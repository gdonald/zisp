//! The entry points a `wasm32-freestanding` zisp exports to its host,
//! such as JavaScript in a browser. The host copies source text into
//! memory from `zisp_alloc`, calls `zisp_eval` on it, and reads what the
//! evaluation printed from `zisp_output_ptr` and `zisp_output_len`.
//! `js:call` calls back into the host through `zisp_js_call`, as
//! `docs/wasm-interop.md` describes.

const std = @import("std");
const zisp = @import("zisp");

const Value = zisp.Value;
const Evaluator = zisp.Evaluator;
const Error = zisp.eval.function.NativeError;
const heap = zisp.heap;
const value = zisp.value;

const gpa = std.heap.wasm_allocator;

var output: std.Io.Writer.Allocating = undefined;
var session: ?*zisp.repl.Repl = null;
var reply: ?[]u8 = null;

extern "env" fn zisp_js_call(request: [*]const u8, len: usize) i32;

const js_package =
    \\(defpackage "JS" (:use "COMMON-LISP") (:export "CALL"))
    \\(defun js:call (name &rest arguments)
    \\  (multiple-value-bind (result threw) (%js-call name arguments)
    \\    (if threw (error "JavaScript: ~a" result) result)))
;

/// Start a session from the boot sources. 0 on success.
export fn zisp_init() i32 {
    if (session != null) return 0;
    output = .init(gpa);
    const repl = zisp.repl.Repl.init(gpa, &output.writer, null) catch return 1;
    const js_call = repl.ev.defineNative("%JS-CALL", &jsCallFn) catch return 1;
    zisp.eval.function.asFunction(js_call).preserves_values = true;
    repl.evalForms(js_package, false) catch return 1;
    session = repl;
    return 0;
}

/// `len` bytes the host can write into.
export fn zisp_alloc(len: usize) ?[*]u8 {
    const bytes = gpa.alloc(u8, len) catch return null;
    return bytes.ptr;
}

export fn zisp_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// The reply to the `zisp_js_call` in progress, in memory from `zisp_alloc`.
export fn zisp_reply(ptr: [*]u8, len: usize) void {
    reply = ptr[0..len];
}

/// Read, evaluate and print every form in the `len` bytes at `ptr`,
/// as the REPL does. The text printed replaces the previous output.
/// 0 when every form was read and evaluated, 1 otherwise.
export fn zisp_eval(ptr: [*]const u8, len: usize) i32 {
    const repl = session orelse return 1;
    output.clearRetainingCapacity();
    repl.run(ptr[0..len]) catch return 1;
    repl.out.flush() catch return 1;
    return 0;
}

export fn zisp_output_ptr() [*]const u8 {
    return output.written().ptr;
}

export fn zisp_output_len() usize {
    return output.written().len;
}

/// `(%js-call name arguments)`: the function's result and NIL, or the
/// message of what it threw and T.
fn jsCallFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len != 2) return Error.WrongArgCount;
    if (!heap.isString(args[0])) return Error.TypeError;

    var request = std.Io.Writer.Allocating.init(gpa);
    defer request.deinit();
    const w = &request.writer;
    w.writeAll("{\"function\":") catch return Error.OutOfMemory;
    try encode(ev, w, args[0]);
    w.writeAll(",\"arguments\":[") catch return Error.OutOfMemory;
    var rest = args[1];
    var first = true;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        if (!first) w.writeByte(',') catch return Error.OutOfMemory;
        first = false;
        try encode(ev, w, heap.car(rest));
    }
    w.writeAll("]}") catch return Error.OutOfMemory;

    reply = null;
    const threw = zisp_js_call(request.written().ptr, request.written().len) != 0;
    const text = reply orelse return Error.ProgramError;
    defer {
        gpa.free(text);
        reply = null;
    }
    if (threw) return ev.setValues(&.{ try ev.heap.allocString(text), value.T });
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return Error.ProgramError;
    defer parsed.deinit();
    var held = ev.heap.protect();
    defer held.close();
    try held.push(try decode(ev, &held, parsed.value));
    return ev.setValues(&.{ held.items()[0], value.NIL });
}

fn encode(ev: *Evaluator, w: *std.Io.Writer, v: Value) Error!void {
    encodeValue(ev, w, v) catch |e| switch (e) {
        error.WriteFailed => return Error.OutOfMemory,
        else => |other| return other,
    };
}

fn encodeValue(ev: *Evaluator, w: *std.Io.Writer, v: Value) (Error || std.Io.Writer.Error)!void {
    if (v.equalsRaw(value.NIL)) return w.writeAll("null");
    if (v.equalsRaw(value.T)) return w.writeAll("true");
    if (v.equalsRaw(try ev.interner.internKeyword("FALSE"))) return w.writeAll("false");
    if (v.isFixnum()) return w.print("{d}", .{v.toFixnum()});
    if (v.isChar()) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(v.toChar(), &buf) catch return Error.TypeError;
        return std.json.Stringify.encodeJsonString(buf[0..n], .{}, w);
    }
    if (heap.isString(v)) {
        const text = try heap.stringUtf8Alloc(gpa, v);
        defer gpa.free(text);
        return std.json.Stringify.encodeJsonString(text, .{}, w);
    }
    if (heap.isBignum(v) or heap.isRatio(v) or heap.isDoubleFloat(v) or v.tag() == .single_float) {
        const x = zisp.equality.toF64(v);
        if (!std.math.isFinite(x)) return Error.TypeError;
        return w.print("{d}", .{x});
    }
    if (v.isCons() or (heap.isArray(v) and heap.asArray(v).rank == 1)) {
        try w.writeByte('[');
        if (v.isCons()) {
            var rest = v;
            while (rest.isCons()) : (rest = heap.cdr(rest)) {
                if (rest.toConsAddr() != v.toConsAddr()) try w.writeByte(',');
                try encodeValue(ev, w, heap.car(rest));
            }
            if (!rest.equalsRaw(value.NIL)) return Error.TypeError;
        } else {
            for (heap.arrayActive(v), 0..) |element, index| {
                if (index > 0) try w.writeByte(',');
                try encodeValue(ev, w, element);
            }
        }
        return w.writeByte(']');
    }
    return Error.TypeError;
}

fn decode(ev: *Evaluator, held: anytype, json: std.json.Value) Error!Value {
    switch (json) {
        .null => return value.NIL,
        .bool => |b| return if (b) value.T else ev.interner.internKeyword("FALSE"),
        .integer => |n| {
            if (n >= value.FIXNUM_MIN and n <= value.FIXNUM_MAX) return Value.fromFixnum(n);
            return ev.heap.allocDoubleFloat(@floatFromInt(n));
        },
        .float => |x| return ev.heap.allocDoubleFloat(x),
        .number_string => |text| return ev.heap.allocDoubleFloat(std.fmt.parseFloat(f64, text) catch return Error.ProgramError),
        .string => |text| return ev.heap.allocString(text),
        .array => |items| {
            const start = held.items().len;
            for (items.items) |item| try held.push(try decode(ev, held, item));
            const vector = try ev.heap.allocVector(held.items()[start..]);
            dropTo(held, start);
            return vector;
        },
        .object => |map| {
            const start = held.items().len;
            var it = map.iterator();
            while (it.next()) |entry| {
                try held.push(try ev.heap.allocString(entry.key_ptr.*));
                try held.push(try decode(ev, held, entry.value_ptr.*));
                const pair = try ev.heap.allocCons(held.items()[held.items().len - 2], held.items()[held.items().len - 1]);
                _ = held.pop();
                held.setItem(held.items().len - 1, pair);
            }
            const alist = try ev.heap.list(held.items()[start..]);
            dropTo(held, start);
            return alist;
        },
    }
}

fn dropTo(held: anytype, len: usize) void {
    while (held.items().len > len) _ = held.pop();
}
