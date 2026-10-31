//! `dksh --tree`: draw the syntax tree as ASCII art.
//!
//!   Program
//!   |-- var x
//!   |   `-- + 
//!   `-- call print

const std = @import("std");
const ast = @import("ast.zig");
const mem = @import("mem.zig");
const source = @import("source.zig");

const Node = struct {
    label: []const u8,
    kids: std.ArrayList(*Node) = .empty,

    fn add(n: *Node, child: *Node) void {
        n.kids.append(mem.gpa, child) catch @panic("out of memory");
    }
};

fn node(comptime fmt: []const u8, args: anytype) *Node {
    const n = mem.gpa.create(Node) catch @panic("out of memory");
    n.* = .{ .label = mem.print(fmt, args) };
    return n;
}

fn quoted(s: []const u8) []const u8 {
    var o: std.ArrayList(u8) = .empty;
    o.append(mem.gpa, '"') catch {};
    for (s) |c| switch (c) {
        '\n' => o.appendSlice(mem.gpa, "\\n") catch {},
        '\t' => o.appendSlice(mem.gpa, "\\t") catch {},
        '"' => o.appendSlice(mem.gpa, "\\\"") catch {},
        else => o.append(mem.gpa, c) catch {},
    };
    o.append(mem.gpa, '"') catch {};
    return o.items;
}

fn opSymbol(op: ast.BinOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .eq => "==",
        .ne => "!=",
        .match => "=~",
        .nomatch => "!~",
        .in => "in",
        .and_ => "&&",
        .or_ => "||",
    };
}

fn exprNode(e: *const ast.Expr) *Node {
    switch (e.kind) {
        .null_ => return node("null", .{}),
        .bool_ => |b| return node("{}", .{b}),
        .int => |i| return node("{d}", .{i}),
        .float => |f| return node("{d}", .{f}),
        .ident => |n| return node("{s}", .{n}),
        .str => |parts| {
            if (parts.len == 1 and parts[0] == .lit) return node("{s}", .{quoted(parts[0].lit)});
            const n = node("string", .{});
            for (parts) |p| switch (p) {
                .lit => |s| n.add(node("{s}", .{quoted(s)})),
                .expr => |x| {
                    const w = node("interpolate", .{});
                    w.add(exprNode(x));
                    n.add(w);
                },
            };
            return n;
        },
        .array => |items| {
            const n = node("array", .{});
            for (items) |it| n.add(exprNode(it));
            return n;
        },
        .map => |entries| {
            const n = node("map", .{});
            for (entries) |en| {
                const pair = node("entry", .{});
                pair.add(exprNode(en.key));
                pair.add(exprNode(en.value));
                n.add(pair);
            }
            return n;
        },
        .unary => |u| {
            const n = node("{s}", .{if (u.op == .not) "!" else "neg"});
            n.add(exprNode(u.e));
            return n;
        },
        .binary => |b| {
            const n = node("{s}", .{opSymbol(b.op)});
            n.add(exprNode(b.l));
            n.add(exprNode(b.r));
            return n;
        },
        .ternary => |t| {
            const n = node("?:", .{});
            n.add(exprNode(t.c));
            n.add(exprNode(t.a));
            n.add(exprNode(t.b));
            return n;
        },
        .call => |c| {
            const n = node("call", .{});
            n.add(exprNode(c.callee));
            for (c.args) |a| n.add(exprNode(a));
            return n;
        },
        .index => |i| {
            const n = node("index", .{});
            n.add(exprNode(i.obj));
            n.add(exprNode(i.idx));
            return n;
        },
        .member => |m| {
            const n = node(".{s}", .{m.name});
            n.add(exprNode(m.obj));
            return n;
        },
        .fn_ => |d| return fnNode(d, "fn (anonymous)"),
        .cmd_sub => |c| {
            const n = node("{s}", .{if (c.lines) "@( ) lines" else "$( ) capture"});
            n.add(listNode(c.list));
            return n;
        },
        .status => |c| {
            const n = node("status( )", .{});
            n.add(listNode(c));
            return n;
        },
    }
}

fn wordNode(w: ast.Word) *Node {
    // One-part words print on a single line; mixed words show their parts.
    if (w.parts.len == 1) {
        switch (w.parts[0]) {
            .text => |t| return node("word {s}{s}", .{ quoted(t.s), if (t.quoted) " (quoted)" else "" }),
            .var_ => |v| {
                var s: std.ArrayList(u8) = .empty;
                s.print(mem.gpa, "${s}", .{v.name}) catch {};
                for (v.fields) |f| s.print(mem.gpa, ".{s}", .{f}) catch {};
                return node("word {s}", .{s.items});
            },
            else => {},
        }
    }
    const n = node("word", .{});
    for (w.parts) |p| switch (p) {
        .text => |t| n.add(node("text {s}{s}", .{ quoted(t.s), if (t.quoted) " (quoted)" else " (glob-eligible)" })),
        .var_ => |v| n.add(node("var ${s}", .{v.name})),
        .expr => |x| {
            const k = node("interpolate", .{});
            k.add(exprNode(x));
            n.add(k);
        },
        .cmd_sub => |c| {
            const k = node("{s}", .{if (c.lines) "@( ) lines" else "$( ) capture"});
            k.add(listNode(c.list));
            n.add(k);
        },
        .splice => |x| {
            const k = node("splice @", .{});
            k.add(exprNode(x));
            n.add(k);
        },
        .tilde => |u| n.add(node("home ~{s}", .{u})),
    };
    return n;
}

fn pipeNode(p: ast.Pipeline) *Node {
    const inner: *Node = blk: {
        if (p.cmds.len == 1) break :blk cmdNode(p.cmds[0]);
        const n = node("pipeline", .{});
        for (p.cmds) |c| n.add(cmdNode(c));
        break :blk n;
    };
    if (!p.negate) return inner;
    const not = node("! (negate status)", .{});
    not.add(inner);
    return not;
}

fn cmdNode(c: ast.Command) *Node {
    const n = node("command", .{});
    for (c.words) |w| n.add(wordNode(w));
    for (c.redirs) |r| {
        const k = node("redirect {s}", .{@tagName(r.kind)});
        if (r.target) |t| k.add(wordNode(t));
        n.add(k);
    }
    return n;
}

fn listNode(cl: *const ast.CommandList) *Node {
    if (cl.rest.len == 0 and !cl.background) return pipeNode(cl.first);
    const n = node("{s}", .{if (cl.background) "list (background)" else "list"});
    n.add(pipeNode(cl.first));
    for (cl.rest) |ch| {
        const k = node("{s}", .{if (ch.and_) "&& then" else "|| else"});
        k.add(pipeNode(ch.p));
        n.add(k);
    }
    return n;
}

fn condNode(c: ast.Cond) *Node {
    const n = node("condition", .{});
    switch (c) {
        .expr => |e| n.add(exprNode(e)),
        .cmd => |cl| {
            const k = node("command status", .{});
            k.add(listNode(cl));
            n.add(k);
        },
    }
    return n;
}

fn blockNode(label: []const u8, stmts: []const ast.Stmt) *Node {
    const n = node("{s}", .{label});
    for (stmts) |*s| n.add(stmtNode(s));
    return n;
}

fn fnNode(d: *const ast.FnDecl, label: []const u8) *Node {
    const n = node("{s}", .{label});
    if (d.params.len > 0) {
        const ps = node("params", .{});
        for (d.params) |p| {
            const k = node("{s}", .{p.name});
            if (p.default) |def| {
                const dn = node("default", .{});
                dn.add(exprNode(def));
                k.add(dn);
            }
            ps.add(k);
        }
        n.add(ps);
    }
    n.add(blockNode("body", d.body));
    return n;
}

fn stmtNode(s: *const ast.Stmt) *Node {
    const loc = source.locate(s.span);
    const n: *Node = switch (s.kind) {
        .var_decl => |d| blk: {
            const k = node("{s} {s}", .{ if (d.is_const) "const" else "var", d.name });
            k.add(exprNode(d.init));
            break :blk k;
        },
        .assign => |a| blk: {
            const k = node("assign {s}", .{@tagName(a.op)});
            k.add(exprNode(a.target));
            if (a.value) |v| k.add(exprNode(v));
            break :blk k;
        },
        .if_ => |i| blk: {
            const k = node("if", .{});
            k.add(condNode(i.cond));
            k.add(blockNode("then", i.then));
            if (i.else_) |e| k.add(blockNode("else", e));
            break :blk k;
        },
        .while_ => |x| blk: {
            const k = node("while", .{});
            k.add(condNode(x.cond));
            k.add(blockNode("body", x.body));
            break :blk k;
        },
        .for_in => |f| blk: {
            const k = node("for {s} in", .{f.name});
            k.add(exprNode(f.iter));
            k.add(blockNode("body", f.body));
            break :blk k;
        },
        .for_c => |f| blk: {
            const k = node("for (;;)", .{});
            if (f.init) |i| {
                const w = node("init", .{});
                w.add(stmtNode(i));
                k.add(w);
            }
            if (f.cond) |c| {
                const w = node("test", .{});
                w.add(exprNode(c));
                k.add(w);
            }
            if (f.step) |st| {
                const w = node("step", .{});
                w.add(stmtNode(st));
                k.add(w);
            }
            k.add(blockNode("body", f.body));
            break :blk k;
        },
        .fn_decl => |d| fnNode(d, mem.print("fn {s}", .{d.name})),
        .class_decl => |c| blk: {
            const k = node("class {s}{s}{s}", .{ c.name, if (c.parent != null) " extends " else "", c.parent orelse "" });
            for (c.fields) |f| {
                const fk = node("field {s}", .{f.name});
                fk.add(exprNode(f.init));
                k.add(fk);
            }
            for (c.methods) |m| k.add(fnNode(m, mem.print("method {s}", .{m.name})));
            break :blk k;
        },
        .return_ => |r| blk: {
            const k = node("return", .{});
            if (r) |e| k.add(exprNode(e));
            break :blk k;
        },
        .break_ => node("break", .{}),
        .continue_ => node("continue", .{}),
        .try_ => |t| blk: {
            const k = node("try", .{});
            k.add(blockNode("body", t.body));
            if (t.handler) |h| k.add(blockNode(mem.print("catch {s}", .{t.name}), h));
            if (t.finally_) |f| k.add(blockNode("finally", f));
            break :blk k;
        },
        .subshell => |b| blockNode("subshell", b),
        .import => |im| node("import {s} as {s}", .{ quoted(im.path), im.alias }),
        .expr => |e| exprNode(e),
        .command => |cl| listNode(cl),
        .block => |b| blockNode("block", b),
    };
    // Tag the statement with where it starts.
    n.label = mem.print("{s}   [{d}:{d}]", .{ n.label, loc.line, loc.col });
    return n;
}

fn render(o: *std.ArrayList(u8), n: *const Node, prefix: []const u8, last: bool, root: bool) void {
    if (root) {
        o.print(mem.gpa, "{s}\n", .{n.label}) catch {};
    } else {
        o.print(mem.gpa, "{s}{s}{s}\n", .{ prefix, if (last) "`-- " else "|-- ", n.label }) catch {};
    }
    const child_prefix = if (root) "" else mem.print("{s}{s}", .{ prefix, if (last) "    " else "|   " });
    for (n.kids.items, 0..) |k, i| render(o, k, child_prefix, i + 1 == n.kids.items.len, false);
}

/// Render a whole program as an ASCII tree.
pub fn program(stmts: []const ast.Stmt) []const u8 {
    const root = node("Program", .{});
    for (stmts) |*s| root.add(stmtNode(s));
    var o: std.ArrayList(u8) = .empty;
    render(&o, root, "", true, true);
    return o.items;
}
