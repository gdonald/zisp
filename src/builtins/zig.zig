//! The natives `src/lisp/zig.lisp` builds `comptime-eval` on: running a
//! program, reading the environment, hashing a cache key, and the Zig
//! source of the comptime printer.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const function = @import("../eval/function.zig");
const eval_mod = @import("../eval/eval.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

/// Freestanding and WASI builds cannot start a process.
pub const available = !build_options.freestanding and builtin.os.tag != .wasi;

pub const printer_source = @embedFile("../zig/zisp_lisp.zig");

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerZig(ev: *Evaluator) !void {
    if (!available) return;
    function.asFunction(try ev.defineNative("%RUN-PROGRAM", &runProgramFn)).preserves_values = true;
    _ = try ev.defineNative("%GETENV", &getenvFn);
    _ = try ev.defineNative("%SHA256-HEX", &sha256HexFn);
    _ = try ev.defineNative("%ZIG-PRINTER-SOURCE", &printerSourceFn);
}

fn stringArg(ev: *Evaluator, v: Value) Error![]u8 {
    if (!heap.isString(v)) return Error.TypeError;
    return heap.stringUtf8Alloc(ev.allocator, v);
}

/// `(%run-program program arguments directory)` runs `program` with the
/// list of strings `arguments` in `directory`, waits for it, and returns
/// the exit code, standard output and standard error. A program that
/// cannot be started returns NIL and the reason as the third value. A
/// program ended by a signal returns 128 plus the signal number, as a
/// shell reports it.
fn runProgramFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 3) return Error.WrongArgCount;
    const io = ev.io orelse return Error.FileError;

    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv.items) |arg| ev.allocator.free(arg);
        argv.deinit(ev.allocator);
    }
    try argv.append(ev.allocator, try stringArg(ev, args[0]));
    var rest = args[1];
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        try argv.append(ev.allocator, try stringArg(ev, heap.car(rest)));
    }
    if (!rest.equalsRaw(value.NIL)) return Error.TypeError;
    const directory = try stringArg(ev, args[2]);
    defer ev.allocator.free(directory);

    const result = std.process.run(ev.allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = directory },
    }) catch |err| {
        const reason = try ev.heap.allocString(@errorName(err));
        return ev.setValues(&.{ value.NIL, value.NIL, reason });
    };
    defer ev.allocator.free(result.stdout);
    defer ev.allocator.free(result.stderr);

    const code: i64 = switch (result.term) {
        .exited => |exit_code| exit_code,
        .signal => |signal| 128 + @as(i64, @backingInt(signal)),
        // The wait asks only for exits, so stops and continues are never reported.
        .stopped, .unknown => unreachable,
    };
    var held = ev.heap.protect();
    defer held.close();
    try held.push(try ev.heap.allocString(result.stdout));
    try held.push(try ev.heap.allocString(result.stderr));
    return ev.setValues(&.{ Value.fromFixnum(code), held.items()[0], held.items()[1] });
}

/// `(%getenv name)` is the value of the environment variable `name`, or
/// NIL when it is not set.
fn getenvFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const name = try stringArg(ev, args[0]);
    defer ev.allocator.free(name);
    const name_z = try ev.allocator.dupeSentinel(u8, name, 0);
    defer ev.allocator.free(name_z);
    const found = std.c.getenv(name_z) orelse return value.NIL;
    return ev.heap.allocString(std.mem.span(found));
}

/// `(%sha256-hex string)` is the SHA-256 of the UTF-8 of `string`, as
/// 64 lowercase hexadecimal digits.
fn sha256HexFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const bytes = try stringArg(ev, args[0]);
    defer ev.allocator.free(bytes);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return ev.heap.allocString(&hex);
}

fn printerSourceFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 0) return Error.WrongArgCount;
    return ev.heap.allocString(printer_source);
}
