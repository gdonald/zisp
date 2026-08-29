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

/// A reclaimed cons cell. A cell carries no header, so the first word
/// holds a marker instead and the list is threaded through the second.
/// That is what lets a card scan pass over a cell nothing owns.
const FreeCons = extern struct {
    marker: u64,
    next: ?*FreeCons,
};

/// The size classes the free list is bucketed by. A request larger than
/// the last class goes to the oversized list, which is searched linearly.
pub const SIZE_CLASSES = [_]usize{ 16, 32, 64, 128 };

/// The blocks one generation has reclaimed. Each generation keeps its
/// own set, so an allocation into the tenured space never lands in a
/// block the nursery gave up, and the other way round.
const FreeLists = struct {
    objects: [SIZE_CLASSES.len + 1]?*FreeBlock = .{null} ** (SIZE_CLASSES.len + 1),
    conses: ?*FreeCons = null,
    /// Payload bytes threaded onto the object lists.
    bytes: usize = 0,
    /// Blocks on the object lists.
    blocks: usize = 0,
    /// Cells on the cons list.
    cells: usize = 0,

    fn clear(self: *FreeLists) void {
        self.* = .{};
    }
};

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

/// Whether the object at `address` says it was reclaimed. A block keeps
/// the pattern in its second word, and a cons cell in its first, since a
/// reclaimed cell threads the free list through its second. Neither can
/// hold the pattern while it is live: a header cannot be that large, and
/// no `Value` carries the tag the low bits spell.
pub fn isPoisoned(address: usize) bool {
    if (!checked) return false;
    const words: [*]const u64 = @ptrFromInt(address);
    return words[0] == POISON or words[1] == POISON;
}

/// Whether the cons cell at `address` is on a free list rather than
/// holding a pair. Unlike `isPoisoned` this holds in every build: the
/// marker is what a card scan reads to tell the two apart.
fn isReclaimedCons(address: usize) bool {
    const words: [*]const u64 = @ptrFromInt(address);
    return words[0] == POISON;
}

/// Say that a cell holds no pair any more, which is what a card scan
/// reads to pass over it. A cell on a free list carries this in its first
/// word, and so does one a checked build is holding back rather than
/// handing out again.
fn markReclaimedCons(cell: [*]align(ALIGNMENT) u8) void {
    const words: [*]u64 = @ptrCast(cell);
    words[0] = POISON;
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

/// How much the nursery holds. Everything is allocated here first and a
/// collection evacuates what survives, so this is also how much garbage a
/// program may make between collections before one is due.
pub const NURSERY_BYTES: usize = 1 << 20;

/// Which generation an object lives in.
pub const Generation = enum { nursery, tenured };

/// How much of a region one card stands for. A collection reads the
/// slots of every dirty card, so a smaller card means less to read and a
/// larger table to keep.
pub const CARD_BYTES: usize = 512;

/// Collections are counted by how long they took, each bucket an order
/// of magnitude wider than the last: under a microsecond, under ten,
/// and so on up to the last, which is everything a second and over.
pub const PAUSE_BUCKETS: usize = 8;

pub fn pauseBucket(nanoseconds: u64) usize {
    var edge: u64 = std.time.ns_per_us;
    for (0..PAUSE_BUCKETS - 1) |bucket| {
        if (nanoseconds < edge) return bucket;
        edge *= 10;
    }
    return PAUSE_BUCKETS - 1;
}

const Region = struct {
    memory: []align(ALIGNMENT) u8,
    /// How far the bump pointer has got through this region.
    used: usize,
    contents: Contents,
    /// Which generation whatever is carved out of this region belongs
    /// to, which is what tells a sweep where its free blocks go.
    generation: Generation = .tenured,
    /// One bit per `ALIGNMENT` bytes, set on the granule an object starts
    /// at. This is where mark bits live, so a cons needs no header.
    marks: []u8,
    /// One bit per `CARD_BYTES`, set when something in that span was made
    /// to point at a young object. Only a tenured region's cards are
    /// read: a young object is found through the roots either way.
    cards: []u8,
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

    fn cardOf(self: *const Region, address: usize) usize {
        return (address - @intFromPtr(self.memory.ptr)) / CARD_BYTES;
    }

    fn markCard(self: *Region, address: usize) void {
        const card = self.cardOf(address);
        self.cards[card / 8] |= @as(u8, 1) << @intCast(card % 8);
    }

    fn cardDirty(self: *const Region, card: usize) bool {
        return self.cards[card / 8] & (@as(u8, 1) << @intCast(card % 8)) != 0;
    }

    /// The bytes one card stands for, clipped to what the region has
    /// handed out.
    fn cardSpan(self: *const Region, card: usize) []align(ALIGNMENT) u8 {
        const start = card * CARD_BYTES;
        const end = @min(start + CARD_BYTES, self.used);
        return @alignCast(self.memory[start..end]);
    }

    fn cardCount(self: *const Region) usize {
        return (self.used + CARD_BYTES - 1) / CARD_BYTES;
    }

    fn anyCardDirty(self: *const Region) bool {
        const cards = self.cardCount();
        for (self.cards[0 .. cards / 8]) |byte| {
            if (byte != 0) return true;
        }
        const rest: u3 = @intCast(cards % 8);
        if (rest == 0) return false;
        const mask = (@as(u8, 1) << rest) - 1;
        return self.cards[cards / 8] & mask != 0;
    }

    /// Whether anything the region has handed out survived. Reading the
    /// bitmap a byte at a time settles that eight granules at a time,
    /// where walking the objects would touch every one of them.
    fn anyMarked(self: *const Region) bool {
        const granules = self.used / ALIGNMENT;
        for (self.marks[0 .. granules / 8]) |byte| {
            if (byte != 0) return true;
        }
        const rest: u3 = @intCast(granules % 8);
        if (rest == 0) return false;
        const mask = (@as(u8, 1) << rest) - 1;
        return self.marks[granules / 8] & mask != 0;
    }
};

pub const Stats = struct {
    /// Tenured bytes handed out and not yet reclaimed. The nursery is
    /// counted on its own, since nothing there survives a collection
    /// without being copied out first.
    live_bytes: usize = 0,
    /// How far the nursery's bump pointer has got.
    nursery_bytes: usize = 0,
    /// Objects the last collection copied out of the nursery.
    promoted: usize = 0,
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
    /// How long collections have taken in total. The mutator is stopped
    /// for all of it, so this is pause time rather than work time.
    gc_time_ns: u64 = 0,
    /// The longest single collection.
    gc_pause_max_ns: u64 = 0,
    /// Collections by how long they took.
    pauses: [PAUSE_BUCKETS]u32 = .{0} ** PAUSE_BUCKETS,
};

pub const Allocator = struct {
    backing: std.mem.Allocator,
    /// Bump-allocated young space: one region for conses and one for
    /// the objects that carry a header, so a sweep can walk either.
    /// Allocation carves from here until the budget is spent. A
    /// collection between allocations reclaims what died in place, and
    /// the one at a top level form copies the survivors into the
    /// tenured regions and puts the bump pointers back to zero.
    nursery_objects: ?*Region = null,
    nursery_conses: ?*Region = null,
    /// What the two nursery regions may hand out between them.
    nursery_capacity: usize = NURSERY_BYTES,
    /// Bytes the last collection read from dirty cards before it reached
    /// anything of its own, which is what makes a young collection cost
    /// more than the nursery it walks.
    card_scan_bytes: usize = 0,
    /// Set when a young allocation had to come out of the tenured space
    /// because the nursery had nothing left, which is what makes a
    /// collection due before the next one.
    nursery_spilled: bool = false,
    regions: ?*Region = null,
    cons_regions: ?*Region = null,
    /// The region the last address looked up belonged to.
    last_region: ?*Region = null,
    tenured_free: FreeLists = .{},
    nursery_free: FreeLists = .{},
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
        self.freeRegions(self.nursery_objects);
        self.freeRegions(self.nursery_conses);
        self.freeRegions(self.regions);
        self.freeRegions(self.cons_regions);
        self.nursery_objects = null;
        self.nursery_conses = null;
        self.last_region = null;
        self.nursery_spilled = false;
        self.regions = null;
        self.cons_regions = null;
        self.tenured_free.clear();
        self.nursery_free.clear();
        self.stats = .{};
    }

    fn freeRegions(self: *Allocator, first: ?*Region) void {
        var region = first;
        while (region) |current| {
            const next = current.next;
            self.backing.free(current.memory);
            self.backing.free(current.marks);
            self.backing.free(current.cards);
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
    ///
    /// The nursery is tried first, from what the last collection
    /// reclaimed there and then from its bump pointer. A request the
    /// nursery cannot serve goes to the tenured space and records the
    /// spill, so a collection runs before the next allocation.
    pub fn alloc(self: *Allocator, size: usize) ![]align(ALIGNMENT) u8 {
        defer self.refreshFreeStats();
        const want = rounded(size);
        self.stats.generation += 1;
        if (popFrom(&self.nursery_free, want)) |block| {
            self.stats.bytes_since_collection += block.len;
            return block;
        }
        if (try self.bumpNursery(&self.nursery_objects, .objects, BLOCK_HEADER_BYTES + want)) |bytes| {
            self.stats.bytes_since_collection += want;
            const header: *BlockHeader = @ptrCast(@alignCast(bytes.ptr));
            header.set(want, false);
            return header.payload()[0..want];
        }
        self.noteSpill();
        const block = popFrom(&self.tenured_free, want) orelse try self.bumpObject(want);
        self.dirtyCardFor(@intFromPtr(block.ptr));
        self.stats.live_bytes += block.len;
        self.stats.bytes_since_collection += block.len;
        return block;
    }

    /// Mark the card an object about to be built on sits on.
    ///
    /// A young allocation the nursery could not serve is built in the
    /// tenured space out of values that are young, and a constructor
    /// writes its fields rather than storing into them, so no barrier
    /// runs. The copy the evacuator makes needs none of this: it rewrites
    /// every reference it copies.
    fn dirtyCardFor(self: *Allocator, address: usize) void {
        const region = self.regionOf(address) orelse return;
        if (region.generation != .tenured) return;
        region.markCard(address);
    }

    /// Record that young space ran out. The collection this asks for
    /// happens between allocations, where moving is unsafe but reclaiming
    /// in place is not.
    fn noteSpill(self: *Allocator) void {
        if (self.nursery_capacity == 0) return;
        self.nursery_spilled = true;
    }

    /// Space for one object in the tenured space, which is where a
    /// collection copies what it finds alive in the nursery.
    pub fn allocTenured(self: *Allocator, size: usize) ![]align(ALIGNMENT) u8 {
        defer self.refreshFreeStats();
        const want = rounded(size);
        const block = popFrom(&self.tenured_free, want) orelse try self.bumpObject(want);
        self.stats.generation += 1;
        self.stats.live_bytes += block.len;
        return block;
    }

    /// Space for one cons in the tenured space.
    pub fn allocTenuredCons(self: *Allocator) ![]align(ALIGNMENT) u8 {
        defer self.refreshFreeStats();
        self.stats.generation += 1;
        self.stats.live_bytes += CONS_BYTES;
        if (popCons(&self.tenured_free)) |bytes| return bytes;
        return self.bumpIn(&self.cons_regions, .conses, CONS_BYTES);
    }

    /// The next `size` bytes of one nursery region, or null once the
    /// young budget is spent.
    fn bumpNursery(
        self: *Allocator,
        slot: *?*Region,
        contents: Contents,
        size: usize,
    ) !?[]align(ALIGNMENT) u8 {
        if (self.nursery_capacity == 0) return null;
        if (self.nurseryUsed() + size > self.nursery_capacity) return null;
        if (slot.* == null) {
            slot.* = try self.newRegion(contents, self.nursery_capacity, .nursery, null);
        }
        const region = slot.*.?;
        if (region.used + size > region.memory.len) return null;
        const start = region.used;
        region.used += size;
        self.stats.nursery_bytes = self.nurseryUsed();
        return @alignCast(region.memory[start .. start + size]);
    }

    /// What the two nursery regions have handed out between them.
    pub fn nurseryUsed(self: *const Allocator) usize {
        var total: usize = 0;
        if (self.nursery_objects) |region| total += region.used;
        if (self.nursery_conses) |region| total += region.used;
        return total;
    }

    /// Whether `address` lies in the nursery, which is what tells a
    /// collection the object has to be copied before it is read again.
    pub fn inNursery(self: *const Allocator, address: usize) bool {
        for ([_]?*Region{ self.nursery_objects, self.nursery_conses }) |maybe| {
            const region = maybe orelse continue;
            const base = @intFromPtr(region.memory.ptr);
            if (address >= base and address < base + region.used) return true;
        }
        return false;
    }

    /// Hand the young cons region over to the tenured space once what
    /// survived fills half of it.
    ///
    /// A cell that came through a collection is old by then, and leaving
    /// it where it is costs the nursery the room it sits in. A form that
    /// runs for a long time would otherwise collect more and more often
    /// over less and less space. Nothing moves: the region keeps its
    /// address and only changes which generation it belongs to, so a
    /// value a Zig local holds is as good afterwards as before.
    fn retireCrowdedNursery(self: *Allocator, region: *Region, live: usize) void {
        if (live * 2 < region.memory.len) return;
        // The region has just been swept, so what it gave up is on the
        // young cons list and goes with it. Retiring any earlier would
        // leave dead cells in the tenured space still holding whatever
        // they held when they died, which a card scan reads as live.
        self.stats.live_bytes += live;
        // A cell that was young could point at anything else young
        // without a barrier having run, so every card starts dirty and
        // the next collection reads the lot.
        @memset(region.cards, 0xFF);
        region.generation = .tenured;
        region.next = self.cons_regions;
        self.cons_regions = region;
        self.nursery_conses = null;
        self.last_region = null;
        self.handOverReclaimedCells();
    }

    /// Move the cells the young cons list holds onto the tenured one,
    /// which is where they belong once the region they sit in is.
    fn handOverReclaimedCells(self: *Allocator) void {
        var cell = self.nursery_free.conses;
        var moved: usize = 0;
        while (cell) |block| : (cell = block.next) {
            moved += 1;
            if (block.next == null) {
                block.next = self.tenured_free.conses;
                self.tenured_free.conses = self.nursery_free.conses;
                break;
            }
        }
        if (moved == 0) return;
        self.nursery_free.conses = null;
        self.nursery_free.cells -= moved;
        self.tenured_free.cells += moved;
    }

    /// Put one region back to its bump pointer, with nothing it handed
    /// out still reachable.
    fn resetRegion(self: *Allocator, region: *Region) void {
        _ = self;
        // Every word reads as poison, so a reference that was missed is
        // caught the same way a swept object's is.
        if (checked) {
            const words: [*]u64 = @ptrCast(region.memory.ptr);
            for (0..region.used / 8) |i| words[i] = POISON;
        }
        region.used = 0;
        @memset(region.marks, 0);
    }

    /// Give the nursery back to its bump pointers. Everything still
    /// wanted has been copied out by the time this runs.
    pub fn resetNursery(self: *Allocator) void {
        for ([_]?*Region{ self.nursery_objects, self.nursery_conses }) |maybe| {
            const region = maybe orelse continue;
            self.resetRegion(region);
        }
        self.nursery_free.clear();
        self.nursery_spilled = false;
        self.stats.nursery_bytes = 0;
        self.stats.bytes_since_collection = 0;
    }

    /// Whether the nursery has handed out its whole budget, which is what
    /// makes a collection due at the next top level form.
    pub fn nurseryFull(self: *const Allocator) bool {
        if (self.nursery_capacity == 0) return false;
        return self.nurseryUsed() >= self.nursery_capacity;
    }

    /// How much a young collection may allocate for every byte the last
    /// one read from dirty cards. A form that keeps making old to young
    /// pointers pays that reading over and over, so the interval grows
    /// with it and what the nursery cannot hold spills to the tenured
    /// space instead, where a major collection reclaims it.
    const CARD_SCAN_SHARE: usize = 4;

    /// Whether young space ran out since the last collection.
    ///
    /// Reclaiming it takes a collection, so how often one may run is set
    /// by how much has been handed out since the last: half a nursery, a
    /// quarter of what is live, or `CARD_SCAN_SHARE` times what the last
    /// collection read from the cards, whichever is the largest. Without
    /// the second term a collection costs more per allocated byte the
    /// more a program retains, and without the third the cards do.
    pub fn nurseryDue(self: *const Allocator) bool {
        // A heap with no nursery never spills, so what is due there is
        // what the bytes handed out since the last collection say.
        if (self.nursery_capacity == 0) {
            return self.stats.bytes_since_collection > self.collect_threshold;
        }
        if (!self.nursery_spilled) return false;
        const since = @max(
            self.nursery_capacity / 2,
            self.stats.live_bytes / 4,
            CARD_SCAN_SHARE * self.card_scan_bytes,
        );
        return self.stats.bytes_since_collection >= since;
    }

    /// Hand a block back.
    pub fn free(self: *Allocator, memory: []align(ALIGNMENT) u8) void {
        defer self.refreshFreeStats();
        const header = headerOf(memory.ptr);
        if (self.inNursery(@intFromPtr(memory.ptr))) {
            pushFree(&self.nursery_free, header);
            return;
        }
        self.stats.live_bytes -= header.size();
        pushFree(&self.tenured_free, header);
    }

    fn headerOf(payload: [*]align(ALIGNMENT) u8) *BlockHeader {
        return @ptrCast(@alignCast(payload - BLOCK_HEADER_BYTES));
    }

    fn pushFree(lists: *FreeLists, header: *BlockHeader) void {
        header.set(header.size(), true);
        poison(header.payload(), header.size());
        const block: *FreeBlock = @ptrCast(@alignCast(header.payload()));
        const class = classOf(header.size());
        block.* = .{ .next = lists.objects[class] };
        lists.objects[class] = block;
        lists.bytes += header.size();
        lists.blocks += 1;
    }

    /// One cell off a generation's cons list, or null when it has none.
    fn popCons(lists: *FreeLists) ?[]align(ALIGNMENT) u8 {
        const block = lists.conses orelse return null;
        lists.conses = block.next;
        lists.cells -= 1;
        const bytes: [*]align(ALIGNMENT) u8 = @ptrCast(block);
        return bytes[0..CONS_BYTES];
    }

    fn pushCons(lists: *FreeLists, cell: [*]align(ALIGNMENT) u8) void {
        const block: *FreeCons = @ptrCast(@alignCast(cell));
        block.* = .{ .marker = POISON, .next = lists.conses };
        lists.conses = block;
        lists.cells += 1;
    }

    /// The first block big enough, taken from its own class if one fits
    /// and from a larger class otherwise. A block with room to spare is
    /// split, so a coalesced run does not sit idle behind one small
    /// request.
    fn popFrom(lists: *FreeLists, size: usize) ?[]align(ALIGNMENT) u8 {
        var index = classOf(size);
        while (index < lists.objects.len) : (index += 1) {
            var previous: ?*FreeBlock = null;
            var current = lists.objects[index];
            while (current) |block| {
                const header = headerOf(@ptrCast(block));
                if (header.size() >= size) {
                    if (previous) |p| p.next = block.next else lists.objects[index] = block.next;
                    lists.blocks -= 1;
                    lists.bytes -= header.size();
                    split(lists, header, size);
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
    fn split(lists: *FreeLists, header: *BlockHeader, size: usize) void {
        const spare = header.size() - size;
        if (spare < BLOCK_HEADER_BYTES + MIN_PAYLOAD) return;
        header.set(size, header.isFree());
        const rest: *BlockHeader = @ptrCast(@alignCast(header.payload() + size));
        rest.set(spare - BLOCK_HEADER_BYTES, true);
        pushFree(lists, rest);
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
        const region = try self.newRegion(contents, @max(size, REGION_BYTES), .tenured, list.*);
        region.used = size;
        list.* = region;
        return @alignCast(region.memory[0..size]);
    }

    fn newRegion(
        self: *Allocator,
        contents: Contents,
        bytes: usize,
        generation: Generation,
        next: ?*Region,
    ) !*Region {
        const region = try self.backing.create(Region);
        errdefer self.backing.destroy(region);
        const memory = try self.backing.alignedAlloc(u8, .of(FreeBlock), bytes);
        errdefer self.backing.free(memory);
        region.* = .{
            .memory = memory,
            .used = 0,
            .contents = contents,
            .generation = generation,
            .marks = try self.backing.alloc(u8, (bytes / ALIGNMENT + 7) / 8),
            .cards = try self.backing.alloc(u8, (bytes / CARD_BYTES + 7) / 8),
            .next = next,
        };
        @memset(region.marks, 0);
        @memset(region.cards, 0);
        self.stats.region_bytes += bytes;
        return region;
    }

    /// Space for one cons. The nursery first, then the cons-only regions.
    pub fn allocCons(self: *Allocator) ![]align(ALIGNMENT) u8 {
        defer self.refreshFreeStats();
        self.stats.generation += 1;
        self.stats.bytes_since_collection += CONS_BYTES;
        if (popCons(&self.nursery_free)) |bytes| return bytes;
        if (try self.bumpNursery(&self.nursery_conses, .conses, CONS_BYTES)) |bytes| return bytes;
        self.noteSpill();
        self.stats.live_bytes += CONS_BYTES;
        const bytes = popCons(&self.tenured_free) orelse
            try self.bumpIn(&self.cons_regions, .conses, CONS_BYTES);
        self.dirtyCardFor(@intFromPtr(bytes.ptr));
        return bytes;
    }

    pub fn freeCons(self: *Allocator, memory: []align(ALIGNMENT) u8) void {
        defer self.refreshFreeStats();
        poison(memory.ptr, CONS_BYTES);
        if (self.inNursery(@intFromPtr(memory.ptr))) {
            pushCons(&self.nursery_free, memory.ptr);
            return;
        }
        self.stats.live_bytes -= CONS_BYTES;
        pushCons(&self.tenured_free, memory.ptr);
    }

    // --- mark bits ---

    /// The region an address belongs to, or null when it belongs to
    /// none.
    ///
    /// A mark phase asks this of every object it reaches, and the
    /// objects it reaches in a row were mostly allocated in a row, so
    /// the region the last one was in is tried first. Without that the
    /// walk is linear in the number of regions and a heap of a few
    /// hundred of them spends all its time here.
    fn regionOf(self: *Allocator, address: usize) ?*Region {
        if (self.last_region) |current| {
            if (current.owns(address)) return current;
        }
        for ([_]?*Region{ self.nursery_objects, self.nursery_conses }) |maybe| {
            const current = maybe orelse continue;
            if (current.owns(address)) return self.remember(current);
        }
        var region = self.regions;
        while (region) |current| : (region = current.next) {
            if (current.owns(address)) return self.remember(current);
        }
        region = self.cons_regions;
        while (region) |current| : (region = current.next) {
            if (current.owns(address)) return self.remember(current);
        }
        return null;
    }

    fn remember(self: *Allocator, region: *Region) *Region {
        self.last_region = region;
        return region;
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

    /// Note that the object at `container` now refers to `stored`.
    ///
    /// Only one direction matters: a tenured object pointing at a young
    /// one, which nothing else would find. The card the container sits
    /// on is marked, and a collection reads that card's slots as if they
    /// were roots.
    pub fn noteWrite(self: *Allocator, container: usize, stored: usize) void {
        if (!self.inNursery(stored)) return;
        const region = self.regionOf(container) orelse return;
        if (region.generation != .tenured) return;
        region.markCard(container);
    }

    /// Whether the card the object at `address` sits on is marked.
    pub fn cardMarked(self: *Allocator, address: usize) bool {
        const region = self.regionOf(address) orelse return false;
        return region.cardDirty(region.cardOf(address));
    }

    /// Which of the tenured space a scan covers: the cards a store
    /// marked, or every live object there is.
    pub const Reach = enum { dirty_cards, everything };

    /// Every live cons a scan reaches in the tenured space.
    ///
    /// Cells are all one size and a card covers a whole number of them,
    /// so a dirty card is read without knowing anything about its
    /// neighbors. A cell on a free list is passed over: its first word
    /// holds a marker no pair can.
    /// Read every dirty card, cells first and then the objects that
    /// carry a header. The bytes this covers are what the next young
    /// collection is charged for.
    pub fn scanDirtyCards(
        self: *Allocator,
        context: anytype,
        comptime visitCell: fn (@TypeOf(context), [*]align(ALIGNMENT) u8) anyerror!void,
        comptime visitObject: fn (@TypeOf(context), [*]align(ALIGNMENT) u8) anyerror!void,
    ) anyerror!void {
        self.card_scan_bytes = 0;
        try self.scanConses(.dirty_cards, context, visitCell);
        try self.scanObjects(.dirty_cards, context, visitObject);
    }

    pub fn scanConses(
        self: *Allocator,
        reach: Reach,
        context: anytype,
        comptime visit: fn (@TypeOf(context), [*]align(ALIGNMENT) u8) anyerror!void,
    ) anyerror!void {
        var region = self.cons_regions;
        while (region) |current| : (region = current.next) {
            if (current.generation != .tenured) continue;
            var card: usize = 0;
            while (card < current.cardCount()) : (card += 1) {
                if (reach == .dirty_cards and !current.cardDirty(card)) continue;
                const span = current.cardSpan(card);
                var offset: usize = 0;
                while (offset + CONS_BYTES <= span.len) : (offset += CONS_BYTES) {
                    const cell: [*]align(ALIGNMENT) u8 = @alignCast(span.ptr + offset);
                    if (isReclaimedCons(@intFromPtr(cell))) continue;
                    if (reach == .dirty_cards) self.card_scan_bytes += CONS_BYTES;
                    try visit(context, cell);
                }
            }
        }
    }

    /// Every live object a scan reaches in the tenured space.
    ///
    /// A card can start part way through a block, and a block says how
    /// long it is only from its own start, so this walks the region and
    /// keeps the blocks the scan covers. A region with no dirty card is
    /// passed over without being walked at all.
    pub fn scanObjects(
        self: *Allocator,
        reach: Reach,
        context: anytype,
        comptime visit: fn (@TypeOf(context), [*]align(ALIGNMENT) u8) anyerror!void,
    ) anyerror!void {
        var region = self.regions;
        while (region) |current| : (region = current.next) {
            if (current.generation != .tenured) continue;
            if (reach == .dirty_cards and !current.anyCardDirty()) continue;
            var offset: usize = 0;
            while (offset < current.used) {
                const header: *BlockHeader = @ptrCast(@alignCast(current.memory.ptr + offset));
                const payload = header.payload();
                const covered = reach == .everything or
                    current.cardDirty(current.cardOf(@intFromPtr(payload)));
                if (!header.isFree() and covered) {
                    if (reach == .dirty_cards) self.card_scan_bytes += header.size();
                    try visit(context, payload);
                }
                offset += BLOCK_HEADER_BYTES + header.size();
            }
        }
    }

    /// Forget every card. A collection that has read them all starts the
    /// next round from clean.
    pub fn clearCards(self: *Allocator) void {
        for ([_]?*Region{ self.regions, self.cons_regions }) |first| {
            var region = first;
            while (region) |current| : (region = current.next) {
                @memset(current.cards, 0);
            }
        }
    }

    /// Record how long one collection took.
    pub fn recordPause(self: *Allocator, nanoseconds: u64) void {
        self.stats.gc_time_ns += nanoseconds;
        self.stats.gc_pause_max_ns = @max(self.stats.gc_pause_max_ns, nanoseconds);
        self.stats.pauses[pauseBucket(nanoseconds)] += 1;
    }

    /// Clear every mark, which is what starts a collection.
    pub fn clearMarks(self: *Allocator) void {
        for ([_]?*Region{ self.nursery_objects, self.nursery_conses }) |maybe| {
            const current = maybe orelse continue;
            @memset(current.marks, 0);
        }
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
        if (self.nurseryFull()) return true;
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
    /// How much of the heap a sweep covers. A young collection has marks
    /// only for what the nursery holds, so it reclaims that and leaves
    /// the tenured space to the collection that marked it.
    pub const Extent = enum { nursery, everything };

    pub fn sweep(self: *Allocator, extent: Extent, finalizer: ?Finalizer) void {
        self.nursery_free.clear();
        self.nursery_spilled = false;
        self.stats.bytes_since_collection = 0;
        self.stats.generation += 1;

        if (extent == .everything) {
            self.tenured_free.clear();
            self.stats.live_bytes = 0;
            var region = self.regions;
            while (region) |current| : (region = current.next) {
                self.sweepObjects(current, finalizer);
            }
            region = self.cons_regions;
            while (region) |current| : (region = current.next) {
                _ = self.sweepConses(current);
            }
        }

        if (self.nursery_objects) |current| self.sweepObjects(current, finalizer);
        if (self.nursery_conses) |current| {
            // A cell owns nothing outside the heap, so a young cons
            // region with no survivors goes back to its bump pointer
            // rather than having every cell threaded onto a free list.
            const live = if (current.anyMarked()) self.sweepConses(current) else blk: {
                self.resetRegion(current);
                break :blk 0;
            };
            self.retireCrowdedNursery(current, live);
        }
        self.stats.nursery_bytes = self.nurseryUsed();
        self.refreshFreeStats();
    }

    /// What the two generations' free lists hold between them. Each list
    /// keeps its own counters so a sweep of one leaves the other's alone,
    /// and the figures `room` reports are the sum.
    fn refreshFreeStats(self: *Allocator) void {
        self.stats.free_blocks = self.tenured_free.blocks + self.nursery_free.blocks;
        self.stats.free_bytes = self.tenured_free.bytes + self.nursery_free.bytes;
        self.stats.free_conses = self.tenured_free.cells + self.nursery_free.cells;
    }

    /// Where the blocks a region gives up belong. A young block goes back
    /// to the nursery, so the next young allocation finds it and the
    /// tenured space never hands out a nursery address.
    fn listsFor(self: *Allocator, region: *const Region) *FreeLists {
        return switch (region.generation) {
            .nursery => &self.nursery_free,
            .tenured => &self.tenured_free,
        };
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
                if (region.generation == .tenured) self.stats.live_bytes += header.size();
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
        pushFree(self.listsFor(region), header);
    }

    /// A cons region needs no runs: every cell is the same size, and the
    /// only thing that allocates from it wants exactly that size.
    fn sweepConses(self: *Allocator, region: *Region) usize {
        var live: usize = 0;
        var offset: usize = 0;
        while (offset < region.used) : (offset += CONS_BYTES) {
            const cell: [*]align(ALIGNMENT) u8 = @alignCast(region.memory.ptr + offset);
            if (region.isMarked(@intFromPtr(cell))) {
                live += CONS_BYTES;
                if (region.generation == .tenured) self.stats.live_bytes += CONS_BYTES;
                continue;
            }
            markReclaimedCons(cell);
            poison(cell, CONS_BYTES);
            if (self.quarantine) continue;
            pushCons(self.listsFor(region), cell);
        }
        @memset(region.marks, 0);
        return live;
    }

    /// Walk every block a region has handed out, which is what a sweep
    /// needs. The callback sees each object's bytes in address order.
    pub fn regionCount(self: *const Allocator) usize {
        var count: usize = 0;
        for ([_]?*Region{ self.nursery_objects, self.nursery_conses }) |maybe| {
            if (maybe != null) count += 1;
        }
        for ([_]?*Region{ self.regions, self.cons_regions }) |first| {
            var region = first;
            while (region) |current| : (region = current.next) count += 1;
        }
        return count;
    }
};
