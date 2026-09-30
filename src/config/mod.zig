// Config subsystem: TOML parser + schema + loader.
//
// We ship a small hand-written TOML parser sufficient for pun's config.
// It supports:
//   - sections: [a.b.c]
//   - key = value with value ∈ {string, int, float, bool, array, inline-table}
//   - line comments with '#'
//   - bare keys and quoted keys
//   - multiline arrays
//   - basic strings ("...") with simple escapes, literal strings ('...')
//
// Not supported (will error): datetimes, multi-line strings, table arrays.
// If pun grows to need those, vendor toml-parser from ziglibs.

pub const parser = @import("parser.zig");
pub const schema = @import("schema.zig");
pub const loader = @import("loader.zig");
pub const hot_reload = @import("hot_reload.zig");

pub const Config = schema.Config;
pub const loadConfig = loader.loadConfig;
pub const initConfig = loader.initConfig;
pub const printConfig = loader.printConfig;

test {
    @import("std").testing.refAllDecls(@This());
}
