//! Writes `zisp-wasm.js`, which sets `globalThis.zispWasm` to the bytes of
//! the module and `globalThis.zispDemo` to the demo program, so the REPL
//! page works when opened from disk, where it cannot fetch files.
//!
//!   embed-wasm <zisp.wasm> <demo.lisp> <zisp-wasm.js>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.Usage;

    const cwd = std.Io.Dir.cwd();
    const wasm = try cwd.readFileAlloc(io, args[1], gpa, .unlimited);
    defer gpa.free(wasm);
    const demo = try cwd.readFileAlloc(io, args[2], gpa, .unlimited);
    defer gpa.free(demo);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("globalThis.zispWasm = Uint8Array.from(atob(\"");
    try std.base64.standard.Encoder.encodeWriter(w, wasm);
    try w.writeAll("\"), (c) => c.charCodeAt(0));\nglobalThis.zispDemo = ");
    try std.json.Stringify.encodeJsonString(demo, .{}, w);
    try w.writeAll(";\n");
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = out.written() });
}
