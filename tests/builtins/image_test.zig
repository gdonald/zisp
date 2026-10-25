//! Saving a whole session to an image and starting a new one from it.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;
const Value = value.Value;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: zisp.Heap,
    aw: std.Io.Writer.Allocating,
    ev: Evaluator,

    /// A session from the boot sources, or from the image at `image`.
    fn init(allocator: std.mem.Allocator, image: ?[]const u8) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = try symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .aw = std.Io.Writer.Allocating.init(allocator),
            .ev = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        fx.ev.out = &fx.aw.writer;
        fx.ev.io = std.testing.io;
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        if (image) |path| {
            try zisp.builtins.registerNatives(&fx.ev);
            try zisp.builtins.registerSystem(&fx.ev);
            try zisp.builtins.image.loadPath(&fx.ev, path);
        } else {
            try zisp.builtins.registerStandard(&fx.ev);
            try zisp.builtins.registerSystem(&fx.ev);
        }
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.aw.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn evalStr(self: *Fixture, src: []const u8) !Value {
        var tk = zisp.reader.Tokenizer.init(src);
        var rd = zisp.reader.Reader.init(&tk, &self.heap, &self.interner);
        var result = value.NIL;
        while (try rd.read()) |form| result = try self.ev.evalTopLevel(form);
        return result;
    }
};

const session =
    \\(defun image-test-fn (x) (* x 7))
    \\(defparameter *image-test-value* (list 1 "two" 3.5 (expt 2 70)))
    \\(defclass image-test-shape () ((sides :initarg :sides :reader image-test-sides)))
    \\(defgeneric image-test-describe (shape))
    \\(defmethod image-test-describe ((shape image-test-shape))
    \\  (format nil "~d sides" (image-test-sides shape)))
    \\(let ((count 0)) (defun image-test-count () (incf count)))
    \\(image-test-count)
    \\(compile 'image-test-fn)
;

fn saveSession(path: []const u8) !void {
    const fx = try Fixture.init(testing.allocator, null);
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr(session);
    const form = try std.fmt.allocPrint(testing.allocator, "(ext:save-image \"{s}\")", .{path});
    defer testing.allocator.free(form);
    try testing.expect((try fx.evalStr(form)).equalsRaw(value.T));
}

test "an image of a session starts a session where its definitions work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/session.zimg", .{tmp.sub_path});
    defer testing.allocator.free(path);
    try saveSession(path);

    const fx = try Fixture.init(testing.allocator, path);
    defer fx.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 42), (try fx.evalStr("(image-test-fn 6)")).toFixnum());
    try testing.expect((try fx.evalStr("(compiled-function-p #'image-test-fn)")).equalsRaw(value.T));
    try testing.expect((try fx.evalStr("(equal *image-test-value* (list 1 \"two\" 3.5 (expt 2 70)))")).equalsRaw(value.T));
    try testing.expect((try fx.evalStr(
        \\(equal (image-test-describe (make-instance 'image-test-shape :sides 5)) "5 sides")
    )).equalsRaw(value.T));
    try testing.expectEqual(@as(i64, 2), (try fx.evalStr("(image-test-count)")).toFixnum());
    try testing.expect((try fx.evalStr("(equal (loop for i below 3 collect (* i i)) '(0 1 4))")).equalsRaw(value.T));
}

test "the same session saved twice gives the same bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/same.zimg", .{tmp.sub_path});
    defer testing.allocator.free(path);
    try saveSession(path);
    const first = try tmp.dir.readFileAlloc(std.testing.io, "same.zimg", testing.allocator, .unlimited);
    defer testing.allocator.free(first);
    try saveSession(path);
    const second = try tmp.dir.readFileAlloc(std.testing.io, "same.zimg", testing.allocator, .unlimited);
    defer testing.allocator.free(second);
    try testing.expect(std.mem.startsWith(u8, first, "ZISPIMG"));
    try testing.expectEqualSlices(u8, first, second);
}
