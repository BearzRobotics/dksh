//! Running commands: word expansion, pipelines, redirections and capture
//! (SPEC 5.5, 5.6). Job control layers on top in `jobs.zig`.

const std = @import("std");
const linux = std.os.linux;
const ast = @import("ast.zig");
const mem = @import("mem.zig");
const sys = @import("sys.zig");
const glob = @import("glob.zig");
const source = @import("source.zig");
const value = @import("value.zig");
const builtins = @import("builtins.zig");
const jobs = @import("jobs.zig");
const Interp = @import("interp.zig").Interp;

const Value = value.Value;
const Env = value.Env;
const Span = ast.Span;
const Error = value.Error;

// ------------------------------------------------------------------ expansion

fn argString(ip: *Interp, v: Value, span: Span) Error![]const u8 {
    return switch (v) {
        .str => |s| s,
        .int, .float, .bool_ => value.toDisplayString(v),
        .array => ip.raise(span, "an array cannot be used as one argument; use @name to splice it", .{}),
        .null_ => ip.raise(span, "null cannot be used as an argument", .{}),
        else => ip.raise(span, "{s} cannot be used as an argument", .{v.typeName()}),
    };
}

fn lookupCmdVar(ip: *Interp, name: []const u8, env: *Env, span: Span) Error!Value {
    if (env.lookup(name)) |v| return v.value;
    if (ip.env_map.get(name)) |v| return v;
    return ip.raise(span, "undefined variable `{s}`", .{name});
}

fn appendEscaped(pat: *std.ArrayList(u8), s: []const u8) void {
    for (s) |c| {
        if (c == '*' or c == '?' or c == '[' or c == '\\') pat.append(mem.gpa, '\\') catch @panic("out of memory");
        pat.append(mem.gpa, c) catch @panic("out of memory");
    }
}

/// Expand one word into zero or more arguments.
pub fn expandWord(ip: *Interp, w: ast.Word, env: *Env, out: *std.ArrayList([]const u8)) Error!void {
    var buf: std.ArrayList(u8) = .empty; // the literal result
    var pat: std.ArrayList(u8) = .empty; // the same text as a glob pattern
    var has_glob = false;

    for (w.parts) |part| switch (part) {
        .text => |t| {
            buf.appendSlice(mem.gpa, t.s) catch @panic("out of memory");
            if (t.quoted) {
                appendEscaped(&pat, t.s);
            } else {
                pat.appendSlice(mem.gpa, t.s) catch @panic("out of memory");
                if (glob.isMagic(t.s)) has_glob = true;
            }
        },
        .var_ => |vr| {
            var v = try lookupCmdVar(ip, vr.name, env, w.span);
            var rest_start: usize = 0;
            // `$obj.field` only applies when the value has fields.
            for (vr.fields, 0..) |f, i| {
                if (v == .map or v == .object) {
                    v = try ip.getMember(v, f, w.span);
                    rest_start = i + 1;
                } else break;
            }
            const s = try argString(ip, v, w.span);
            buf.appendSlice(mem.gpa, s) catch @panic("out of memory");
            appendEscaped(&pat, s);
            for (vr.fields[rest_start..]) |f| {
                buf.append(mem.gpa, '.') catch @panic("out of memory");
                buf.appendSlice(mem.gpa, f) catch @panic("out of memory");
                pat.append(mem.gpa, '.') catch @panic("out of memory");
                pat.appendSlice(mem.gpa, f) catch @panic("out of memory");
            }
        },
        .expr => |e| {
            const s = try argString(ip, try ip.eval(e, env), e.span);
            buf.appendSlice(mem.gpa, s) catch @panic("out of memory");
            appendEscaped(&pat, s);
        },
        .cmd_sub => |c| {
            const text = try capture(ip, c.list, env);
            if (c.lines) {
                if (w.parts.len != 1) return ip.raise(w.span, "@(...) must be a whole word", .{});
                const arr = Interp.linesOf(text).array;
                for (arr.items.items) |l| out.append(mem.gpa, l.str) catch @panic("out of memory");
                return;
            }
            buf.appendSlice(mem.gpa, text) catch @panic("out of memory");
            appendEscaped(&pat, text);
        },
        .splice => |e| {
            if (w.parts.len != 1) return ip.raise(w.span, "@name must be a whole word", .{});
            const v = try ip.eval(e, env);
            if (v != .array) return ip.raise(e.span, "@ splices an array, got {s}", .{v.typeName()});
            for (v.array.items.items) |item| out.append(mem.gpa, try argString(ip, item, e.span)) catch @panic("out of memory");
            return;
        },
        .tilde => |user| {
            const home: ?[]const u8 = if (user.len == 0)
                (if (ip.env_map.get("HOME")) |h| (if (h == .str) h.str else null) else null)
            else
                sys.homeOf(user);
            const h = home orelse {
                // Unknown user: leave the text alone, like a literal.
                buf.append(mem.gpa, '~') catch @panic("out of memory");
                buf.appendSlice(mem.gpa, user) catch @panic("out of memory");
                pat.append(mem.gpa, '~') catch @panic("out of memory");
                pat.appendSlice(mem.gpa, user) catch @panic("out of memory");
                continue;
            };
            buf.appendSlice(mem.gpa, h) catch @panic("out of memory");
            appendEscaped(&pat, h);
        },
    };

    if (has_glob) {
        const matches = glob.expand(pat.items) catch return ip.raise(w.span, "glob failed: {s}", .{sys.errnoText()});
        if (matches.len == 0) return ip.raise(w.span, "no matches for glob pattern: {s}", .{buf.items});
        for (matches) |m| out.append(mem.gpa, m) catch @panic("out of memory");
        return;
    }
    out.append(mem.gpa, buf.items) catch @panic("out of memory");
}

// ------------------------------------------------------------------- staging

const Redir = struct { kind: ast.RedirKind, arg: []const u8, span: Span, fd: sys.fd_t = -1 };

const Target = union(enum) {
    func: *value.Func,
    builtin: builtins.CommandFn,
    external: [:0]const u8,
    /// Command could not be resolved (lenient contexts report status 127).
    missing,
};

const Stage = struct {
    span: Span,
    argv: []const []const u8,
    target: Target,
    redirs: []const Redir,
};

fn searchPath(ip: *Interp, name: []const u8) ?[:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (sys.isExecutable(mem.gpa, name)) return sys.dupeZ(mem.gpa, name) catch null;
        return null;
    }
    const path_v = ip.env_map.get("PATH");
    const path = if (path_v) |p| (if (p == .str) p.str else "/usr/bin:/bin") else "/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const d = if (dir.len == 0) "." else dir;
        const full = std.fs.path.join(mem.gpa, &.{ d, name }) catch continue;
        if (sys.isExecutable(mem.gpa, full)) return sys.dupeZ(mem.gpa, full) catch null;
    }
    return null;
}

/// `-x`: show the command as it will run, quoted so each argument is visible.
fn traceCommand(argv: []const []const u8) void {
    var line: std.ArrayList(u8) = .empty;
    line.appendSlice(mem.gpa, "+") catch {};
    for (argv) |a| {
        line.append(mem.gpa, ' ') catch {};
        var plain = a.len > 0;
        for (a) |c| {
            if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_@%+=:,./-", c) != null)) plain = false;
        }
        if (plain) {
            line.appendSlice(mem.gpa, a) catch {};
        } else {
            line.append(mem.gpa, '\'') catch {};
            for (a) |c| {
                if (c == '\'') line.appendSlice(mem.gpa, "'\\''") catch {} else line.append(mem.gpa, c) catch {};
            }
            line.append(mem.gpa, '\'') catch {};
        }
    }
    line.append(mem.gpa, '\n') catch {};
    sys.write(2, line.items);
}

fn prepare(ip: *Interp, cmd: ast.Command, env: *Env, strict: bool) Error!Stage {
    _ = strict; // kept for callers; a missing command no longer depends on it
    var argv: std.ArrayList([]const u8) = .empty;
    for (cmd.words) |w| try expandWord(ip, w, env, &argv);

    var redirs: std.ArrayList(Redir) = .empty;
    for (cmd.redirs) |r| {
        var arg: []const u8 = "";
        if (r.target) |t| {
            var tmp: std.ArrayList([]const u8) = .empty;
            try expandWord(ip, t, env, &tmp);
            if (tmp.items.len != 1) return ip.raise(t.span, "a redirection needs exactly one target, got {d}", .{tmp.items.len});
            arg = tmp.items[0];
        }
        var fd: sys.fd_t = -1;
        switch (r.kind) {
            .out, .append, .err, .err_append, .both => {
                const append = r.kind == .append or r.kind == .err_append;
                fd = sys.open(mem.gpa, arg, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = !append, .APPEND = append, .CLOEXEC = true }, 0o666) catch {
                    closeRedirs(redirs.items);
                    return ip.raise(r.span, "cannot open {s} for writing: {s}", .{ arg, sys.errnoText() });
                };
            },
            .in => {
                fd = sys.open(mem.gpa, arg, .{ .CLOEXEC = true }, 0) catch {
                    closeRedirs(redirs.items);
                    return ip.raise(r.span, "cannot open {s} for reading: {s}", .{ arg, sys.errnoText() });
                };
            },
            else => {},
        }
        redirs.append(mem.gpa, .{ .kind = r.kind, .arg = arg, .span = r.span, .fd = fd }) catch @panic("out of memory");
    }

    if (argv.items.len == 0) return ip.raise(cmd.span, "empty command", .{});
    const name = argv.items[0];
    if (name.len == 0) return ip.raise(cmd.words[0].span, "empty command name", .{});

    var target: Target = .missing;
    if (env.lookup(name)) |v| {
        if (v.value == .func) target = .{ .func = v.value.func };
    }
    if (target == .missing) {
        if (builtins.findCommand(name)) |b| target = .{ .builtin = b };
    }
    if (target == .missing) {
        if (searchPath(ip, name)) |p| target = .{ .external = p };
    }
    // A command that cannot be found is always an error, except inside status().
    if (target == .missing and ip.status_depth == 0) {
        if (std.mem.indexOfScalar(u8, name, '/') != null and sys.kindOf(mem.gpa, name) != .none) {
            return ip.raiseStatus(cmd.words[0].span, 126, "permission denied: {s}", .{name});
        }
        return ip.raiseStatus(cmd.words[0].span, 127, "command not found: {s}", .{name});
    }
    if (ip.trace) traceCommand(argv.items);
    return .{ .span = cmd.span, .argv = argv.items, .target = target, .redirs = redirs.items };
}

// --------------------------------------------------------------- redirection

fn closeRedirs(redirs: []const Redir) void {
    for (redirs) |r| if (r.fd >= 0) sys.close(r.fd);
}

/// Apply redirections (already opened by `prepare`) to this process.
/// Returns false after printing why on failure.
fn applyRedirs(redirs: []const Redir) bool {
    for (redirs) |r| switch (r.kind) {
        .out, .append => sys.dup2(r.fd, 1) catch return false,
        .err, .err_append => sys.dup2(r.fd, 2) catch return false,
        .both => {
            sys.dup2(r.fd, 1) catch return false;
            sys.dup2(r.fd, 2) catch return false;
        },
        .in => sys.dup2(r.fd, 0) catch return false,
        .err_to_out => sys.dup2(1, 2) catch return false,
        .here_string => {
            const text = mem.print("{s}\n", .{r.arg});
            if (text.len > 60000) {
                sys.write(2, source.render("error", "here-string is too long (limit 60000 bytes)", r.span));
                return false;
            }
            const p = sys.pipe() catch return false;
            sys.write(p[1], text);
            sys.close(p[1]);
            sys.dup2(p[0], 0) catch return false;
            sys.close(p[0]);
        },
    };
    return true;
}

// ------------------------------------------------------------------ execution

fn strArgs(argv: []const []const u8) []const Value {
    const vals = mem.gpa.alloc(Value, argv.len) catch @panic("out of memory");
    for (argv, 0..) |a, i| vals[i] = .{ .str = a };
    return vals;
}

fn runLocal(ip: *Interp, st: Stage) Error!u8 {
    switch (st.target) {
        .func => |f| {
            _ = try ip.callFunc(f, f.self_obj, strArgs(st.argv[1..]), st.span);
            return 0;
        },
        .builtin => |b| return b(ip, st.argv, st.span),
        else => unreachable,
    }
}

fn buildEnvp(ip: *Interp) [*:null]const ?[*:0]const u8 {
    const m = ip.env_map.m;
    const arr = mem.gpa.alloc(?[*:0]const u8, m.count() + 1) catch @panic("out of memory");
    var i: usize = 0;
    var it = m.iterator();
    while (it.next()) |e| {
        const s = sys.dupeZ(mem.gpa, mem.print("{s}={s}", .{ e.key_ptr.*, value.toDisplayString(e.value_ptr.*) })) catch @panic("out of memory");
        arr[i] = s.ptr;
        i += 1;
    }
    arr[i] = null;
    return @ptrCast(arr.ptr);
}

fn execExternal(ip: *Interp, st: Stage) noreturn {
    const argv = mem.gpa.alloc(?[*:0]const u8, st.argv.len + 1) catch sys.exit(127);
    for (st.argv, 0..) |a, i| {
        const z = sys.dupeZ(mem.gpa, a) catch sys.exit(127);
        argv[i] = z.ptr;
    }
    argv[st.argv.len] = null;
    const e = sys.execve(st.target.external, @ptrCast(argv.ptr), buildEnvp(ip));
    const msg = switch (e) {
        .NOENT => "No such file or directory",
        .ACCES => "Permission denied",
        .NOEXEC => "Exec format error",
        else => "cannot execute",
    };
    sys.write(2, mem.print("dksh: {s}: {s}\n", .{ st.argv[0], msg }));
    sys.exit(if (e == .NOENT) 127 else 126);
}

/// Body of a forked child: never returns.
fn childMain(ip: *Interp, st: Stage) noreturn {
    ip.in_child = true;
    ip.interactive = false;
    if (!applyRedirs(st.redirs)) sys.exit(1);
    switch (st.target) {
        .external => execExternal(ip, st),
        .missing => sys.exit(127),
        else => {
            const status = runLocal(ip, st) catch |e| switch (e) {
                error.Raise => blk: {
                    ip.report();
                    break :blk @as(u8, 1);
                },
                error.Exit => ip.exit_code,
                else => 0,
            };
            sys.exit(status);
        },
    }
}

fn runInProcess(ip: *Interp, st: Stage) Error!u8 {
    defer closeRedirs(st.redirs);
    var saved: [3]sys.fd_t = .{ -1, -1, -1 };
    if (st.redirs.len > 0) {
        for (0..3) |i| {
            const rc = linux.fcntl(@intCast(i), linux.F.DUPFD_CLOEXEC, 10);
            if (linux.errno(rc) == .SUCCESS) saved[i] = @intCast(rc);
        }
    }
    defer for (saved, 0..) |s, i| {
        if (s >= 0) {
            sys.dup2(s, @intCast(i)) catch {};
            sys.close(s);
        }
    };
    if (!applyRedirs(st.redirs)) return 1;
    return runLocal(ip, st);
}

const PipeResult = struct { status: u8, span: Span, exempt: bool = false };

fn runPipeline(ip: *Interp, pl: ast.Pipeline, env: *Env, strict: bool) Error!PipeResult {
    var res = try runPipelineRaw(ip, pl, env, strict);
    if (pl.negate) {
        res.status = if (res.status == 0) 1 else 0;
        res.exempt = true; // `! cmd` is a test, not a failure
    }
    return res;
}

fn runPipelineRaw(ip: *Interp, pl: ast.Pipeline, env: *Env, strict: bool) Error!PipeResult {
    const stages = mem.gpa.alloc(Stage, pl.cmds.len) catch @panic("out of memory");
    for (pl.cmds, 0..) |c, i| stages[i] = try prepare(ip, c, env, strict);

    if (stages.len == 1) {
        const st = stages[0];
        switch (st.target) {
            .missing => {
                closeRedirs(st.redirs);
                return .{ .status = 127, .span = st.span };
            },
            .func, .builtin => return .{ .status = try runInProcess(ip, st), .span = st.span },
            .external => {},
        }
    }
    return runForked(ip, stages, pl.span);
}

fn runForked(ip: *Interp, stages: []const Stage, span: Span) Error!PipeResult {
    const pids = mem.gpa.alloc(sys.pid_t, stages.len) catch @panic("out of memory");
    var prev_read: sys.fd_t = -1;
    var pgid: sys.pid_t = 0;
    for (stages, 0..) |st, i| {
        var fds: [2]sys.fd_t = .{ -1, -1 };
        if (i + 1 < stages.len) {
            fds = sys.pipe() catch return ip.raise(span, "cannot create pipe: {s}", .{sys.errnoText()});
        }
        const pid = sys.fork() catch return ip.raise(span, "cannot fork: {s}", .{sys.errnoText()});
        if (pid == 0) {
            jobs.childSetup(pgid, ip.interactive);
            if (prev_read >= 0) sys.dup2(prev_read, 0) catch sys.exit(1);
            if (fds[1] >= 0) sys.dup2(fds[1], 1) catch sys.exit(1);
            if (prev_read >= 0) sys.close(prev_read);
            if (fds[0] >= 0) sys.close(fds[0]);
            if (fds[1] >= 0) sys.close(fds[1]);
            childMain(ip, st);
        }
        if (pgid == 0) pgid = pid;
        jobs.parentSetup(pid, pgid, ip.interactive);
        pids[i] = pid;
        if (prev_read >= 0) sys.close(prev_read);
        if (fds[1] >= 0) sys.close(fds[1]);
        prev_read = fds[0];
    }
    if (prev_read >= 0) sys.close(prev_read);
    for (stages) |st| closeRedirs(st.redirs);

    var status: u8 = 0;
    var fail_span = stages[stages.len - 1].span;
    if (ip.interactive) {
        // Foreground job owns the terminal while it runs.
        const r = jobs.waitForeground(ip, pids, pgid, stages[stages.len - 1].span);
        return .{ .status = r, .span = fail_span };
    }
    for (pids, 0..) |pid, i| {
        const r = sys.waitpid(pid, 0) catch continue;
        const s = sys.exitStatus(r.status);
        // An upstream stage killed by SIGPIPE only means the reader finished
        // early (`yes | head`); that is not a failure.
        if (s == 141 and i + 1 < pids.len) continue;
        if (s != 0) {
            status = s;
            fail_span = stages[i].span;
        }
    }
    return .{ .status = status, .span = fail_span };
}

/// Run a command list. `strict` marks a normal statement: a failing last
/// command raises (when `ip.errexit`), and an unknown command is an error.
pub fn runCommandList(ip: *Interp, cl: *const ast.CommandList, env: *Env, strict: bool) Error!u8 {
    if (cl.background) return runBackground(ip, cl, env);
    var res = try runPipeline(ip, cl.first, env, strict and cl.rest.len == 0);
    var status = res.status;
    var last_ran: usize = 0;
    for (cl.rest, 0..) |ch, i| {
        const run = if (ch.and_) status == 0 else status != 0;
        if (!run) continue;
        res = try runPipeline(ip, ch.p, env, strict and i + 1 == cl.rest.len);
        status = res.status;
        last_ran = i + 1;
    }
    if (strict and ip.errexit and status != 0 and last_ran == cl.rest.len and !res.exempt) {
        return ip.raiseStatus(res.span, status, "command failed with status {d}: {s}", .{ status, commandText(res.span) });
    }
    // Only statements update `$?`-style state; conditions and status() do not.
    if (strict) ip.last_status = status;
    return status;
}

fn commandText(span: Span) []const u8 {
    const text = source.get(span.file).text;
    const s = @min(span.start, text.len);
    const e = @min(span.end, text.len);
    return std.mem.trim(u8, text[s..e], " \t\n");
}

fn runBackground(ip: *Interp, cl: *const ast.CommandList, env: *Env) Error!u8 {
    const pid = sys.fork() catch return ip.raise(cl.span, "cannot fork: {s}", .{sys.errnoText()});
    if (pid == 0) {
        ip.in_child = true;
        jobs.childSetup(0, ip.interactive);
        ip.interactive = false; // not the terminal owner; stages stay in this job's group
        // Background jobs must not read the terminal.
        if (sys.open(mem.gpa, "/dev/null", .{ .CLOEXEC = true }, 0)) |fd| {
            sys.dup2(fd, 0) catch {};
            sys.close(fd);
        } else |_| {}
        var copy = cl.*;
        copy.background = false;
        const st = runCommandList(ip, &copy, env, false) catch |e| switch (e) {
            error.Raise => blk: {
                ip.report();
                break :blk @as(u8, 1);
            },
            error.Exit => ip.exit_code,
            else => 0,
        };
        sys.exit(st);
    }
    jobs.parentSetup(pid, pid, ip.interactive);
    jobs.addBackground(pid, commandText(cl.span), ip.interactive);
    return 0;
}

/// Run `cl` with standard output captured; one trailing newline is removed.
pub fn capture(ip: *Interp, cl: *const ast.CommandList, env: *Env) Error![]const u8 {
    const p = sys.pipe() catch return ip.raise(cl.span, "cannot create pipe: {s}", .{sys.errnoText()});
    const pid = sys.fork() catch return ip.raise(cl.span, "cannot fork: {s}", .{sys.errnoText()});
    if (pid == 0) {
        ip.in_child = true;
        ip.interactive = false;
        sys.dup2(p[1], 1) catch sys.exit(1);
        sys.close(p[0]);
        sys.close(p[1]);
        const st = runCommandList(ip, cl, env, false) catch |e| switch (e) {
            error.Raise => blk: {
                ip.report();
                break :blk @as(u8, 1);
            },
            error.Exit => ip.exit_code,
            else => 0,
        };
        sys.exit(st);
    }
    sys.close(p[1]);
    const out = sys.readAll(mem.gpa, p[0]) catch &.{};
    sys.close(p[0]);
    const r = sys.waitpid(pid, 0) catch return ip.raise(cl.span, "wait failed", .{});
    const status = sys.exitStatus(r.status);
    if (status != 0 and ip.errexit) {
        return ip.raiseStatus(cl.span, status, "command failed with status {d}: {s}", .{ status, commandText(cl.span) });
    }
    var text: []const u8 = out;
    if (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
    return text;
}
