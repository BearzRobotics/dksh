//! Tree-walking interpreter for statements and expressions (SPEC 4).

const std = @import("std");
const ast = @import("ast.zig");
const mem = @import("mem.zig");
const sys = @import("sys.zig");
const source = @import("source.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const value = @import("value.zig");
const exec = @import("exec.zig");
const builtins = @import("builtins.zig");
const regex = @import("regex.zig");
const jobs = @import("jobs.zig");
const signals = @import("signals.zig");

const Value = value.Value;
const Env = value.Env;
const Span = ast.Span;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
pub const Error = value.Error;

pub const ErrInfo = struct {
    message: []const u8,
    status: ?i64 = null,
    span: Span,
};

const max_depth = 600;

pub const Interp = struct {
    /// Holds `env` and `args`; parent of every script and module scope.
    base: *Env,
    globals: *Env,
    env_map: *value.Map,
    err: ErrInfo = .{ .message = "", .span = .{} },
    exit_code: u8 = 0,
    /// `exit` ran; the interactive loop should stop.
    exit_requested: bool = false,
    ret: Value = .null_,
    last_status: u8 = 0,
    /// Failed commands raise errors (scripts) or just set the status (prompt).
    errexit: bool = true,
    interactive: bool = false,
    /// `-x`: print each command, expanded, before running it.
    trace: bool = false,
    /// True in a forked child (never owns the terminal or the job table).
    in_child: bool = false,
    depth: u32 = 0,
    /// Handlers installed with `trap()`, by signal number.
    traps: std.AutoHashMapUnmanaged(u5, Value) = .empty,
    exit_trap: ?Value = null,
    in_trap: bool = false,
    /// Nesting of `status(...)`: inside it a missing command is status 127, not an error.
    status_depth: u32 = 0,
    modules: std.StringHashMapUnmanaged(Value) = .empty,

    pub fn init(args: []const []const u8, environ: []const [*:0]const u8) *Interp {
        const ip = mem.gpa.create(Interp) catch @panic("out of memory");
        const base = Env.create(null);
        const env_map = Value.newMap();
        for (environ) |entry| {
            const s = std.mem.span(entry);
            if (std.mem.indexOfScalar(u8, s, '=')) |eq| {
                env_map.put(mem.dupe(s[0..eq]), .{ .str = mem.dupe(s[eq + 1 ..]) });
            }
        }
        const arr = Value.newArray();
        for (args) |a| arr.items.append(mem.gpa, .{ .str = mem.dupe(a) }) catch @panic("out of memory");
        base.declare("env", .{ .map = env_map }, true);
        base.declare("args", .{ .array = arr }, true);
        ip.* = .{ .base = base, .globals = Env.create(base), .env_map = env_map };
        return ip;
    }

    // ------------------------------------------------------------- errors

    pub fn raise(ip: *Interp, span: Span, comptime fmt: []const u8, args: anytype) Error {
        ip.err = .{ .message = mem.print(fmt, args), .span = span };
        return error.Raise;
    }

    pub fn raiseStatus(ip: *Interp, span: Span, status: i64, comptime fmt: []const u8, args: anytype) Error {
        ip.err = .{ .message = mem.print(fmt, args), .status = status, .span = span };
        return error.Raise;
    }

    /// Print the pending error in the SPEC 5.8 format to standard error.
    pub fn report(ip: *Interp) void {
        sys.write(2, source.render("error", ip.err.message, ip.err.span));
    }

    // ------------------------------------------------------------ running

    /// Parse, resolve and run a program in `env`. Returns the exit status.
    pub fn runSource(ip: *Interp, name: []const u8, text: []const u8, env: *Env) u8 {
        const prog = parser.parseSource(name, text) catch |e| {
            reportParse(e);
            return 2;
        };
        const diags = resolver.resolve(prog.stmts);
        if (diags.len > 0) {
            for (diags) |d| if (!d.warning) sys.write(2, source.render("error", d.message, d.span));
            for (diags) |d| if (d.warning) sys.write(2, source.render("warning", d.message, d.span));
            for (diags) |d| if (!d.warning) return 2;
        }
        return ip.runProgram(prog.stmts, env);
    }

    pub fn runProgram(ip: *Interp, stmts: []const Stmt, env: *Env) u8 {
        ip.execStmts(stmts, env) catch |e| switch (e) {
            error.Raise => {
                ip.report();
                return 1;
            },
            error.Exit => {
                ip.exit_requested = true;
                return ip.exit_code;
            },
            error.Break, error.Continue, error.Return => return ip.last_status,
        };
        return ip.last_status;
    }

    // --------------------------------------------------------- statements

    /// Declare in `env`, remembering global names for later parses.
    fn declare(ip: *Interp, env: *Env, name: []const u8, v: Value, is_const: bool) void {
        env.declare(name, v, is_const);
        if (env == ip.globals) parser.global_names.put(mem.gpa, name, {}) catch @panic("out of memory");
    }

    fn hoist(ip: *Interp, stmts: []const Stmt, env: *Env) void {
        for (stmts) |s| {
            if (s.kind == .fn_decl) {
                const f = mem.gpa.create(value.Func) catch @panic("out of memory");
                f.* = .{ .decl = s.kind.fn_decl, .env = env };
                ip.declare(env, s.kind.fn_decl.name, .{ .func = f }, true);
            }
        }
    }

    /// Run statements in the given scope (no new scope is created).
    pub fn execStmts(ip: *Interp, stmts: []const Stmt, env: *Env) Error!void {
        ip.hoist(stmts, env);
        for (stmts) |*s| try ip.execStmt(s, env);
    }

    pub fn execBlock(ip: *Interp, stmts: []const Stmt, parent: *Env) Error!void {
        return ip.execStmts(stmts, Env.create(parent));
    }

    fn condTrue(ip: *Interp, c: ast.Cond, env: *Env) Error!bool {
        switch (c) {
            .expr => |e| {
                const v = try ip.eval(e, env);
                if (v != .bool_) return ip.raise(e.span, "condition must be a bool, got {s}", .{v.typeName()});
                return v.bool_;
            },
            .cmd => |cl| return (try exec.runCommandList(ip, cl, env, false)) == 0,
        }
    }

    /// `subshell { ... }`: run the block in a forked child, so `cd`, variable
    /// changes and `exit` stay inside it.
    fn runSubshell(ip: *Interp, s: *const Stmt, body: []const Stmt, env: *Env) Error!void {
        const pid = sys.fork() catch return ip.raise(s.span, "cannot fork: {s}", .{sys.errnoText()});
        if (pid == 0) {
            ip.in_child = true;
            ip.interactive = false;
            jobs.resetSignals();
            ip.traps = .empty;
            ip.exit_trap = null;
            const st: u8 = blk: {
                ip.execBlock(body, env) catch |e| switch (e) {
                    error.Raise => {
                        ip.report();
                        break :blk 1;
                    },
                    error.Exit => break :blk ip.exit_code,
                    else => {},
                };
                break :blk 0;
            };
            ip.runExitTrap();
            sys.exit(st);
        }
        const r = sys.waitpid(pid, 0) catch return ip.raise(s.span, "wait failed", .{});
        const st = sys.exitStatus(r.status);
        ip.last_status = st;
        if (st != 0 and ip.errexit) return ip.raiseStatus(s.span, st, "subshell exited with status {d}", .{st});
    }

    /// Run script functions registered with `trap()` for signals that arrived.
    fn runTraps(ip: *Interp, span: Span) Error!void {
        if (ip.in_trap) return;
        ip.in_trap = true;
        defer ip.in_trap = false;
        const bits = signals.takePending();
        var n: u5 = 1;
        while (true) : (n += 1) {
            if (bits & (@as(u32, 1) << n) != 0) {
                if (ip.traps.get(n)) |handler| {
                    const sig: std.os.linux.SIG = @enumFromInt(n);
                    _ = try ip.callValue(handler, &.{.{ .str = signals.nameOf(sig) }}, span);
                }
            }
            if (n == 31) break;
        }
    }

    /// Run the `trap("EXIT", fn)` handler, once.
    pub fn runExitTrap(ip: *Interp) void {
        const handler = ip.exit_trap orelse return;
        ip.exit_trap = null;
        _ = ip.callValue(handler, &.{.{ .str = "EXIT" }}, .{}) catch |e| {
            if (e == error.Raise) ip.report();
        };
    }

    pub fn execStmt(ip: *Interp, s: *const Stmt, env: *Env) Error!void {
        if (signals.anyPending()) try ip.runTraps(s.span);
        switch (s.kind) {
            .var_decl => |d| {
                const v = try ip.eval(d.init, env);
                if (env.vars.contains(d.name)) {
                    return ip.raise(s.span, "`{s}` is already declared in this scope", .{d.name});
                }
                ip.declare(env, d.name, v, d.is_const);
            },
            .assign => |a| try ip.execAssign(s, a, env),
            .if_ => |i| {
                if (try ip.condTrue(i.cond, env)) {
                    try ip.execBlock(i.then, env);
                } else if (i.else_) |els| {
                    try ip.execBlock(els, env);
                }
            },
            .while_ => |w| {
                while (try ip.condTrue(w.cond, env)) {
                    ip.execBlock(w.body, env) catch |e| switch (e) {
                        error.Break => break,
                        error.Continue => continue,
                        else => return e,
                    };
                }
            },
            .for_in => |f| {
                const it = try ip.eval(f.iter, env);
                switch (it) {
                    .array => |arr| {
                        var i: usize = 0;
                        while (i < arr.items.items.len) : (i += 1) {
                            const scope = Env.create(env);
                            scope.declare(f.name, arr.items.items[i], false);
                            ip.execStmts(f.body, scope) catch |e| switch (e) {
                                error.Break => break,
                                error.Continue => continue,
                                else => return e,
                            };
                        }
                    },
                    .map => |m| {
                        const keys = mem.gpa.dupe([]const u8, m.m.keys()) catch @panic("out of memory");
                        for (keys) |k| {
                            const scope = Env.create(env);
                            scope.declare(f.name, .{ .str = k }, false);
                            ip.execStmts(f.body, scope) catch |e| switch (e) {
                                error.Break => break,
                                error.Continue => continue,
                                else => return e,
                            };
                        }
                    },
                    else => return ip.raise(f.iter.span, "cannot iterate over {s}", .{it.typeName()}),
                }
            },
            .for_c => |f| {
                const scope = Env.create(env);
                if (f.init) |init_stmt| try ip.execStmt(init_stmt, scope);
                while (true) {
                    if (f.cond) |c| {
                        const v = try ip.eval(c, scope);
                        if (v != .bool_) return ip.raise(c.span, "condition must be a bool, got {s}", .{v.typeName()});
                        if (!v.bool_) break;
                    }
                    var brk = false;
                    ip.execBlock(f.body, scope) catch |e| switch (e) {
                        error.Break => brk = true,
                        error.Continue => {},
                        else => return e,
                    };
                    if (brk) break;
                    if (f.step) |st| try ip.execStmt(st, scope);
                }
            },
            .fn_decl => {}, // hoisted
            .class_decl => |c| try ip.declareClass(c, env),
            .return_ => |r| {
                ip.ret = if (r) |e| try ip.eval(e, env) else .null_;
                return error.Return;
            },
            .break_ => return error.Break,
            .continue_ => return error.Continue,
            .try_ => |t| {
                // Whatever escapes the body or the handler is re-raised once
                // `finally` has run; an error inside `finally` replaces it.
                var pending: ?Error = null;
                ip.execBlock(t.body, env) catch |e| {
                    if (e == error.Raise and t.handler != null) {
                        const scope = Env.create(env);
                        scope.declare(t.name, ip.errorMap(), false);
                        ip.execStmts(t.handler.?, scope) catch |e2| {
                            pending = e2;
                        };
                    } else pending = e;
                };
                if (t.finally_) |f| {
                    const saved_err = ip.err;
                    const saved_ret = ip.ret;
                    const saved_exit = ip.exit_code;
                    try ip.execBlock(f, env);
                    ip.err = saved_err;
                    ip.ret = saved_ret;
                    ip.exit_code = saved_exit;
                }
                if (pending) |e| return e;
            },
            .subshell => |b| try ip.runSubshell(s, b, env),
            .import => |im| try ip.execImport(s, im.path, im.alias, env),
            .expr => |e| _ = try ip.eval(e, env),
            .command => |cl| {
                const st = try exec.runCommandList(ip, cl, env, true);
                ip.last_status = st;
            },
            .block => |b| try ip.execBlock(b, env),
        }
    }

    fn errorMap(ip: *Interp) Value {
        const m = Value.newMap();
        const loc = source.locate(ip.err.span);
        m.put("message", Value.newStr(ip.err.message));
        m.put("status", if (ip.err.status) |st| .{ .int = st } else .null_);
        m.put("file", Value.newStr(source.get(ip.err.span.file).name));
        m.put("line", .{ .int = loc.line });
        m.put("column", .{ .int = loc.col });
        return .{ .map = m };
    }

    fn execAssign(ip: *Interp, s: *const Stmt, a: anytype, env: *Env) Error!void {
        const new: Value = blk: {
            if (a.op == .set) break :blk try ip.eval(a.value.?, env);
            const old = try ip.eval(a.target, env);
            const rhs: Value = switch (a.op) {
                .inc, .dec => .{ .int = 1 },
                else => try ip.eval(a.value.?, env),
            };
            const op: ast.BinOp = switch (a.op) {
                .add, .inc => .add,
                .sub, .dec => .sub,
                .mul => .mul,
                .div => .div,
                .set => unreachable,
            };
            break :blk try ip.binaryOp(op, old, rhs, s.span);
        };
        try ip.store(a.target, new, env);
    }

    fn store(ip: *Interp, target: *Expr, v: Value, env: *Env) Error!void {
        switch (target.kind) {
            .ident => |name| {
                const slot = env.lookup(name) orelse return ip.raise(target.span, "`{s}` is not declared; use `var {s} = ...`", .{ name, name });
                if (slot.is_const) return ip.raise(target.span, "cannot assign to constant `{s}`", .{name});
                slot.value = v;
            },
            .member => |m| {
                const obj = try ip.eval(m.obj, env);
                switch (obj) {
                    .object => |o| {
                        const slot = o.fields.getPtr(m.name) orelse
                            return ip.raise(target.span, "{s} has no field `{s}`", .{ o.class.name, m.name });
                        slot.* = v;
                    },
                    .map => |mp| {
                        if (m.obj.kind == .ident and std.mem.eql(u8, m.obj.kind.ident, "env")) {
                            if (v != .str) return ip.raise(target.span, "environment values must be strings", .{});
                        }
                        mp.put(mem.dupe(m.name), v);
                    },
                    else => return ip.raise(target.span, "cannot assign to a field of {s}", .{obj.typeName()}),
                }
            },
            .index => |ix| {
                const obj = try ip.eval(ix.obj, env);
                const idx = try ip.eval(ix.idx, env);
                switch (obj) {
                    .array => |arr| {
                        const i = try ip.arrayIndex(arr.items.items.len, idx, ix.idx.span);
                        arr.items.items[i] = v;
                    },
                    .map => |mp| mp.put(mem.dupe(try ip.mapKey(idx, ix.idx.span)), v),
                    else => return ip.raise(target.span, "cannot index-assign into {s}", .{obj.typeName()}),
                }
            },
            else => return ip.raise(target.span, "invalid assignment target", .{}),
        }
    }

    /// Map keys are strings; an int index is its decimal text (match groups: `m[1]`).
    fn mapKey(ip: *Interp, idx: Value, span: Span) Error![]const u8 {
        return switch (idx) {
            .str => |s| s,
            .int => value.toDisplayString(idx),
            else => ip.raise(span, "map keys must be strings, got {s}", .{idx.typeName()}),
        };
    }

    fn arrayIndex(ip: *Interp, len: usize, idx: Value, span: Span) Error!usize {
        if (idx != .int) return ip.raise(span, "index must be an int, got {s}", .{idx.typeName()});
        var i = idx.int;
        if (i < 0) i += @intCast(len);
        if (i < 0 or i >= len) return ip.raise(span, "index {d} out of range (length {d})", .{ idx.int, len });
        return @intCast(i);
    }

    // ------------------------------------------------------------ classes

    fn declareClass(ip: *Interp, c: *ast.ClassDecl, env: *Env) Error!void {
        var parent: ?*value.Class = null;
        if (c.parent) |pname| {
            const slot = env.lookup(pname) orelse return ip.raise(c.span, "unknown parent class `{s}`", .{pname});
            if (slot.value != .class) return ip.raise(c.span, "`{s}` is not a class", .{pname});
            parent = slot.value.class;
        }
        // A child must not redeclare a parent's field.
        if (parent) |p| {
            for (c.fields) |f| {
                var q: ?*value.Class = p;
                while (q) |cur| : (q = cur.parent) {
                    for (cur.fields) |pf| {
                        if (std.mem.eql(u8, pf.name, f.name)) {
                            return ip.raise(f.span, "field `{s}` is already declared in parent class {s}", .{ f.name, cur.name });
                        }
                    }
                }
            }
        }
        const cls = mem.gpa.create(value.Class) catch @panic("out of memory");
        cls.* = .{ .name = c.name, .parent = parent, .fields = c.fields, .env = env };
        for (c.methods) |m| {
            const f = mem.gpa.create(value.Func) catch @panic("out of memory");
            f.* = .{ .decl = m, .env = env, .owner = cls };
            cls.methods.put(mem.gpa, m.name, f) catch @panic("out of memory");
        }
        ip.declare(env, c.name, .{ .class = cls }, true);
    }

    fn instantiate(ip: *Interp, cls: *value.Class, args: []const Value, span: Span) Error!Value {
        const obj = mem.gpa.create(value.Object) catch @panic("out of memory");
        obj.* = .{ .class = cls };
        // Root-most class first so field order follows inheritance.
        var chain: std.ArrayList(*value.Class) = .empty;
        var c: ?*value.Class = cls;
        while (c) |cur| : (c = cur.parent) chain.append(mem.gpa, cur) catch @panic("out of memory");
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            const k = chain.items[i];
            for (k.fields) |f| {
                const v = try ip.eval(f.init, k.env);
                obj.fields.put(mem.gpa, f.name, v) catch @panic("out of memory");
            }
        }
        const result: Value = .{ .object = obj };
        if (cls.findMethod("init")) |ctor| {
            _ = try ip.callFunc(ctor, obj, args, span);
        } else if (args.len > 0) {
            return ip.raise(span, "{s} has no init method but was given {d} argument(s)", .{ cls.name, args.len });
        }
        return result;
    }

    // ------------------------------------------------------------- modules

    fn execImport(ip: *Interp, s: *const Stmt, path: []const u8, alias: []const u8, env: *Env) Error!void {
        const resolved = ip.findModule(path, s.span) orelse
            return ip.raise(s.span, "cannot find module \"{s}\"", .{path});
        if (ip.modules.get(resolved)) |m| {
            ip.declare(env, alias, m, true);
            return;
        }
        const text = sys.readFile(mem.gpa, resolved) catch
            return ip.raise(s.span, "cannot read module \"{s}\": {s}", .{ resolved, sys.errnoText() });
        const prog = parser.parseSource(resolved, text) catch |e| {
            reportParse(e);
            return ip.raise(s.span, "module \"{s}\" has syntax errors", .{path});
        };
        const diags = resolver.resolve(prog.stmts);
        var bad = false;
        for (diags) |d| if (!d.warning) {
            sys.write(2, source.render("error", d.message, d.span));
            bad = true;
        };
        if (bad) return ip.raise(s.span, "module \"{s}\" has errors", .{path});
        const menv = Env.create(ip.base);
        // Mark as loading to stop import cycles from recursing forever.
        const ns = Value.newMap();
        ip.modules.put(mem.gpa, resolved, .{ .map = ns }) catch @panic("out of memory");
        try ip.execStmts(prog.stmts, menv);
        var it = menv.vars.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.is_const) ns.put(e.key_ptr.*, e.value_ptr.value);
        }
        ip.declare(env, alias, .{ .map = ns }, true);
    }

    fn findModule(ip: *Interp, path: []const u8, span: Span) ?[]const u8 {
        const relative = std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../") or std.mem.indexOfScalar(u8, path, '/') != null;
        if (std.fs.path.isAbsolute(path)) return if (sys.kindOf(mem.gpa, path) == .file) path else null;
        if (relative) {
            const dir = std.fs.path.dirname(source.get(span.file).name) orelse ".";
            const joined = std.fs.path.join(mem.gpa, &.{ dir, path }) catch return null;
            if (sys.kindOf(mem.gpa, joined) == .file) return joined;
        }
        // Bare names search $XDG_DATA_HOME/dksh/lib, then /usr/share/dksh/lib.
        const data_home: []const u8 = if (ip.env_map.get("XDG_DATA_HOME")) |d| (if (d == .str and d.str.len > 0) d.str else "") else "";
        const home: []const u8 = if (ip.env_map.get("HOME")) |d| (if (d == .str) d.str else "") else "";
        const user_lib = if (data_home.len > 0) mem.print("{s}/dksh/lib", .{data_home}) else mem.print("{s}/.local/share/dksh/lib", .{home});
        for ([_][]const u8{ user_lib, "/usr/share/dksh/lib" }) |dir| {
            const cand = std.fs.path.join(mem.gpa, &.{ dir, path }) catch continue;
            if (sys.kindOf(mem.gpa, cand) == .file) return cand;
        }
        return null;
    }

    // ------------------------------------------------------------ expressions

    pub fn lookupName(ip: *Interp, name: []const u8, env: *Env, span: Span) Error!Value {
        if (env.lookup(name)) |v| return v.value;
        if (builtins.find(name)) |n| return .{ .native = n };
        return ip.raise(span, "undefined variable `{s}`", .{name});
    }

    pub fn eval(ip: *Interp, e: *const Expr, env: *Env) Error!Value {
        switch (e.kind) {
            .null_ => return .null_,
            .bool_ => |b| return .{ .bool_ = b },
            .int => |i| return .{ .int = i },
            .float => |f| return .{ .float = f },
            .str => |parts| {
                if (parts.len == 0) return .{ .str = "" };
                if (parts.len == 1 and parts[0] == .lit) return .{ .str = parts[0].lit };
                var buf: std.ArrayList(u8) = .empty;
                for (parts) |p| switch (p) {
                    .lit => |s| buf.appendSlice(mem.gpa, s) catch @panic("out of memory"),
                    .expr => |x| value.display(&buf, try ip.eval(x, env), false),
                };
                return .{ .str = buf.items };
            },
            .ident => |name| return ip.lookupName(name, env, e.span),
            .array => |items| {
                const arr = Value.newArray();
                for (items) |it| arr.items.append(mem.gpa, try ip.eval(it, env)) catch @panic("out of memory");
                return .{ .array = arr };
            },
            .map => |entries| {
                const m = Value.newMap();
                for (entries) |en| {
                    const k = try ip.eval(en.key, env);
                    if (k != .str) return ip.raise(en.key.span, "map keys must be strings, got {s}", .{k.typeName()});
                    m.put(k.str, try ip.eval(en.value, env));
                }
                return .{ .map = m };
            },
            .unary => |u| {
                const v = try ip.eval(u.e, env);
                switch (u.op) {
                    .not => {
                        if (v != .bool_) return ip.raise(e.span, "`!` needs a bool, got {s}", .{v.typeName()});
                        return .{ .bool_ = !v.bool_ };
                    },
                    .neg => return switch (v) {
                        .int => |i| .{ .int = std.math.negate(i) catch return ip.raise(e.span, "integer overflow", .{}) },
                        .float => |f| .{ .float = -f },
                        else => ip.raise(e.span, "cannot negate {s}", .{v.typeName()}),
                    },
                }
            },
            .binary => |b| {
                if (b.op == .and_ or b.op == .or_) {
                    const l = try ip.eval(b.l, env);
                    if (l != .bool_) return ip.raise(b.l.span, "`{s}` needs bools, got {s}", .{ if (b.op == .and_) "&&" else "||", l.typeName() });
                    if (b.op == .and_ and !l.bool_) return .{ .bool_ = false };
                    if (b.op == .or_ and l.bool_) return .{ .bool_ = true };
                    const r = try ip.eval(b.r, env);
                    if (r != .bool_) return ip.raise(b.r.span, "`{s}` needs bools, got {s}", .{ if (b.op == .and_) "&&" else "||", r.typeName() });
                    return r;
                }
                const l = try ip.eval(b.l, env);
                const r = try ip.eval(b.r, env);
                return ip.binaryOp(b.op, l, r, e.span);
            },
            .ternary => |t| {
                const c = try ip.eval(t.c, env);
                if (c != .bool_) return ip.raise(t.c.span, "condition must be a bool, got {s}", .{c.typeName()});
                return ip.eval(if (c.bool_) t.a else t.b, env);
            },
            .call => |c| return ip.evalCall(e, c.callee, c.args, env),
            .index => |ix| {
                const obj = try ip.eval(ix.obj, env);
                const idx = try ip.eval(ix.idx, env);
                switch (obj) {
                    .array => |arr| return arr.items.items[try ip.arrayIndex(arr.items.items.len, idx, ix.idx.span)],
                    .str => |s| {
                        const i = try ip.arrayIndex(s.len, idx, ix.idx.span);
                        return .{ .str = s[i .. i + 1] };
                    },
                    .map => |m| return m.get(try ip.mapKey(idx, ix.idx.span)) orelse .null_,
                    else => return ip.raise(e.span, "cannot index {s}", .{obj.typeName()}),
                }
            },
            .member => |m| return ip.evalMember(e, m.obj, m.name, env),
            .fn_ => |d| {
                const f = mem.gpa.create(value.Func) catch @panic("out of memory");
                f.* = .{ .decl = d, .env = env };
                return .{ .func = f };
            },
            .cmd_sub => |c| {
                const out = try exec.capture(ip, c.list, env);
                if (!c.lines) return .{ .str = out };
                return linesOf(out);
            },
            .status => |cl| {
                ip.status_depth += 1;
                defer ip.status_depth -= 1;
                return .{ .int = try exec.runCommandList(ip, cl, env, false) };
            },
        }
    }

    pub fn linesOf(out: []const u8) Value {
        const arr = Value.newArray();
        if (out.len == 0) return .{ .array = arr };
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| arr.items.append(mem.gpa, .{ .str = line }) catch @panic("out of memory");
        return .{ .array = arr };
    }

    fn evalMember(ip: *Interp, e: *const Expr, obj_expr: *Expr, name: []const u8, env: *Env) Error!Value {
        // super.method: the parent's method bound to the current instance.
        if (obj_expr.kind == .ident and std.mem.eql(u8, obj_expr.kind.ident, "super")) {
            const owner_v = env.lookup("__owner") orelse return ip.raise(e.span, "`super` is only valid inside a method", .{});
            const self_v = env.lookup("self").?;
            const parent = owner_v.value.class.parent orelse return ip.raise(e.span, "class {s} has no parent", .{owner_v.value.class.name});
            const m = parent.findMethod(name) orelse return ip.raise(e.span, "parent class has no method `{s}`", .{name});
            const bound = mem.gpa.create(value.Func) catch @panic("out of memory");
            bound.* = m.*;
            bound.self_obj = self_v.value.object;
            return .{ .func = bound };
        }
        const obj = try ip.eval(obj_expr, env);
        return ip.getMember(obj, name, e.span);
    }

    pub fn getMember(ip: *Interp, obj: Value, name: []const u8, span: Span) Error!Value {
        switch (obj) {
            .map => |m| return m.get(name) orelse .null_,
            .object => |o| {
                if (o.fields.get(name)) |v| return v;
                if (o.class.findMethod(name)) |m| {
                    const bound = mem.gpa.create(value.Func) catch @panic("out of memory");
                    bound.* = m.*;
                    bound.self_obj = o;
                    return .{ .func = bound };
                }
                return ip.raise(span, "{s} has no field or method `{s}`", .{ o.class.name, name });
            },
            .regex => {
                if (builtins.findRegexMethod(name)) |n| {
                    const b = mem.gpa.create(value.Bound) catch @panic("out of memory");
                    b.* = .{ .recv = obj, .native = n };
                    return .{ .bound = b };
                }
                return ip.raise(span, "regex has no method `{s}`", .{name});
            },
            else => return ip.raise(span, "{s} has no members", .{obj.typeName()}),
        }
    }

    fn evalCall(ip: *Interp, e: *const Expr, callee_e: *Expr, arg_es: []const *Expr, env: *Env) Error!Value {
        const callee = try ip.eval(callee_e, env);
        const args = mem.gpa.alloc(Value, arg_es.len) catch @panic("out of memory");
        for (arg_es, 0..) |a, i| args[i] = try ip.eval(a, env);
        return ip.callValue(callee, args, e.span);
    }

    pub fn callValue(ip: *Interp, f: Value, args: []const Value, span: Span) Error!Value {
        switch (f) {
            .func => |fun| return ip.callFunc(fun, fun.self_obj, args, span),
            .native => |n| {
                if (args.len < n.min_args or args.len > n.max_args) {
                    return ip.raise(span, "{s}() takes {s} argument(s), got {d}", .{ n.name, arityText(n.min_args, n.max_args), args.len });
                }
                return n.call(ip, args, span);
            },
            .bound => |b| {
                const full = mem.gpa.alloc(Value, args.len + 1) catch @panic("out of memory");
                full[0] = b.recv;
                @memcpy(full[1..], args);
                if (args.len < b.native.min_args - 1 or args.len > b.native.max_args - 1) {
                    return ip.raise(span, "{s}() takes {s} argument(s), got {d}", .{ b.native.name, arityText(b.native.min_args - 1, b.native.max_args - 1), args.len });
                }
                return b.native.call(ip, full, span);
            },
            .class => |c| return ip.instantiate(c, args, span),
            else => return ip.raise(span, "{s} is not callable", .{f.typeName()}),
        }
    }

    fn arityText(min: u8, max: u8) []const u8 {
        if (min == max) return mem.print("{d}", .{min});
        if (max == 255) return mem.print("at least {d}", .{min});
        return mem.print("{d} to {d}", .{ min, max });
    }

    pub fn callFunc(ip: *Interp, f: *value.Func, self_obj: ?*value.Object, args: []const Value, span: Span) Error!Value {
        const params = f.decl.params;
        var required: usize = 0;
        for (params) |p| {
            if (p.default == null) required += 1;
        }
        if (args.len < required or args.len > params.len) {
            const name = if (f.decl.name.len > 0) f.decl.name else "function";
            return ip.raise(span, "{s} expects {s} argument(s), got {d}", .{ name, if (required == params.len) mem.print("{d}", .{required}) else mem.print("{d} to {d}", .{ required, params.len }), args.len });
        }
        if (ip.depth >= max_depth) return ip.raise(span, "stack overflow: calls nested more than {d} deep", .{max_depth});
        ip.depth += 1;
        defer ip.depth -= 1;
        const scope = Env.create(f.env);
        if (self_obj) |o| {
            scope.declare("self", .{ .object = o }, true);
            if (f.owner) |ow| scope.declare("__owner", .{ .class = ow }, true);
        }
        for (params, 0..) |p, i| {
            const v: Value = if (i < args.len) args[i] else try ip.eval(p.default.?, scope);
            scope.declare(p.name, v, false);
        }
        ip.ret = .null_;
        ip.execStmts(f.decl.body, scope) catch |e| switch (e) {
            error.Return => {
                const r = ip.ret;
                ip.ret = .null_;
                return r;
            },
            else => return e,
        };
        return .null_;
    }

    // ------------------------------------------------------------ operators

    fn numPair(l: Value, r: Value) ?struct { a: f64, b: f64 } {
        const a: f64 = switch (l) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            else => return null,
        };
        const b: f64 = switch (r) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            else => return null,
        };
        return .{ .a = a, .b = b };
    }

    pub fn binaryOp(ip: *Interp, op: ast.BinOp, l: Value, r: Value, span: Span) Error!Value {
        switch (op) {
            .eq => return .{ .bool_ = value.equal(l, r) },
            .ne => return .{ .bool_ = !value.equal(l, r) },
            .match, .nomatch => {
                if (l != .str) return ip.raise(span, "`=~` needs a string on the left, got {s}", .{l.typeName()});
                const re: *regex.Regex = switch (r) {
                    .regex => |x| x,
                    .str => |pat| ip.cachedRegex(pat, span) catch |e| return e,
                    else => return ip.raise(span, "`=~` needs a regex or string on the right, got {s}", .{r.typeName()}),
                };
                const hit = builtins.regexTest(re, l.str);
                return .{ .bool_ = if (op == .match) hit else !hit };
            },
            .in => {
                switch (r) {
                    .array => |a| {
                        for (a.items.items) |x| if (value.equal(l, x)) return .{ .bool_ = true };
                        return .{ .bool_ = false };
                    },
                    .map => |m| {
                        if (l != .str) return .{ .bool_ = false };
                        return .{ .bool_ = m.m.contains(l.str) };
                    },
                    .str => |s| {
                        if (l != .str) return ip.raise(span, "`in` on a string needs a string on the left", .{});
                        return .{ .bool_ = std.mem.indexOf(u8, s, l.str) != null };
                    },
                    else => return ip.raise(span, "`in` needs an array, map or string on the right, got {s}", .{r.typeName()}),
                }
            },
            .lt, .le, .gt, .ge => {
                if (l == .str and r == .str) {
                    const ord = std.mem.order(u8, l.str, r.str);
                    return .{ .bool_ = switch (op) {
                        .lt => ord == .lt,
                        .le => ord != .gt,
                        .gt => ord == .gt,
                        else => ord != .lt,
                    } };
                }
                if (l == .int and r == .int) {
                    return .{ .bool_ = switch (op) {
                        .lt => l.int < r.int,
                        .le => l.int <= r.int,
                        .gt => l.int > r.int,
                        else => l.int >= r.int,
                    } };
                }
                const p = numPair(l, r) orelse return ip.raise(span, "cannot compare {s} and {s}", .{ l.typeName(), r.typeName() });
                return .{ .bool_ = switch (op) {
                    .lt => p.a < p.b,
                    .le => p.a <= p.b,
                    .gt => p.a > p.b,
                    else => p.a >= p.b,
                } };
            },
            .add => {
                if (l == .str and r == .str) {
                    return .{ .str = std.mem.concat(mem.gpa, u8, &.{ l.str, r.str }) catch @panic("out of memory") };
                }
                if (l == .array and r == .array) {
                    const a = Value.newArray();
                    a.items.appendSlice(mem.gpa, l.array.items.items) catch @panic("out of memory");
                    a.items.appendSlice(mem.gpa, r.array.items.items) catch @panic("out of memory");
                    return .{ .array = a };
                }
            },
            else => {},
        }
        // Arithmetic.
        if (l == .int and r == .int) {
            const a = l.int;
            const b = r.int;
            switch (op) {
                .add => return .{ .int = std.math.add(i64, a, b) catch return ip.raise(span, "integer overflow", .{}) },
                .sub => return .{ .int = std.math.sub(i64, a, b) catch return ip.raise(span, "integer overflow", .{}) },
                .mul => return .{ .int = std.math.mul(i64, a, b) catch return ip.raise(span, "integer overflow", .{}) },
                .div => {
                    if (b == 0) return ip.raise(span, "division by zero", .{});
                    if (a == std.math.minInt(i64) and b == -1) return ip.raise(span, "integer overflow", .{});
                    return .{ .int = @divTrunc(a, b) };
                },
                .mod => {
                    if (b == 0) return ip.raise(span, "division by zero", .{});
                    if (b == -1) return .{ .int = 0 };
                    return .{ .int = @rem(a, b) };
                },
                else => unreachable,
            }
        }
        if (numPair(l, r)) |p| {
            return .{ .float = switch (op) {
                .add => p.a + p.b,
                .sub => p.a - p.b,
                .mul => p.a * p.b,
                .div => p.a / p.b,
                .mod => @rem(p.a, p.b),
                else => unreachable,
            } };
        }
        const sym = switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            else => "?",
        };
        return ip.raise(span, "cannot apply `{s}` to {s} and {s}", .{ sym, l.typeName(), r.typeName() });
    }

    var regex_cache: std.StringHashMapUnmanaged(*regex.Regex) = .empty;

    fn cachedRegex(ip: *Interp, pat: []const u8, span: Span) Error!*regex.Regex {
        if (regex_cache.get(pat)) |r| return r;
        const re = regex.compile(pat, "") catch return ip.raise(span, "invalid regex: {s}", .{regex.last_error});
        regex_cache.put(mem.gpa, pat, re) catch @panic("out of memory");
        return re;
    }
};

pub fn reportParse(_: parser.ParseError) void {
    sys.write(2, source.render("error", parser.diag.message, parser.diag.span));
}
