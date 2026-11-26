const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const build_options = @import("build_options");

const file_system_functions = [_][]const u8{
    "open",                 "file-length",
    "load",                 "compile-file",
    "truename",             "probe-file",
    "file-write-date",      "delete-file",
    "rename-file",          "ensure-directories-exist",
    "directory",            "ext::delete-directory",
    "ext::save-image",      "pathname",
    "make-pathname",        "merge-pathnames",
    "namestring",           "file-namestring",
    "directory-namestring", "pathname-name",
    "parse-namestring",     "translate-pathname",
    "logical-pathname",     "logical-pathname-translations",
};

fn evaluate(source: []const u8) ![]u8 {
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    errdefer output.deinit();
    const repl = try zisp.repl.Repl.init(testing.allocator, &output.writer, null);
    defer repl.deinit();
    try repl.run(source);
    return output.toOwnedSlice();
}

fn expectEvaluates(source: []const u8, expected: []const u8) !void {
    const written = try evaluate(source);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(expected, written);
}

test "the file system functions are defined only in a build with a file system" {
    for (file_system_functions) |name| {
        const source = try std.fmt.allocPrint(testing.allocator, "(fboundp '{s})", .{name});
        defer testing.allocator.free(source);
        const written = try evaluate(source);
        defer testing.allocator.free(written);
        const expected = if (build_options.freestanding) "NIL\n" else "T\n";
        testing.expectEqualStrings(expected, written) catch |e| {
            std.debug.print("(fboundp '{s})\n", .{name});
            return e;
        };
    }
}

test "a build with no file system signals an error reading #P" {
    const expected = if (build_options.freestanding) ":ERROR\n" else "T\n";
    try expectEvaluates(
        \\(handler-case (pathnamep (read-from-string "#P\"notes.txt\""))
        \\  (error () :error))
    , expected);
}

test "with-open-file signals undefined-function in a build with no file system" {
    const expected = if (build_options.freestanding) ":UNDEFINED-FUNCTION\n" else ":FILE-ERROR\n";
    try expectEvaluates(
        \\(handler-case (with-open-file (in "notes.txt") (read-line in))
        \\  (undefined-function () :undefined-function)
        \\  (file-error () :file-error))
    , expected);
}

test "string streams, read-sequence and pathnamep work with or without a file system" {
    try expectEvaluates(
        \\(let ((text (make-string 3)))
        \\  (read-sequence text (make-string-input-stream "abc"))
        \\  text)
        \\(with-output-to-string (out) (write-sequence "xyz" out))
        \\(close (make-string-output-stream))
        \\(pathnamep "notes.txt")
    , "\"abc\"\n\"xyz\"\nT\nNIL\n");
}
