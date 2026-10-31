//! Name resolution before execution (SPEC 4): typos in variable names are
//! caught early, and `super.init` rules for classes are checked.

const std = @import("std");
const ast = @import("ast.zig");
const mem = @import("mem.zig");
const builtins = @import("builtins.zig");

const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Span = ast.Span;

pub const Diag = struct { message: []const u8, span: Span, warning: bool = false };

/// Set by `dksh -n` to also report shadowed variables.
pub var warn_shadow = false;

const Scope = struct {
    /// Names whose declaration has been passed.
    visible: std.StringHashMapUnmanaged(void) = .empty,
    /// Every name declared directly in this block (for forward use inside fns).
    all: std.StringHashMapUnmanaged(void) = .empty,
};

const Resolver = struct {
    scopes: std.ArrayList(Scope) = .empty,
    diags: std.ArrayList(Diag) = .empty,
    fn_depth: u32 = 0,
    in_method: bool = false,

    fn oom() noreturn {
        @panic("out of memory");
    }

    fn push(r: *Resolver, stmts: []const Stmt) void {
        var s: Scope = .{};
        for (stmts) |st| switch (st.kind) {
            .var_decl => |d| s.all.put(mem.gpa, d.name, {}) catch oom(),
            .fn_decl => |f| {
                s.all.put(mem.gpa, f.name, {}) catch oom();
                s.visible.put(mem.gpa, f.name, {}) catch oom(); // hoisted
            },
            .class_decl => |c| s.all.put(mem.gpa, c.name, {}) catch oom(),
            .import => |im| s.all.put(mem.gpa, im.alias, {}) catch oom(),
            else => {},
        };
        r.scopes.append(mem.gpa, s) catch oom();
    }

    fn pop(r: *Resolver) void {
        _ = r.scopes.pop();
    }

    fn declare(r: *Resolver, name: []const u8, span: Span) void {
        if (warn_shadow and r.scopes.items.len > 1) {
            var i = r.scopes.items.len - 1;
            while (i > 0) {
                i -= 1;
                if (r.scopes.items[i].visible.contains(name)) {
                    r.warn(span, "`{s}` shadows a variable from an outer scope", .{name});
                    break;
                }
            }
        }
        const top = &r.scopes.items[r.scopes.items.len - 1];
        top.visible.put(mem.gpa, name, {}) catch oom();
        top.all.put(mem.gpa, name, {}) catch oom();
    }

    fn err(r: *Resolver, span: Span, comptime fmt: []const u8, args: anytype) void {
        r.diags.append(mem.gpa, .{ .message = mem.print(fmt, args), .span = span }) catch oom();
    }

    fn warn(r: *Resolver, span: Span, comptime fmt: []const u8, args: anytype) void {
        r.diags.append(mem.gpa, .{ .message = mem.print(fmt, args), .span = span, .warning = true }) catch oom();
    }

    fn known(r: *Resolver, name: []const u8) bool {
        if (builtins.find(name) != null) return true;
        var i = r.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const s = r.scopes.items[i];
            if (s.visible.contains(name)) return true;
            if (r.fn_depth > 0 and s.all.contains(name)) return true;
        }
        return false;
    }

    fn block(r: *Resolver, stmts: []const Stmt) void {
        r.push(stmts);
        defer r.pop();
        for (stmts) |*s| r.stmt(s);
    }

    fn cond(r: *Resolver, c: ast.Cond) void {
        switch (c) {
            .expr => |e| r.expr(e),
            .cmd => |cl| r.commandList(cl),
        }
    }

    fn stmt(r: *Resolver, s: *const Stmt) void {
        switch (s.kind) {
            .var_decl => |d| {
                r.expr(d.init);
                r.declare(d.name, s.span);
            },
            .assign => |a| {
                r.expr(a.target);
                if (a.value) |v| r.expr(v);
            },
            .if_ => |i| {
                r.cond(i.cond);
                r.block(i.then);
                if (i.else_) |e| r.block(e);
            },
            .while_ => |w| {
                r.cond(w.cond);
                r.block(w.body);
            },
            .for_in => |f| {
                r.expr(f.iter);
                r.push(&.{});
                r.declare(f.name, s.span);
                r.block(f.body);
                r.pop();
            },
            .for_c => |f| {
                r.push(&.{});
                defer r.pop();
                if (f.init) |i| r.stmt(i);
                if (f.cond) |c| r.expr(c);
                if (f.step) |st| r.stmt(st);
                r.block(f.body);
            },
            .fn_decl => |d| r.function(d, false),
            .class_decl => |c| r.class(c),
            .return_ => |e| if (e) |x| r.expr(x),
            .break_, .continue_ => {},
            .try_ => |t| {
                r.block(t.body);
                if (t.handler) |h| {
                    r.push(&.{});
                    r.declare(t.name, s.span);
                    r.block(h);
                    r.pop();
                }
                if (t.finally_) |f| r.block(f);
            },
            .subshell => |b| r.block(b),
            .import => |im| r.declare(im.alias, s.span),
            .expr => |e| r.expr(e),
            .command => |cl| r.commandList(cl),
            .block => |b| r.block(b),
        }
    }

    fn function(r: *Resolver, d: *ast.FnDecl, is_method: bool) void {
        r.fn_depth += 1;
        defer r.fn_depth -= 1;
        r.push(&.{});
        defer r.pop();
        const saved = r.in_method;
        r.in_method = is_method or r.in_method;
        defer r.in_method = saved;
        if (is_method) {
            r.declare("self", d.span);
            r.declare("super", d.span);
        }
        for (d.params) |p| {
            if (p.default) |def| r.expr(def);
            r.declare(p.name, d.span);
        }
        r.block(d.body);
    }

    fn callsSuperInit(stmts: []const Stmt) bool {
        for (stmts) |s| {
            switch (s.kind) {
                .expr => |e| if (isSuperInit(e)) return true,
                .if_ => |i| {
                    if (callsSuperInit(i.then)) return true;
                    if (i.else_) |el| if (callsSuperInit(el)) return true;
                },
                .block => |b| if (callsSuperInit(b)) return true,
                else => {},
            }
        }
        return false;
    }

    fn isSuperInit(e: *const Expr) bool {
        if (e.kind != .call) return false;
        const callee = e.kind.call.callee;
        if (callee.kind != .member) return false;
        const m = callee.kind.member;
        return m.obj.kind == .ident and std.mem.eql(u8, m.obj.kind.ident, "super") and std.mem.eql(u8, m.name, "init");
    }

    fn class(r: *Resolver, c: *ast.ClassDecl) void {
        if (c.parent) |p| {
            if (!r.known(p)) r.err(c.span, "unknown parent class `{s}`", .{p});
        }
        r.declare(c.name, c.span);
        r.push(&.{});
        defer r.pop();
        for (c.fields) |f| r.expr(f.init);
        for (c.methods) |m| {
            r.function(m, true);
            if (c.parent != null and std.mem.eql(u8, m.name, "init") and !callsSuperInit(m.body)) {
                r.err(m.span, "`init` in class {s} must call super.init(...)", .{c.name});
            }
        }
    }

    fn commandList(r: *Resolver, cl: *const ast.CommandList) void {
        r.pipeline(cl.first);
        for (cl.rest) |ch| r.pipeline(ch.p);
    }

    fn pipeline(r: *Resolver, p: ast.Pipeline) void {
        for (p.cmds) |c| {
            for (c.words) |w| r.word(w);
            for (c.redirs) |rd| if (rd.target) |t| r.word(t);
        }
    }

    fn word(r: *Resolver, w: ast.Word) void {
        for (w.parts) |part| switch (part) {
            .expr => |e| r.expr(e),
            .cmd_sub => |c| r.commandList(c.list),
            .splice => |e| r.expr(e),
            else => {},
        };
    }

    fn expr(r: *Resolver, e: *const Expr) void {
        switch (e.kind) {
            .null_, .bool_, .int, .float => {},
            .str => |parts| for (parts) |p| switch (p) {
                .expr => |x| r.expr(x),
                else => {},
            },
            .ident => |name| {
                if (std.mem.eql(u8, name, "super") or std.mem.eql(u8, name, "self")) {
                    if (!r.in_method) r.err(e.span, "`{s}` is only valid inside a method", .{name});
                } else if (!r.known(name)) {
                    r.err(e.span, "undefined variable `{s}`", .{name});
                }
            },
            .array => |items| for (items) |i| r.expr(i),
            .map => |entries| for (entries) |en| {
                r.expr(en.key);
                r.expr(en.value);
            },
            .unary => |u| r.expr(u.e),
            .binary => |b| {
                r.expr(b.l);
                r.expr(b.r);
            },
            .ternary => |t| {
                r.expr(t.c);
                r.expr(t.a);
                r.expr(t.b);
            },
            .call => |c| {
                r.expr(c.callee);
                for (c.args) |a| r.expr(a);
            },
            .index => |i| {
                r.expr(i.obj);
                r.expr(i.idx);
            },
            .member => |m| r.expr(m.obj),
            .fn_ => |d| r.function(d, false),
            .cmd_sub => |c| r.commandList(c.list),
            .status => |cl| r.commandList(cl),
        }
    }
};

/// Check a parsed program. Returns errors and warnings (empty when clean).
pub fn resolve(stmts: []const Stmt) []const Diag {
    var r: Resolver = .{};
    // The implicit globals every program starts with.
    var base: Scope = .{};
    base.visible.put(mem.gpa, "env", {}) catch @panic("out of memory");
    base.visible.put(mem.gpa, "args", {}) catch @panic("out of memory");
    var it = @import("parser.zig").global_names.keyIterator();
    while (it.next()) |k| base.visible.put(mem.gpa, k.*, {}) catch @panic("out of memory");
    r.scopes.append(mem.gpa, base) catch @panic("out of memory");
    r.block(stmts);
    return r.diags.items;
}
