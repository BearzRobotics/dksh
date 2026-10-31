//! `dksh --dump-ast`: print the syntax tree as indented S-expressions.
//! Meant for debugging the language itself, not as a stable format.

const std = @import("std");
const ast = @import("ast.zig");
const mem = @import("mem.zig");
const source = @import("source.zig");

const Out = std.ArrayList(u8);

fn pad(o: *Out, depth: usize) void {
    o.appendNTimes(mem.gpa, ' ', depth * 2) catch {};
}

fn w(o: *Out, comptime fmt: []const u8, args: anytype) void {
    o.print(mem.gpa, fmt, args) catch {};
}

fn str(o: *Out, s: []const u8) void {
    o.append(mem.gpa, '"') catch {};
    for (s) |c| switch (c) {
        '\n' => o.appendSlice(mem.gpa, "\\n") catch {},
        '"' => o.appendSlice(mem.gpa, "\\\"") catch {},
        '\\' => o.appendSlice(mem.gpa, "\\\\") catch {},
        else => o.append(mem.gpa, c) catch {},
    };
    o.append(mem.gpa, '"') catch {};
}

fn expr(o: *Out, e: *const ast.Expr) void {
    switch (e.kind) {
        .null_ => w(o, "null", .{}),
        .bool_ => |b| w(o, "{}", .{b}),
        .int => |i| w(o, "{d}", .{i}),
        .float => |f| w(o, "{d}", .{f}),
        .str => |parts| {
            w(o, "(str", .{});
            for (parts) |p| {
                o.append(mem.gpa, ' ') catch {};
                switch (p) {
                    .lit => |s| str(o, s),
                    .expr => |x| {
                        w(o, "${{", .{});
                        expr(o, x);
                        w(o, "}}", .{});
                    },
                }
            }
            w(o, ")", .{});
        },
        .ident => |n| w(o, "{s}", .{n}),
        .array => |items| {
            w(o, "(array", .{});
            for (items) |it| {
                o.append(mem.gpa, ' ') catch {};
                expr(o, it);
            }
            w(o, ")", .{});
        },
        .map => |entries| {
            w(o, "(map", .{});
            for (entries) |en| {
                w(o, " (", .{});
                expr(o, en.key);
                o.append(mem.gpa, ' ') catch {};
                expr(o, en.value);
                w(o, ")", .{});
            }
            w(o, ")", .{});
        },
        .unary => |u| {
            w(o, "({s} ", .{@tagName(u.op)});
            expr(o, u.e);
            w(o, ")", .{});
        },
        .binary => |b| {
            w(o, "({s} ", .{@tagName(b.op)});
            expr(o, b.l);
            o.append(mem.gpa, ' ') catch {};
            expr(o, b.r);
            w(o, ")", .{});
        },
        .ternary => |t| {
            w(o, "(? ", .{});
            expr(o, t.c);
            o.append(mem.gpa, ' ') catch {};
            expr(o, t.a);
            o.append(mem.gpa, ' ') catch {};
            expr(o, t.b);
            w(o, ")", .{});
        },
        .call => |c| {
            w(o, "(call ", .{});
            expr(o, c.callee);
            for (c.args) |a| {
                o.append(mem.gpa, ' ') catch {};
                expr(o, a);
            }
            w(o, ")", .{});
        },
        .index => |i| {
            w(o, "(index ", .{});
            expr(o, i.obj);
            o.append(mem.gpa, ' ') catch {};
            expr(o, i.idx);
            w(o, ")", .{});
        },
        .member => |m| {
            w(o, "(. ", .{});
            expr(o, m.obj);
            w(o, " {s})", .{m.name});
        },
        .fn_ => |d| w(o, "(fn/{d})", .{d.params.len}),
        .cmd_sub => |c| {
            w(o, "({s} ", .{if (c.lines) "@(" else "$("});
            commandList(o, c.list);
            w(o, ")", .{});
        },
        .status => |c| {
            w(o, "(status ", .{});
            commandList(o, c);
            w(o, ")", .{});
        },
    }
}

fn word(o: *Out, wd: ast.Word) void {
    w(o, "(word", .{});
    for (wd.parts) |p| {
        o.append(mem.gpa, ' ') catch {};
        switch (p) {
            .text => |t| {
                if (t.quoted) w(o, "q", .{});
                str(o, t.s);
            },
            .var_ => |v| {
                w(o, "${s}", .{v.name});
                for (v.fields) |f| w(o, ".{s}", .{f});
            },
            .expr => |x| {
                w(o, "${{", .{});
                expr(o, x);
                w(o, "}}", .{});
            },
            .cmd_sub => |c| {
                w(o, "({s} ", .{if (c.lines) "@(" else "$("});
                commandList(o, c.list);
                w(o, ")", .{});
            },
            .splice => |x| {
                w(o, "@", .{});
                expr(o, x);
            },
            .tilde => |u| w(o, "~{s}", .{u}),
        }
    }
    w(o, ")", .{});
}

fn commandList(o: *Out, cl: *const ast.CommandList) void {
    w(o, "(list", .{});
    pipeline(o, cl.first);
    for (cl.rest) |ch| {
        w(o, " {s}", .{if (ch.and_) "&&" else "||"});
        pipeline(o, ch.p);
    }
    if (cl.background) w(o, " &", .{});
    w(o, ")", .{});
}

fn pipeline(o: *Out, p: ast.Pipeline) void {
    w(o, " ({s}", .{if (p.negate) "pipe!" else "pipe"});
    for (p.cmds) |c| {
        w(o, " (cmd", .{});
        for (c.words) |wd| {
            o.append(mem.gpa, ' ') catch {};
            word(o, wd);
        }
        for (c.redirs) |r| {
            w(o, " ({s}", .{@tagName(r.kind)});
            if (r.target) |t| {
                o.append(mem.gpa, ' ') catch {};
                word(o, t);
            }
            w(o, ")", .{});
        }
        w(o, ")", .{});
    }
    w(o, ")", .{});
}

fn cond(o: *Out, c: ast.Cond) void {
    switch (c) {
        .expr => |e| expr(o, e),
        .cmd => |cl| commandList(o, cl),
    }
}

fn block(o: *Out, stmts: []const ast.Stmt, depth: usize) void {
    for (stmts) |*s| stmt(o, s, depth);
}

fn stmt(o: *Out, s: *const ast.Stmt, depth: usize) void {
    pad(o, depth);
    const loc = source.locate(s.span);
    switch (s.kind) {
        .var_decl => |d| {
            w(o, "({s} {s} ", .{ if (d.is_const) "const" else "var", d.name });
            expr(o, d.init);
            w(o, ")", .{});
        },
        .assign => |a| {
            w(o, "(assign {s} ", .{@tagName(a.op)});
            expr(o, a.target);
            if (a.value) |v| {
                o.append(mem.gpa, ' ') catch {};
                expr(o, v);
            }
            w(o, ")", .{});
        },
        .if_ => |i| {
            w(o, "(if ", .{});
            cond(o, i.cond);
            w(o, "\n", .{});
            block(o, i.then, depth + 1);
            if (i.else_) |e| {
                pad(o, depth);
                w(o, "else\n", .{});
                block(o, e, depth + 1);
            }
            pad(o, depth);
            w(o, ")", .{});
        },
        .while_ => |x| {
            w(o, "(while ", .{});
            cond(o, x.cond);
            w(o, "\n", .{});
            block(o, x.body, depth + 1);
            pad(o, depth);
            w(o, ")", .{});
        },
        .for_in => |f| {
            w(o, "(for {s} in ", .{f.name});
            expr(o, f.iter);
            w(o, "\n", .{});
            block(o, f.body, depth + 1);
            pad(o, depth);
            w(o, ")", .{});
        },
        .for_c => |f| {
            w(o, "(for;;\n", .{});
            if (f.init) |i| stmt(o, i, depth + 1);
            if (f.cond) |c| {
                pad(o, depth + 1);
                expr(o, c);
                w(o, "\n", .{});
            }
            if (f.step) |st| stmt(o, st, depth + 1);
            block(o, f.body, depth + 1);
            pad(o, depth);
            w(o, ")", .{});
        },
        .fn_decl => |d| {
            w(o, "(fn {s}(", .{d.name});
            for (d.params, 0..) |p, i| {
                if (i > 0) w(o, ", ", .{});
                w(o, "{s}", .{p.name});
                if (p.default) |def| {
                    w(o, "=", .{});
                    expr(o, def);
                }
            }
            w(o, ")\n", .{});
            block(o, d.body, depth + 1);
            pad(o, depth);
            w(o, ")", .{});
        },
        .class_decl => |c| {
            w(o, "(class {s}", .{c.name});
            if (c.parent) |p| w(o, " extends {s}", .{p});
            w(o, "\n", .{});
            for (c.fields) |f| {
                pad(o, depth + 1);
                w(o, "(field {s} ", .{f.name});
                expr(o, f.init);
                w(o, ")\n", .{});
            }
            for (c.methods) |m| {
                pad(o, depth + 1);
                w(o, "(method {s}/{d})\n", .{ m.name, m.params.len });
            }
            pad(o, depth);
            w(o, ")", .{});
        },
        .return_ => |r| {
            w(o, "(return", .{});
            if (r) |e| {
                o.append(mem.gpa, ' ') catch {};
                expr(o, e);
            }
            w(o, ")", .{});
        },
        .break_ => w(o, "(break)", .{}),
        .continue_ => w(o, "(continue)", .{}),
        .try_ => |t| {
            w(o, "(try\n", .{});
            block(o, t.body, depth + 1);
            if (t.handler) |h| {
                pad(o, depth);
                w(o, "catch {s}\n", .{t.name});
                block(o, h, depth + 1);
            }
            if (t.finally_) |f| {
                pad(o, depth);
                w(o, "finally\n", .{});
                block(o, f, depth + 1);
            }
            pad(o, depth);
            w(o, ")", .{});
        },
        .subshell => |b| {
            w(o, "(subshell\n", .{});
            block(o, b, depth + 1);
            pad(o, depth);
            w(o, ")", .{});
        },
        .import => |im| w(o, "(import \"{s}\" as {s})", .{ im.path, im.alias }),
        .expr => |e| expr(o, e),
        .command => |cl| commandList(o, cl),
        .block => |b| {
            w(o, "(block\n", .{});
            block(o, b, depth + 1);
            pad(o, depth);
            w(o, ")", .{});
        },
    }
    w(o, "  ; {d}:{d}\n", .{ loc.line, loc.col });
}

/// Render a whole program.
pub fn program(stmts: []const ast.Stmt) []const u8 {
    var o: Out = .empty;
    block(&o, stmts, 0);
    return o.items;
}
