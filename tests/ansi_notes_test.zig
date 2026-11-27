const std = @import("std");
const testing = std.testing;

const harness_files = [_][]const u8{
    "tests/lisp/ansi-rt.lisp",
    "tests/lisp/ansi-suite.lisp",
    "tests/lisp/ansi-category.lisp",
};

const failures_files = [_][]const u8{
    "tests/ansi-failures.txt",
    "tests/ansi-failures-compile.txt",
};

const doc_path = "docs/ansi-test.md";
const doc_heading = "## Notes switched off";
const disable_call = "(rt::disable-note :";

const NoteSet = std.StringArrayHashMapUnmanaged(void);

fn readRepoFile(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .unlimited);
}

fn addNote(arena: std.mem.Allocator, notes: *NoteSet, name: []const u8) !void {
    const lower = try std.ascii.allocLowerString(arena, name);
    try notes.put(arena, lower, {});
}

fn noteNameEnd(text: []const u8) usize {
    var index: usize = 0;
    while (index < text.len and (std.ascii.isAlphanumeric(text[index]) or text[index] == '-')) index += 1;
    return index;
}

fn harnessNotes(arena: std.mem.Allocator) !NoteSet {
    var notes: NoteSet = .empty;
    for (harness_files) |path| {
        const source = try readRepoFile(arena, path);
        var rest = source;
        while (std.mem.indexOf(u8, rest, disable_call)) |start| {
            rest = rest[start + disable_call.len ..];
            try addNote(arena, &notes, rest[0..noteNameEnd(rest)]);
        }
    }
    for (failures_files) |path| {
        const source = try readRepoFile(arena, path);
        var lines = std.mem.tokenizeScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (line.len > 1 and line[0] == ':') try addNote(arena, &notes, line[1 .. 1 + noteNameEnd(line[1..])]);
        }
    }
    return notes;
}

fn documentedNotes(arena: std.mem.Allocator) !NoteSet {
    var notes: NoteSet = .empty;
    const source = try readRepoFile(arena, doc_path);
    const start = std.mem.indexOf(u8, source, doc_heading) orelse return error.NotesSectionMissing;
    var section = source[start + doc_heading.len ..];
    if (std.mem.indexOf(u8, section, "\n## ")) |end| section = section[0..end];
    var lines = std.mem.tokenizeScalar(u8, section, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "- `:")) try addNote(arena, &notes, line[4 .. 4 + noteNameEnd(line[4..])]);
    }
    return notes;
}

fn expectSameNotes(expected: NoteSet, actual: NoteSet) !void {
    for (expected.keys()) |name| {
        if (!actual.contains(name)) {
            std.debug.print("note {s} is missing\n", .{name});
            return error.NoteListsDiffer;
        }
    }
    try testing.expectEqual(expected.count(), actual.count());
}

test "the notes the ansi-test harness switches off are the notes docs/ansi-test.md lists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const switched_off = try harnessNotes(arena);
    const documented = try documentedNotes(arena);

    try testing.expect(switched_off.count() > 0);
    try expectSameNotes(switched_off, documented);
    try expectSameNotes(documented, switched_off);
}
