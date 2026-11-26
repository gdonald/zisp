//! Prints a comptime-known Zig value or type as the text of a Lisp form.
//! zisp writes this file next to each program `comptime-eval` builds.

const std = @import("std");

pub fn print(comptime value: anytype) []const u8 {
    comptime {
        const T = @TypeOf(value);
        if (T == type) return describe(value);
        return switch (@typeInfo(T)) {
            .comptime_int, .int => std.fmt.comptimePrint("{d}", .{value}),
            .bool => if (value) "T" else "NIL",
            .null => "NIL",
            .optional => if (value) |payload| print(payload) else "NIL",
            .enum_literal, .@"enum" => ":" ++ lispName(@tagName(value)),
            .array => list(value),
            .pointer => |info| switch (info.size) {
                .one => if (isText(info.child)) quote(value) else print(value.*),
                .slice => if (info.child == u8) quote(value) else list(value),
                else => @compileError("no Lisp form for " ++ @typeName(T)),
            },
            .@"struct" => |info| if (info.is_tuple) list(value) else plist(value),
            else => @compileError("no Lisp form for " ++ @typeName(T)),
        };
    }
}

fn isText(comptime Child: type) bool {
    return switch (@typeInfo(Child)) {
        .array => |info| info.child == u8,
        else => false,
    };
}

fn quote(comptime text: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        for (text) |char| {
            if (char == '"' or char == '\\') out = out ++ "\\";
            out = out ++ [_]u8{char};
        }
        return out ++ "\"";
    }
}

fn list(comptime items: anytype) []const u8 {
    comptime {
        var out: []const u8 = "(";
        for (items, 0..) |item, index| {
            if (index > 0) out = out ++ " ";
            out = out ++ print(item);
        }
        return out ++ ")";
    }
}

fn plist(comptime value: anytype) []const u8 {
    comptime {
        var out: []const u8 = "(";
        for (@typeInfo(@TypeOf(value)).@"struct".field_names, 0..) |name, index| {
            if (index > 0) out = out ++ " ";
            out = out ++ ":" ++ lispName(name) ++ " " ++ print(@field(value, name));
        }
        return out ++ ")";
    }
}

fn describe(comptime T: type) []const u8 {
    comptime {
        return switch (@typeInfo(T)) {
            .int => |info| std.fmt.comptimePrint("(:{s} {d})", .{ if (info.signedness == .signed) "SIGNED" else "UNSIGNED", info.bits }),
            .float => |info| std.fmt.comptimePrint("(:FLOAT {d})", .{info.bits}),
            .bool => ":BOOL",
            .pointer => ":POINTER",
            .optional => |info| if (@typeInfo(info.child) == .pointer) ":POINTER" else @compileError("no Lisp form for " ++ @typeName(T)),
            .@"struct" => |info| fields: {
                var out: []const u8 = std.fmt.comptimePrint("(:STRUCT :SIZE {d} :ALIGNMENT {d}", .{ @sizeOf(T), @alignOf(T) });
                for (info.field_names, info.field_types) |name, field_type| {
                    out = out ++ std.fmt.comptimePrint(" (:{s} :OFFSET {d} :TYPE {s})", .{ lispName(name), @offsetOf(T, name), describe(field_type) });
                }
                break :fields out ++ ")";
            },
            else => @compileError("no Lisp form for " ++ @typeName(T)),
        };
    }
}

fn lispName(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        for (name, 0..) |char, index| out[index] = if (char == '_') '-' else std.ascii.toUpper(char);
        const final = out;
        return &final;
    }
}
