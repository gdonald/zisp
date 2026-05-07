// Test root. Every test file in tests/ must be imported here so `zig build tests`
// discovers it. Implementation modules under src/ contain no test blocks.

comptime {
    _ = @import("runtime/value_test.zig");
    _ = @import("runtime/heap_test.zig");
    _ = @import("runtime/symbol_test.zig");
    _ = @import("runtime/printer_test.zig");
    _ = @import("runtime/log_test.zig");
    _ = @import("runtime/read_all_test.zig");
    _ = @import("reader/tokenizer_test.zig");
    _ = @import("reader/float_parse_test.zig");
    _ = @import("reader/reader_test.zig");
    _ = @import("reader/feature_expr_test.zig");
    _ = @import("reader/golden_test.zig");
    _ = @import("reader/roundtrip_test.zig");
    _ = @import("reader/fuzz_test.zig");
    _ = @import("eval/env_test.zig");
    _ = @import("cli_test.zig");
}
