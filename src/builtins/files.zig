//! The file system operations under `delete-file`, `rename-file`,
//! `ensure-directories-exist` and `directory` in `src/lisp/files.lisp`.
//! Each takes namestrings and signals `file-error` when the operating
//! system refuses.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const pathnames = @import("pathnames.zig");
const fs = @import("fs.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerFiles(ev: *Evaluator) !void {
    _ = try ev.defineNative("%DELETE-FILE", &deleteFileFn);
    _ = try ev.defineNative("%RENAME-FILE", &renameFileFn);
    _ = try ev.defineNative("%CREATE-DIRECTORIES", &createDirectoriesFn);
    _ = try ev.defineNative("%DIRECTORY-ENTRIES", &directoryEntriesFn);
    const delete_directory = try ev.interner.internExtension("DELETE-DIRECTORY");
    symbol_mod.symbol(delete_directory).function_cell = try ev.makeNative("DELETE-DIRECTORY", &deleteDirectoryFn);
}

fn pathArg(ev: *Evaluator, v: Value) Error![]const u8 {
    return pathnames.namestringOf(ev.heap.allocator, v);
}

fn deleteFileFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const io = ev.io orelse return Error.FileError;
    try fs.deleteFile(io, try pathArg(ev, args[0]));
    return value.T;
}

fn renameFileFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const io = ev.io orelse return Error.FileError;
    try fs.rename(io, try pathArg(ev, args[0]), try pathArg(ev, args[1]));
    return value.T;
}

/// `(ext:delete-directory pathspec)` removes an empty directory.
fn deleteDirectoryFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const io = ev.io orelse return Error.FileError;
    try fs.deleteDirectory(io, try pathArg(ev, args[0]));
    return value.T;
}

/// T when a directory had to be made, NIL when they all existed.
fn createDirectoriesFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const io = ev.io orelse return Error.FileError;
    return if (try fs.createDirectories(io, try pathArg(ev, args[0]))) value.T else value.NIL;
}

/// The names in a directory, each a string, with a `/` after the name of
/// a subdirectory.
fn directoryEntriesFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const io = ev.io orelse return Error.FileError;
    const given = try pathArg(ev, args[0]);
    const names = try fs.directoryEntries(io, ev.allocator, if (given.len == 0) "." else given);
    defer {
        for (names) |name| ev.allocator.free(name);
        ev.allocator.free(names);
    }

    var held = ev.heap.protect();
    defer held.close();
    try held.push(value.NIL);
    for (names) |name| {
        const text = try ev.heap.allocString(name);
        try held.push(text);
        held.setItem(0, try ev.heap.allocCons(text, held.items()[0]));
        _ = held.pop();
    }
    return held.items()[0];
}
