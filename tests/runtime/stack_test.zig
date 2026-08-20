//! The Lisp value stack.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const stack_mod = zisp.stack;
const Value = value.Value;

fn newStack() stack_mod.Stack {
    return stack_mod.Stack.init(testing.allocator);
}

test "a region reports what was pushed onto it" {
    var stack = newStack();
    defer stack.deinit();
    var region = stack.open();
    defer region.close();

    try region.push(Value.fromFixnum(1));
    try region.push(Value.fromFixnum(2));

    const items = region.items();
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(@as(i64, 1), items[0].toFixnum());
    try testing.expectEqual(@as(i64, 2), items[1].toFixnum());
}

test "an empty region has no items" {
    var stack = newStack();
    defer stack.deinit();
    var region = stack.open();
    defer region.close();

    try testing.expectEqual(@as(usize, 0), region.items().len);
}

test "closing a region gives its slots back" {
    var stack = newStack();
    defer stack.deinit();
    const before = stack.mark();
    var region = stack.open();
    try region.push(Value.fromFixnum(1));

    region.close();

    try testing.expectEqual(before.chunk, stack.mark().chunk);
    try testing.expectEqual(before.top, stack.mark().top);
}

test "clearing a region keeps it open for refilling" {
    var stack = newStack();
    defer stack.deinit();
    var region = stack.open();
    defer region.close();
    try region.push(Value.fromFixnum(1));

    region.clear();
    try region.push(Value.fromFixnum(9));

    try testing.expectEqual(@as(usize, 1), region.items().len);
    try testing.expectEqual(@as(i64, 9), region.items()[0].toFixnum());
}

test "a region above another leaves the one below alone" {
    var stack = newStack();
    defer stack.deinit();
    var lower = stack.open();
    defer lower.close();
    try lower.push(Value.fromFixnum(1));
    {
        var upper = stack.open();
        defer upper.close();
        try upper.push(Value.fromFixnum(2));
        try testing.expectEqual(@as(i64, 2), upper.items()[0].toFixnum());
    }

    try testing.expectEqual(@as(usize, 1), lower.items().len);
    try testing.expectEqual(@as(i64, 1), lower.items()[0].toFixnum());
}

test "a run longer than a chunk stays contiguous" {
    var stack = newStack();
    defer stack.deinit();
    var region = stack.open();
    defer region.close();

    const count = stack_mod.CHUNK_SLOTS + 10;
    for (0..count) |i| try region.push(Value.fromFixnum(@intCast(i)));

    const items = region.items();
    try testing.expectEqual(count, items.len);
    for (items, 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(i)), v.toFixnum());
    try testing.expect(stack.chunkCount() > 1);
}

test "a run that outgrows its chunk leaves what was below it in place" {
    var stack = newStack();
    defer stack.deinit();
    var lower = stack.open();
    defer lower.close();
    try lower.push(Value.fromFixnum(7));

    var region = stack.open();
    defer region.close();
    for (0..stack_mod.CHUNK_SLOTS + 1) |i| try region.push(Value.fromFixnum(@intCast(i)));

    try testing.expectEqual(@as(i64, 7), lower.items()[0].toFixnum());
}

test "every value in use is reachable through the chunks" {
    var stack = newStack();
    defer stack.deinit();
    var region = stack.open();
    defer region.close();
    const count = stack_mod.CHUNK_SLOTS + 5;
    for (0..count) |_| try region.push(Value.fromFixnum(3));

    var seen: usize = 0;
    var chunk: usize = 0;
    while (chunk < stack.chunkCount()) : (chunk += 1) {
        for (stack.live(chunk)) |v| {
            try testing.expectEqual(@as(i64, 3), v.toFixnum());
            seen += 1;
        }
    }

    try testing.expectEqual(count, seen);
}

test "a released run is no longer reported as in use" {
    var stack = newStack();
    defer stack.deinit();
    {
        var region = stack.open();
        defer region.close();
        for (0..100) |_| try region.push(Value.fromFixnum(3));
    }

    var seen: usize = 0;
    var chunk: usize = 0;
    while (chunk < stack.chunkCount()) : (chunk += 1) seen += stack.live(chunk).len;

    try testing.expectEqual(@as(usize, 0), seen);
}

test "a chunk past the end holds nothing" {
    var stack = newStack();
    defer stack.deinit();

    try testing.expectEqual(@as(usize, 0), stack.live(99).len);
}

test "popping hands back the last value pushed" {
    var stack = newStack();
    defer stack.deinit();
    var region = stack.open();
    defer region.close();
    try region.push(Value.fromFixnum(1));
    try region.push(Value.fromFixnum(2));

    const popped = region.pop();

    try testing.expectEqual(@as(i64, 2), popped.?.toFixnum());
    try testing.expectEqual(@as(usize, 1), region.items().len);
}

test "popping an empty region hands back nothing" {
    var stack = newStack();
    defer stack.deinit();
    var region = stack.open();
    defer region.close();

    try testing.expectEqual(@as(?Value, null), region.pop());
}

test "a slot can be replaced after it was pushed" {
    var stack = newStack();
    defer stack.deinit();
    var region = stack.open();
    defer region.close();
    try region.push(Value.fromFixnum(1));

    region.setItem(0, Value.fromFixnum(9));

    try testing.expectEqual(@as(i64, 9), region.items()[0].toFixnum());
}

test "a run below one that moved chunks can still grow" {
    var stack = newStack();
    defer stack.deinit();
    var lower = stack.open();
    defer lower.close();
    try lower.push(Value.fromFixnum(1));
    {
        var upper = stack.open();
        defer upper.close();
        for (0..stack_mod.CHUNK_SLOTS + 1) |_| try upper.push(Value.fromFixnum(2));
    }

    try lower.push(Value.fromFixnum(3));

    try testing.expectEqual(@as(usize, 2), lower.items().len);
    try testing.expectEqual(@as(i64, 3), lower.items()[1].toFixnum());
}
