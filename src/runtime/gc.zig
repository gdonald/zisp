//! The object allocator underneath the heap.
//!
//! Objects come out of large regions rather than one host allocation
//! each, so a sweep can walk them and hand reclaimed space back through a
//! free list. Payload arrays that objects point at (string characters,
//! array storage, bignum limbs) stay on the host allocator; only the
//! objects themselves live here.

const std = @import("std");
const build_options = @import("build_options");

/// How much memory one region holds. Large enough that carving objects
/// out of it is the common path, small enough that a mostly-empty region
/// is not much waste.
pub const REGION_BYTES: usize = 64 * 1024;

/// Objects are handed out at this alignment, which is what the tagged
/// representation needs of every heap pointer.
pub const ALIGNMENT: usize = 8;

/// The prefix every block in an object region carries, free or live. It
/// is what lets a sweep walk a region without knowing what type each
/// object is.
const BlockHeader = extern struct {
    /// Payload bytes, not counting this prefix. Every size is a multiple
    /// of the alignment, so the low bit is spare and records whether the
    /// block is free.
    tagged_size: u64,

    fn size(self: BlockHeader) usize {
        return @intCast(self.tagged_size & ~@as(u64, 1));
    }

    fn isFree(self: BlockHeader) bool {
        return self.tagged_size & 1 != 0;
    }

    fn set(self: *BlockHeader, payload_size: usize, free_block: bool) void {
        self.tagged_size = payload_size | @intFromBool(free_block);
    }

    fn payload(self: *BlockHeader) [*]align(ALIGNMENT) u8 {
        const base: [*]u8 = @ptrCast(self);
        return @alignCast(base + BLOCK_HEADER_BYTES);
    }
};

pub const BLOCK_HEADER_BYTES: usize = @sizeOf(BlockHeader);

/// A free block, threaded through the space it used to occupy. Its size
/// lives in the block header ahead of it, so a sweep can read the size of
/// a free block and a live one the same way.
const FreeBlock = struct {
    next: ?*FreeBlock,
};

/// The size classes the free list is bucketed by. A request larger than
/// the last class goes to the oversized list, which is searched linearly.
pub const SIZE_CLASSES = [_]usize{ 16, 32, 64, 128 };

/// What a region holds. Conses have no header, so they live apart from
/// the objects that do: a sweep can then walk a cons region in fixed
/// steps and an object region by each header's recorded size.
pub const Contents = enum { conses, objects };

/// Written into a reclaimed block's second word where a checked build can
/// see it. The low three bits are a tag no `Value` ever carries, so a
/// live cons cannot hold this by accident.
pub const POISON: u64 = 0xDEADBEEFDEADBEE6;

/// Whether reclaimed blocks are poisoned and dereferences checked.
pub const checked = std.debug.runtime_safety;

/// Whether the second word of the object at `address` says it was
/// reclaimed. Only meaningful in a checked build.
pub fn isPoisoned(address: usize) bool {
    if (!checked) return false;
    const words: [*]const u64 = @ptrFromInt(address);
    return words[1] == POISON;
}

fn poison(payload: [*]align(ALIGNMENT) u8, size: usize) void {
    if (!checked or size < 16) return;
    const words: [*]u64 = @ptrCast(payload);
    words[1] = POISON;
}

/// Bytes one cons occupies, which is also the step a cons region is
/// walked in.
pub const CONS_BYTES: usize = 16;

/// The smallest payload a block may have, which is what a free block
/// needs to thread itself through.
pub const MIN_PAYLOAD: usize = @max(@sizeOf(FreeBlock), ALIGNMENT);

const Region = struct {
    memory: []align(ALIGNMENT) u8,
    /// How far the bump pointer has got through this region.
    used: usize,
    contents: Contents,
    /// One bit per `ALIGNMENT` bytes, set on the granule an object starts
    /// at. This is where mark bits live, so a cons needs no header.
    marks: []u8,
    next: ?*Region,

    fn owns(self: *const Region, address: usize) bool {
        const base = @intFromPtr(self.memory.ptr);
        return address >= base and address < base + self.memory.len;
    }

    fn granuleOf(self: *const Region, address: usize) usize {
        return (address - @intFromPtr(self.memory.ptr)) / ALIGNMENT;
    }

    fn isMarked(self: *const Region, address: usize) bool {
        const granule = self.granuleOf(address);
        return self.marks[granule / 8] & (@as(u8, 1) << @intCast(granule % 8)) != 0;
    }
};

pub const Stats = struct {
    /// Bytes handed out and not yet reclaimed.
    live_bytes: usize = 0,
    /// Bytes the regions hold in total.
    region_bytes: usize = 0,
    /// Blocks sitting on the object free lists.
    free_blocks: usize = 0,
    /// Bytes sitting on the object free lists, payloads only.
    free_bytes: usize = 0,
    /// Cells sitting on the cons free list.
    free_conses: usize = 0,
    /// Bytes handed out since the last collection, which is what the
    /// trigger heuristic watches.
    bytes_since_collection: usize = 0,
    /// Steps once per allocation. A held heap pointer is only known to
    /// be good while this stands still.
    generation: u64 = 0,
};

pub const Allocator = struct {
    backing: std.mem.Allocator,
    regions: ?*Region = null,
    cons_regions: ?*Region = null,
    /// Conses are all one size, so they need only the one free list.
    cons_free: ?*FreeBlock = null,
    /// One list per size class, plus a final list for anything larger.
    free_lists: [SIZE_CLASSES.len + 1]?*FreeBlock = .{null} ** (SIZE_CLASSES.len + 1),
    stats: Stats = .{},
    /// How much may be handed out between collections. The default is
    /// what a program allocates in a fraction of a second, so a long run
    /// collects often enough that the heap does not grow without bound.
    collect_threshold: usize = 8 << 20,
    /// Hold reclaimed blocks back rather than handing them out again, so
    /// a stale reference stays poisoned instead of finding whatever was
    /// allocated over it. On under torture, where the point is to catch
    /// the stale reference.
    quarantine: bool = build_options.gc_torture > 0,

    pub fn init(backing: std.mem.Allocator) Allocator {
        return .{ .backing = backing };
    }

    pub fn deinit(self: *Allocator) void {
        self.freeRegions(self.regions);
        self.freeRegions(self.cons_regions);
        self.regions = null;
        self.cons_regions = null;
        self.cons_free = null;
        self.free_lists = .{null} ** (SIZE_CLASSES.len + 1);
        self.stats = .{};
    }

    fn freeRegions(self: *Allocator, first: ?*Region) void {
        var region = first;
        while (region) |current| {
            const next = current.next;
            self.backing.free(current.memory);
            self.backing.free(current.marks);
            self.backing.destroy(current);
            region = next;
        }
    }

    /// The list a block of `size` bytes belongs on.
    fn classOf(size: usize) usize {
        for (SIZE_CLASSES, 0..) |limit, i| {
            if (size <= limit) return i;
        }
        return SIZE_CLASSES.len;
    }

    fn rounded(size: usize) usize {
        // Every block has to hold a `FreeBlock` once it is reclaimed.
        const needed = @max(size, MIN_PAYLOAD);
        return std.mem.alignForward(usize, needed, ALIGNMENT);
    }

    /// Space for one object. The bytes are not zeroed; the caller writes
    /// the object over them.
    pub fn alloc(self: *Allocator, size: usize) ![]align(ALIGNMENT) u8 {
        const want = rounded(size);
        const block = self.popFree(want) orelse try self.bumpObject(want);
        self.stats.generation += 1;
        self.stats.live_bytes += block.len;
        self.stats.bytes_since_collection += block.len;
        return block;
    }

    /// Hand a block back.
    pub fn free(self: *Allocator, memory: []align(ALIGNMENT) u8) void {
        const header = headerOf(memory.ptr);
        self.stats.live_bytes -= header.size();
        self.pushFree(header);
    }

    fn headerOf(payload: [*]align(ALIGNMENT) u8) *BlockHeader {
        return @ptrCast(@alignCast(payload - BLOCK_HEADER_BYTES));
    }

    fn pushFree(self: *Allocator, header: *BlockHeader) void {
        header.set(header.size(), true);
        poison(header.payload(), header.size());
        const block: *FreeBlock = @ptrCast(@alignCast(header.payload()));
        const class = classOf(header.size());
        block.* = .{ .next = self.free_lists[class] };
        self.free_lists[class] = block;
        self.stats.free_blocks += 1;
        self.stats.free_bytes += header.size();
    }

    /// The first block big enough, taken from its own class if one fits
    /// and from a larger class otherwise. A block with room to spare is
    /// split, so a coalesced run does not sit idle behind one small
    /// request.
    fn popFree(self: *Allocator, size: usize) ?[]align(ALIGNMENT) u8 {
        var index = classOf(size);
        while (index < self.free_lists.len) : (index += 1) {
            var previous: ?*FreeBlock = null;
            var current = self.free_lists[index];
            while (current) |block| {
                const header = headerOf(@ptrCast(block));
                if (header.size() >= size) {
                    if (previous) |p| p.next = block.next else self.free_lists[index] = block.next;
                    self.stats.free_blocks -= 1;
                    self.stats.free_bytes -= header.size();
                    self.split(header, size);
                    header.set(header.size(), false);
                    return header.payload()[0..header.size()];
                }
                previous = block;
                current = block.next;
            }
        }
        return null;
    }

    /// Cut a block down to `size`, putting the remainder back on the free
    /// lists when what is left over can hold a block of its own.
    fn split(self: *Allocator, header: *BlockHeader, size: usize) void {
        const spare = header.size() - size;
        if (spare < BLOCK_HEADER_BYTES + MIN_PAYLOAD) return;
        header.set(size, header.isFree());
        const rest: *BlockHeader = @ptrCast(@alignCast(header.payload() + size));
        rest.set(spare - BLOCK_HEADER_BYTES, true);
        self.pushFree(rest);
    }

    fn bumpObject(self: *Allocator, want: usize) ![]align(ALIGNMENT) u8 {
        const bytes = try self.bumpIn(&self.regions, .objects, BLOCK_HEADER_BYTES + want);
        const header: *BlockHeader = @ptrCast(@alignCast(bytes.ptr));
        header.set(want, false);
        return header.payload()[0..want];
    }

    fn bumpIn(
        self: *Allocator,
        list: *?*Region,
        contents: Contents,
        size: usize,
    ) ![]align(ALIGNMENT) u8 {
        if (list.*) |region| {
            if (region.used + size <= region.memory.len) {
                const start = region.used;
                region.used += size;
                return @alignCast(region.memory[start .. start + size]);
            }
        }
        // A request larger than a whole region gets a region of its own.
        const bytes = @max(size, REGION_BYTES);
        const region = try self.backing.create(Region);
        errdefer self.backing.destroy(region);
        const memory = try self.backing.alignedAlloc(u8, .of(FreeBlock), bytes);
        errdefer self.backing.free(memory);
        region.* = .{
            .memory = memory,
            .used = size,
            .contents = contents,
            .marks = try self.backing.alloc(u8, (bytes / ALIGNMENT + 7) / 8),
            .next = list.*,
        };
        @memset(region.marks, 0);
        list.* = region;
        self.stats.region_bytes += bytes;
        return @alignCast(region.memory[0..size]);
    }

    /// Space for one cons, which comes from the cons-only regions.
    pub fn allocCons(self: *Allocator) ![]align(ALIGNMENT) u8 {
        self.stats.generation += 1;
        self.stats.live_bytes += CONS_BYTES;
        self.stats.bytes_since_collection += CONS_BYTES;
        if (self.cons_free) |block| {
            self.cons_free = block.next;
            self.stats.free_conses -= 1;
            const bytes: [*]align(ALIGNMENT) u8 = @ptrCast(block);
            return bytes[0..CONS_BYTES];
        }
        return self.bumpIn(&self.cons_regions, .conses, CONS_BYTES);
    }

    pub fn freeCons(self: *Allocator, memory: []align(ALIGNMENT) u8) void {
        poison(memory.ptr, CONS_BYTES);
        const block: *FreeBlock = @ptrCast(@alignCast(memory.ptr));
        block.* = .{ .next = self.cons_free };
        self.cons_free = block;
        self.stats.live_bytes -= CONS_BYTES;
        self.stats.free_conses += 1;
    }

    // --- mark bits ---

    fn regionOf(self: *Allocator, address: usize) ?*Region {
        var region = self.regions;
        while (region) |current| : (region = current.next) {
            if (current.owns(address)) return current;
        }
        region = self.cons_regions;
        while (region) |current| : (region = current.next) {
            if (current.owns(address)) return current;
        }
        return null;
    }

    /// Set the mark bit for the object starting at `address`. Returns
    /// false when the address belongs to no region, which is how an
    /// object outside the collected heap is recognized.
    pub fn mark(self: *Allocator, address: usize) bool {
        const region = self.regionOf(address) orelse return false;
        const granule = region.granuleOf(address);
        region.marks[granule / 8] |= @as(u8, 1) << @intCast(granule % 8);
        return true;
    }

    pub fn isMarked(self: *Allocator, address: usize) bool {
        const region = self.regionOf(address) orelse return false;
        return region.isMarked(address);
    }

    /// Whether `address` lies in the collected heap at all.
    pub fn owns(self: *Allocator, address: usize) bool {
        return self.regionOf(address) != null;
    }

    /// Clear every mark, which is what starts a collection.
    pub fn clearMarks(self: *Allocator) void {
        for ([_]?*Region{ self.regions, self.cons_regions }) |first| {
            var region = first;
            while (region) |current| : (region = current.next) {
                @memset(current.marks, 0);
            }
        }
    }

    /// Whether enough has been allocated since the last collection to
    /// make another one due.
    pub fn collectionDue(self: *const Allocator) bool {
        return self.stats.bytes_since_collection > self.collect_threshold;
    }

    // --- sweep ---

    /// What a sweep calls on an object about to be reclaimed, so whatever
    /// the object holds outside the collected heap goes with it.
    pub const Finalizer = struct {
        context: *anyopaque,
        run: *const fn (context: *anyopaque, object: [*]align(ALIGNMENT) u8) void,
    };

    /// Reclaim everything left unmarked and rebuild the free lists.
    ///
    /// Marks are cleared as the walk passes them, so the next collection
    /// starts from a clean bitmap.
    ///
    /// The walk runs in address order, so a run of neighbouring dead
    /// blocks becomes one free block rather than several. That is the
    /// coalescing: nothing merges blocks afterwards, because the free
    /// lists are only ever built from runs.
    pub fn sweep(self: *Allocator, finalizer: ?Finalizer) void {
        self.free_lists = .{null} ** (SIZE_CLASSES.len + 1);
        self.cons_free = null;
        self.stats.free_blocks = 0;
        self.stats.free_bytes = 0;
        self.stats.free_conses = 0;
        self.stats.live_bytes = 0;
        self.stats.bytes_since_collection = 0;
        self.stats.generation += 1;

        var region = self.regions;
        while (region) |current| : (region = current.next) {
            self.sweepObjects(current, finalizer);
        }
        region = self.cons_regions;
        while (region) |current| : (region = current.next) {
            self.sweepConses(current);
        }
    }

    fn sweepObjects(self: *Allocator, region: *Region, finalizer: ?Finalizer) void {
        var offset: usize = 0;
        var run_start: ?usize = null;
        while (offset < region.used) {
            const header: *BlockHeader = @ptrCast(@alignCast(region.memory.ptr + offset));
            const total = BLOCK_HEADER_BYTES + header.size();
            const payload = header.payload();
            const live = !header.isFree() and region.isMarked(@intFromPtr(payload));
            if (live) {
                self.stats.live_bytes += header.size();
                if (run_start) |start| {
                    self.releaseRun(region, start, offset);
                    run_start = null;
                }
            } else {
                if (!header.isFree()) {
                    if (finalizer) |f| f.run(f.context, payload);
                    // Poison every dead block, not just the one a run
                    // starts at, so a stale reference into the middle of
                    // a run is caught too.
                    poison(payload, header.size());
                }
                if (run_start == null) run_start = offset;
            }
            offset += total;
        }
        if (run_start) |start| self.releaseRun(region, start, offset);
        @memset(region.marks, 0);
    }

    /// Turn the bytes from `start` up to `end` into one free block.
    fn releaseRun(self: *Allocator, region: *Region, start: usize, end: usize) void {
        const header: *BlockHeader = @ptrCast(@alignCast(region.memory.ptr + start));
        header.set(end - start - BLOCK_HEADER_BYTES, true);
        if (self.quarantine) {
            poison(header.payload(), header.size());
            return;
        }
        self.pushFree(header);
    }

    /// A cons region needs no runs: every cell is the same size, and the
    /// only thing that allocates from it wants exactly that size.
    fn sweepConses(self: *Allocator, region: *Region) void {
        var offset: usize = 0;
        while (offset < region.used) : (offset += CONS_BYTES) {
            const cell: [*]align(ALIGNMENT) u8 = @alignCast(region.memory.ptr + offset);
            if (region.isMarked(@intFromPtr(cell))) {
                self.stats.live_bytes += CONS_BYTES;
                continue;
            }
            poison(cell, CONS_BYTES);
            if (self.quarantine) continue;
            const block: *FreeBlock = @ptrCast(@alignCast(cell));
            block.* = .{ .next = self.cons_free };
            self.cons_free = block;
            self.stats.free_conses += 1;
        }
        @memset(region.marks, 0);
    }

    /// Walk every block a region has handed out, which is what a sweep
    /// needs. The callback sees each object's bytes in address order.
    pub fn regionCount(self: *const Allocator) usize {
        var count: usize = 0;
        for ([_]?*Region{ self.regions, self.cons_regions }) |first| {
            var region = first;
            while (region) |current| : (region = current.next) count += 1;
        }
        return count;
    }
};
