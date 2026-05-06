const std = @import("std");
const builtin = @import("builtin");
const zisp = @import("zisp");
const log = zisp.log;

test "every category name round-trips through the public API" {
    const Cats = [_]log.Category{ .gc, .reader, .eval, .compile, .cli };
    inline for (Cats) |c| {
        log.setEnabled(c, false);
        _ = log.isEnabled(c);
    }
    // Force the log() call sites to compile without emitting under Debug
    // (where every category is hard-on and would otherwise spam stderr).
    comptime {
        _ = &log.log;
    }
}

test "isEnabled obeys the per-mode contract" {
    // setEnabled writes the flag; isEnabled's response depends on the build
    // mode. One test, three branches — no skips.
    log.setEnabled(.gc, true);
    log.setEnabled(.reader, false);

    switch (builtin.mode) {
        .Debug => {
            // Every category hard-on regardless of the flag.
            try std.testing.expect(log.isEnabled(.gc));
            try std.testing.expect(log.isEnabled(.reader));
        },
        .ReleaseFast, .ReleaseSmall => {
            // Every category hard-off regardless of the flag.
            try std.testing.expect(!log.isEnabled(.gc));
            try std.testing.expect(!log.isEnabled(.reader));
        },
        .ReleaseSafe => {
            // Flag is honored.
            try std.testing.expect(log.isEnabled(.gc));
            try std.testing.expect(!log.isEnabled(.reader));
        },
    }

    // Restore.
    log.setEnabled(.gc, false);
    log.setEnabled(.reader, false);
}
