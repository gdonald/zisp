//! Categorical runtime logger.
//!
//! Five categories — gc, reader, eval, compile, cli — each independently
//! togglable.
//!
//! Compile-time gating by build mode:
//!
//!   Debug        — every category on; calls always emit.
//!   ReleaseSafe  — calls compile in but each category checks an atomic flag
//!                  populated from the ZISP_LOG env var at startup.
//!   ReleaseFast  — every call site comptime-elides to a no-op.
//!
//! The runtime cost of a disabled category in ReleaseSafe is one relaxed atomic
//! load + branch; in ReleaseFast it's literally zero.
//!
//! `*trace-output*` (CLHS) is the Lisp-visible binding for trace output. It
//! is not yet wired up — that waits for streams; for now we expose a
//! placeholder hook at `trace_output_stream` that the eventual stream-aware
//! version will replace.

const std = @import("std");
const builtin = @import("builtin");

pub const Category = enum {
    gc,
    reader,
    eval,
    compile,
    cli,
};

const N_CATEGORIES = @typeInfo(Category).@"enum".fields.len;

/// Per-category enabled flags. Only consulted in ReleaseSafe; the other modes
/// short-circuit at comptime.
var enabled: [N_CATEGORIES]std.atomic.Value(bool) = blk: {
    var arr: [N_CATEGORIES]std.atomic.Value(bool) = undefined;
    for (&arr) |*slot| slot.* = std.atomic.Value(bool).init(false);
    break :blk arr;
};

/// Read ZISP_LOG and turn on the named categories. Format: comma-separated
/// names, or `all` to enable everything. Unknown names are silently ignored.
///
/// Calling this in Debug or ReleaseFast is harmless but redundant — those
/// modes don't consult the flags.
pub fn initFromEnv(allocator: std.mem.Allocator) void {
    if (builtin.mode != .ReleaseSafe) return;

    const raw = std.process.getEnvVarOwned(allocator, "ZISP_LOG") catch return;
    defer allocator.free(raw);

    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |name| {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "all")) {
            for (&enabled) |*slot| slot.store(true, .monotonic);
            continue;
        }
        if (categoryFromName(trimmed)) |cat| {
            enabled[@intFromEnum(cat)].store(true, .monotonic);
        }
    }
}

/// Force a category on/off. Tests use this; production uses initFromEnv.
pub fn setEnabled(cat: Category, on: bool) void {
    enabled[@intFromEnum(cat)].store(on, .monotonic);
}

pub fn isEnabled(cat: Category) bool {
    return switch (builtin.mode) {
        .Debug => true,
        .ReleaseFast, .ReleaseSmall => false,
        .ReleaseSafe => enabled[@intFromEnum(cat)].load(.monotonic),
    };
}

/// Emit a log line for `cat`. No-op when the category is disabled. The format
/// string is comptime so disabled call sites really do generate nothing in
/// ReleaseFast.
pub fn log(comptime cat: Category, comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) return;
    if (!isEnabled(cat)) return;
    std.debug.print("[" ++ @tagName(cat) ++ "] " ++ fmt ++ "\n", args);
}

fn categoryFromName(name: []const u8) ?Category {
    inline for (@typeInfo(Category).@"enum".fields) |f| {
        if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// This will be replaced with a real stream once `*standard-output*` and
/// friends exist. For now nothing reads it; the placeholder exists so the
/// stream-aware version has a concrete landing site to grep for.
pub var trace_output_stream: ?*anyopaque = null;
