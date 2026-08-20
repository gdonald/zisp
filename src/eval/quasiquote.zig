//! Quasiquote expansion. `expand` turns a backquote template into an
//! equivalent form built from `quote`, `list`, and `append` calls.
//!
//! Depth counting follows CLtL2 appendix C: each nested `quasiquote`
//! increments the depth, each `unquote` / `unquote-splicing` decrements it,
//! and only depth-zero unquotes evaluate. Deeper markers are rebuilt as
//! data, with their subform list processed as a template one level down, so
//! a depth-zero splice inside a deeper marker distributes into that
//! marker's subforms (the `` ``(,,@q) `` cases). A later expansion round
//! then sees markers like `(unquote 1 2)`, whose subforms all evaluate.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const eval_mod = @import("eval.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = eval_mod.Error;

const Syms = struct {
    quasiquote: Value,
    unquote: Value,
    splicing: Value,
    quote: Value,
    list: Value,
    append: Value,
};

pub fn expand(ev: *Evaluator, template: Value) Error!Value {
    const syms = Syms{
        .quasiquote = try ev.interner.intern("QUASIQUOTE"),
        .unquote = try ev.interner.intern("UNQUOTE"),
        .splicing = try ev.interner.intern("UNQUOTE-SPLICING"),
        .quote = try ev.interner.intern("QUOTE"),
        .list = try ev.interner.intern("LIST"),
        .append = try ev.interner.intern("APPEND"),
    };
    return qq(ev, &syms, template, 0);
}

fn make2(ev: *Evaluator, a: Value, b: Value) Error!Value {
    var held = ev.heap.protect();
    defer held.close();
    try held.push(a);
    try held.push(b);
    const tail = try ev.heap.allocCons(b, value.NIL);
    held.setItem(1, tail);
    return ev.heap.allocCons(a, tail);
}

fn quoteOf(ev: *Evaluator, syms: *const Syms, v: Value) Error!Value {
    return make2(ev, syms.quote, v);
}

/// The single subform of a depth-zero `(unquote . tail)`.
fn expectOne(tail: Value) Error!Value {
    if (!tail.isCons()) return Error.ProgramError;
    if (!heap.cdr(tail).equalsRaw(value.NIL)) return Error.ProgramError;
    return heap.car(tail);
}

fn expectProperList(v: Value) Error!void {
    var cur = v;
    while (!cur.equalsRaw(value.NIL)) {
        if (!cur.isCons()) return Error.ProgramError;
        cur = heap.cdr(cur);
    }
}

/// Rebuild a marker form as data for a deeper expansion round:
/// `(append (list 'marker) <qq of the subform list>)`. Processing the
/// subforms as a list template lets depth-zero splices distribute into the
/// rebuilt marker.
fn rebuild(ev: *Evaluator, syms: *const Syms, marker: Value, forms: Value, depth: u32) Error!Value {
    var held = ev.heap.protect();
    defer held.close();
    const marker_seg = try make2(ev, syms.list, try quoteOf(ev, syms, marker));
    try held.push(marker_seg);
    const rest = try qq(ev, syms, forms, depth);
    try held.push(rest);
    const pair = try make2(ev, marker_seg, rest);
    try held.push(pair);
    return ev.heap.allocCons(syms.append, pair);
}

fn qq(ev: *Evaluator, syms: *const Syms, x: Value, depth: u32) Error!Value {
    if (!x.isCons()) return quoteOf(ev, syms, x);

    const head = heap.car(x);
    if (head.equalsRaw(syms.unquote)) {
        if (depth == 0) return expectOne(heap.cdr(x));
        return rebuild(ev, syms, syms.unquote, heap.cdr(x), depth - 1);
    }
    if (head.equalsRaw(syms.splicing)) {
        // Valid only as a list element; element splices are handled below,
        // so reaching here at depth zero is the `,@x at top level error.
        if (depth == 0) return Error.ProgramError;
        return rebuild(ev, syms, syms.splicing, heap.cdr(x), depth - 1);
    }
    if (head.equalsRaw(syms.quasiquote)) {
        return rebuild(ev, syms, syms.quasiquote, heap.cdr(x), depth + 1);
    }

    // General list: (append seg... tail). Each plain element contributes
    // (list <qq of element>); a depth-zero splice contributes each of its
    // subforms; a depth-zero multi-subform unquote (from a distributed
    // splice in an earlier round) contributes (list <subforms...>).
    // The segments built so far are reachable from nothing else while
    // the next one is built, and building allocates.
    var segs = ev.heap.protect();
    defer segs.close();

    var tail: Value = undefined;
    var last_was_splice = false;
    var cur = x;
    while (true) {
        if (!cur.isCons()) {
            if (cur.equalsRaw(value.NIL) and last_was_splice) {
                // A final splice may produce a dotted tail; don't append
                // a trailing 'nil after it.
                tail = segs.pop().?;
            } else {
                tail = try quoteOf(ev, syms, cur);
            }
            break;
        }
        const h = heap.car(cur);
        // A marker in cdr position ends the spine: `(a . ,b) reads as
        // (a unquote b), so a marker symbol mid-spine is a dotted tail.
        // The head of x itself was screened above.
        if (h.isSymbol()) {
            if (h.equalsRaw(syms.unquote)) {
                tail = if (depth == 0)
                    try expectOne(heap.cdr(cur))
                else
                    try rebuild(ev, syms, syms.unquote, heap.cdr(cur), depth - 1);
                break;
            }
            if (h.equalsRaw(syms.splicing)) {
                if (depth == 0) return Error.ProgramError;
                tail = try rebuild(ev, syms, syms.splicing, heap.cdr(cur), depth - 1);
                break;
            }
            if (h.equalsRaw(syms.quasiquote)) {
                tail = try rebuild(ev, syms, syms.quasiquote, heap.cdr(cur), depth + 1);
                break;
            }
        }
        if (depth == 0 and h.isCons() and heap.car(h).equalsRaw(syms.splicing)) {
            const forms = heap.cdr(h);
            try expectProperList(forms);
            var f = forms;
            while (!f.equalsRaw(value.NIL)) {
                try segs.push(heap.car(f));
                f = heap.cdr(f);
            }
            last_was_splice = !forms.equalsRaw(value.NIL);
        } else if (depth == 0 and h.isCons() and heap.car(h).equalsRaw(syms.unquote) and
            heap.cdr(h).isCons() and !heap.cdr(heap.cdr(h)).equalsRaw(value.NIL))
        {
            // (unquote f1 f2 ...) from a distributed splice: every subform
            // evaluates to its own element.
            const forms = heap.cdr(h);
            try expectProperList(forms);
            try segs.push(try ev.heap.allocCons(syms.list, forms));
            last_was_splice = false;
        } else {
            try segs.push(try make2(ev, syms.list, try qq(ev, syms, h, depth)));
            last_was_splice = false;
        }
        cur = heap.cdr(cur);
    }

    var built = ev.heap.protect();
    defer built.close();
    try built.push(tail);
    var form = try ev.heap.allocCons(tail, value.NIL);
    built.setItem(0, form);
    built.setItem(0, form);
    var i = segs.len;
    while (i > 0) {
        i -= 1;
        form = try ev.heap.allocCons(segs.items()[i], form);
        built.setItem(0, form);
    }
    return ev.heap.allocCons(syms.append, form);
}
