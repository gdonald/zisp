//! Reader fuzz tests.
//!
//! Reader fuzzer driven by Zig's `std.testing.fuzz` / `std.testing.Smith`
//! infrastructure. The property is "never panic": for any byte sequence,
//! the reader must either succeed or return one of the documented
//! reader errors (`EndOfInput`, `UnbalancedParens`, `BadToken`, or an
//! allocator error). Crashes, infinite loops, or unhandled errors fail
//! the test.
//!
//! `zig build tests` runs this once per test invocation against a
//! Smith-generated input. `zig build fuzz-reader` runs the same test
//! with `-ffuzz` instrumentation enabled, suitable for sustained
//! fuzzing — invoke as `zig build fuzz-reader -- --fuzz` to engage the
//! Zig fuzzer's input-mutation loop (CTRL-C to stop).

const std = @import("std");
const zisp = @import("zisp");

const ReaderError = zisp.reader.ReaderError;

fn fuzzReader(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    // Bias the byte distribution toward syntactically interesting chars
    // so single-byte mutations are more likely to hit reader paths than
    // skipping arbitrary high-byte garbage. The full byte range still
    // appears, just less often.
    const len = smith.sliceWeightedBytes(&buf, &.{
        .rangeAtMost(u8, 0x00, 0xFF, 1),
        .rangeAtMost(u8, 0x20, 0x7E, 4),
        .value(u8, '(', 6),
        .value(u8, ')', 6),
        .value(u8, ' ', 4),
        .value(u8, '\n', 2),
        .value(u8, '"', 3),
        .value(u8, '\\', 3),
        .value(u8, '#', 3),
        .value(u8, '\'', 2),
        .value(u8, '`', 2),
        .value(u8, ',', 2),
        .value(u8, '|', 2),
        .value(u8, '.', 2),
        .value(u8, ';', 1),
    });
    const source = buf[0..len];

    const a = std.testing.allocator;
    // Only the allocator can bubble up here — `parseAll` itself returns
    // outcomes for reader-shape failures, not errors. Treat OOM as
    // infrastructure noise.
    const outcome = zisp.read_all.parseAll(a, source, "fuzz") catch |e| switch (e) {
        error.OutOfMemory => return,
    };

    // Property: result is one of the documented variants. Absence of a
    // crash is the actual test; this last switch exists so a future
    // refactor of `Outcome` doesn't silently bypass the fuzzer.
    switch (outcome) {
        .ok => {},
        .fail => |info| {
            try std.testing.expect(info.pos.line >= 0);
            const e = info.err;
            const ok = (e == ReaderError.EndOfInput) or
                (e == ReaderError.UnbalancedParens) or
                (e == ReaderError.BadToken) or
                (e == ReaderError.OutOfMemory);
            try std.testing.expect(ok);
        },
    }
}

test "reader fuzz: no input crashes the reader" {
    try std.testing.fuzz({}, fuzzReader, .{});
}

// Deterministic PRNG-driven loop that runs every invocation, even when
// the binary isn't built with `-ffuzz`. Generates 2000 random byte
// strings biased toward syntactically interesting characters and
// verifies the same no-panic property.
test "reader fuzz: deterministic mass invocation" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xfeed_face_cafe_babe);
    const rand = prng.random();

    const interesting: []const u8 =
        "()'`,@#\\| .;\"abc012";

    var iters: u32 = 0;
    while (iters < 2000) : (iters += 1) {
        var buf: [128]u8 = undefined;
        const len = rand.uintLessThan(u32, buf.len);
        for (buf[0..len]) |*b| {
            // 70% interesting char, 30% arbitrary byte.
            if (rand.uintLessThan(u32, 100) < 70) {
                b.* = interesting[rand.uintLessThan(usize, interesting.len)];
            } else {
                b.* = rand.int(u8);
            }
        }
        const outcome = zisp.read_all.parseAll(a, buf[0..len], "fuzz") catch |e| switch (e) {
            error.OutOfMemory => continue,
        };
        switch (outcome) {
            .ok => {},
            .fail => |info| {
                const e = info.err;
                const ok = (e == ReaderError.EndOfInput) or
                    (e == ReaderError.UnbalancedParens) or
                    (e == ReaderError.BadToken) or
                    (e == ReaderError.OutOfMemory);
                try std.testing.expect(ok);
            },
        }
    }
}
