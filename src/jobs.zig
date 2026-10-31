//! Job control (SPEC 6.5): process groups, terminal ownership, stopped jobs.
//!
//! Job control is only active in an interactive shell. In scripts every
//! function here degrades to plain fork/wait bookkeeping.

const std = @import("std");
const linux = std.os.linux;
const ast = @import("ast.zig");
const mem = @import("mem.zig");
const sys = @import("sys.zig");
const source = @import("source.zig");
const Interp = @import("interp.zig").Interp;
const Error = @import("value.zig").Error;

const State = enum { running, stopped, done };

const Job = struct {
    id: u32,
    pgid: sys.pid_t,
    pids: []sys.pid_t,
    done: []bool,
    cmd: []const u8,
    state: State,
    status: u8 = 0,
    /// A finished/stopped state change the user has not been told about yet.
    notify: bool = false,
};

var table: std.ArrayList(*Job) = .empty;
var next_id: u32 = 1;
var shell_pgid: sys.pid_t = 0;
var tty_fd: sys.fd_t = 0;
var shell_modes: ?linux.termios = null;

const Disp = enum { ign, dfl };

fn setSignal(sig: linux.SIG, d: Disp) void {
    const act: linux.Sigaction = .{
        .handler = .{ .handler = if (d == .ign) linux.SIG.IGN else linux.SIG.DFL },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(sig, &act, null);
}

/// Zig's start-up code ignores SIGPIPE; children must see the default so
/// `yes | head` ends quietly.
pub fn restoreSigpipe() void {
    setSignal(.PIPE, .dfl);
}

/// In a forked child that keeps running shell code: undo the interactive
/// shell's signal handling so Ctrl-C and friends work again.
pub fn resetSignals() void {
    for ([_]linux.SIG{ .INT, .QUIT, .TSTP, .TTIN, .TTOU }) |s| setSignal(s, .dfl);
}

/// The terminal went away: hang up every job, then leave. Only async-signal-safe
/// calls (kill, exit_group) are used.
fn onHangup(_: linux.SIG) callconv(.c) void {
    for (table.items) |j| {
        _ = linux.kill(-j.pgid, .HUP);
        _ = linux.kill(-j.pgid, .CONT); // a stopped job must wake up to see the HUP
    }
    linux.exit_group(129);
}

/// Called once by an interactive shell: take ownership of the terminal.
pub fn initInteractive() void {
    const hup: linux.Sigaction = .{ .handler = .{ .handler = onHangup }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.HUP, &hup, null);
    // Loop until we are in the foreground (a shell started from another shell's job).
    shell_pgid = sys.getpid();
    sys.setpgid(0, shell_pgid);
    for ([_]linux.SIG{ .INT, .QUIT, .TSTP, .TTIN, .TTOU }) |s| setSignal(s, .ign);
    var pg = shell_pgid;
    _ = linux.tcsetpgrp(tty_fd, &pg);
    var t: linux.termios = undefined;
    if (linux.errno(linux.tcgetattr(tty_fd, &t)) == .SUCCESS) shell_modes = t;
}

/// In a freshly forked child, before exec: join the process group, reset signals.
pub fn childSetup(pgid: sys.pid_t, interactive: bool) void {
    if (!interactive) return;
    sys.setpgid(0, pgid);
    for ([_]linux.SIG{ .INT, .QUIT, .TSTP, .TTIN, .TTOU }) |s| setSignal(s, .dfl);
}

/// In the parent right after fork (the child does the same, so whoever runs first wins).
pub fn parentSetup(pid: sys.pid_t, pgid: sys.pid_t, interactive: bool) void {
    if (!interactive) return;
    sys.setpgid(pid, pgid);
}

fn giveTerminal(pgid: sys.pid_t) void {
    var pg = pgid;
    _ = linux.tcsetpgrp(tty_fd, &pg);
}

fn restoreShellModes() void {
    if (shell_modes) |m| _ = linux.tcsetattr(tty_fd, .DRAIN, &m);
}

fn newJob(pids: []const sys.pid_t, pgid: sys.pid_t, cmd: []const u8, state: State) *Job {
    const j = mem.gpa.create(Job) catch @panic("out of memory");
    j.* = .{
        .id = next_id,
        .pgid = pgid,
        .pids = mem.gpa.dupe(sys.pid_t, pids) catch @panic("out of memory"),
        .done = mem.gpa.alloc(bool, pids.len) catch @panic("out of memory"),
        .cmd = cmd,
        .state = state,
    };
    @memset(j.done, false);
    next_id += 1;
    table.append(mem.gpa, j) catch @panic("out of memory");
    return j;
}

fn remove(j: *Job) void {
    for (table.items, 0..) |x, i| {
        if (x == j) {
            _ = table.orderedRemove(i);
            break;
        }
    }
    if (table.items.len == 0) next_id = 1;
}

fn spanText(span: ast.Span) []const u8 {
    const text = source.get(span.file).text;
    const s = @min(span.start, text.len);
    const e = @min(span.end, text.len);
    return std.mem.trim(u8, text[s..e], " \t\n");
}

/// Wait for a job's processes. Returns its status, or 128+sig if it stopped.
fn waitJob(ip: *Interp, j: *Job) u8 {
    _ = ip;
    var status: u8 = 0;
    var stopped_at: ?usize = null;
    for (j.pids, 0..) |pid, i| {
        if (j.done[i]) continue;
        const r = sys.waitpid(pid, linux.W.UNTRACED) catch {
            j.done[i] = true;
            continue;
        };
        if (linux.W.IFSTOPPED(r.status)) {
            stopped_at = i;
            j.status = sys.exitStatus(r.status);
            break;
        }
        j.done[i] = true;
        const s = sys.exitStatus(r.status);
        if (s != 0 and !(s == 141 and i + 1 < j.pids.len)) status = s;
    }
    if (stopped_at) |k| {
        // Let the rest of the group finish stopping so a later `fg` sees a clean state.
        for (j.pids, 0..) |pid, i| {
            if (j.done[i] or i <= k) continue;
            const r = sys.waitpid(pid, linux.W.UNTRACED) catch {
                j.done[i] = true;
                continue;
            };
            if (!linux.W.IFSTOPPED(r.status)) j.done[i] = true;
        }
        j.state = .stopped;
        return j.status;
    }
    j.state = .done;
    j.status = status;
    return status;
}

/// Run a freshly forked foreground pipeline to completion (or until stopped).
pub fn waitForeground(ip: *Interp, pids: []const sys.pid_t, pgid: sys.pid_t, span: ast.Span) u8 {
    const j = newJob(pids, pgid, spanText(span), .running);
    giveTerminal(pgid);
    const st = waitJob(ip, j);
    giveTerminal(shell_pgid);
    if (j.state == .stopped) {
        saveModes(j);
        printJob(j, true);
        j.notify = false;
        return st;
    }
    restoreShellModes();
    remove(j);
    return st;
}

fn saveModes(j: *Job) void {
    _ = j;
}

pub fn addBackground(pid: sys.pid_t, cmd: []const u8, interactive: bool) void {
    const j = newJob(&.{pid}, pid, cmd, .running);
    if (interactive) sys.write(2, mem.print("[{d}] {d}\n", .{ j.id, pid }));
}

fn stateName(s: State) []const u8 {
    return switch (s) {
        .running => "Running",
        .stopped => "Stopped",
        .done => "Done",
    };
}

fn printJob(j: *Job, newline_first: bool) void {
    const cur: u8 = if (table.items.len > 0 and table.items[table.items.len - 1] == j) '+' else '-';
    sys.write(2, mem.print("{s}[{d}]{c}  {s: <10} {s}\n", .{ if (newline_first) "\n" else "", j.id, cur, stateName(j.state), j.cmd }));
}

pub fn printJobs() void {
    for (table.items) |j| {
        const cur: u8 = if (table.items[table.items.len - 1] == j) '+' else '-';
        sys.write(1, mem.print("[{d}]{c}  {s: <10} {s}\n", .{ j.id, cur, stateName(j.state), j.cmd }));
    }
}

/// Collect state changes of background jobs; call before showing each prompt.
pub fn reapAndReport() void {
    while (true) {
        const r = sys.waitpid(-1, linux.W.NOHANG | linux.W.UNTRACED | linux.W.CONTINUED) catch break;
        if (r.pid == 0) break;
        for (table.items) |j| {
            for (j.pids, 0..) |pid, i| {
                if (pid != r.pid) continue;
                if (r.status == 0xffff) { // WIFCONTINUED (must precede the stopped test)
                    j.state = .running;
                } else if (linux.W.IFSTOPPED(r.status)) {
                    j.state = .stopped;
                    j.notify = true;
                } else {
                    j.done[i] = true;
                    j.status = sys.exitStatus(r.status);
                    var all = true;
                    for (j.done) |d| {
                        if (!d) all = false;
                    }
                    if (all) {
                        j.state = .done;
                        j.notify = true;
                    }
                }
            }
        }
    }
    var i: usize = 0;
    while (i < table.items.len) {
        const j = table.items[i];
        if (j.notify) {
            printJob(j, false);
            j.notify = false;
        }
        if (j.state == .done) {
            _ = table.orderedRemove(i);
        } else i += 1;
    }
    if (table.items.len == 0) next_id = 1;
}

fn parseSpec(ip: *Interp, spec: ?[]const u8, span: ast.Span) Error!?*Job {
    if (table.items.len == 0) return null;
    const s = spec orelse return table.items[table.items.len - 1];
    const num_text = if (s.len > 0 and s[0] == '%') s[1..] else s;
    const n = std.fmt.parseInt(u32, num_text, 10) catch return ip.raise(span, "invalid job spec: {s}", .{s});
    for (table.items) |j| if (j.id == n) return j;
    return ip.raise(span, "no such job: {s}", .{s});
}

pub fn foregroundCmd(ip: *Interp, spec: ?[]const u8, span: ast.Span) Error!u8 {
    const j = (try parseSpec(ip, spec, span)) orelse return ip.raise(span, "fg: no current job", .{});
    sys.write(2, mem.print("{s}\n", .{j.cmd}));
    j.state = .running;
    giveTerminal(j.pgid);
    _ = linux.kill(-j.pgid, .CONT);
    const st = waitJob(ip, j);
    giveTerminal(shell_pgid);
    if (j.state == .stopped) {
        printJob(j, true);
        return st;
    }
    restoreShellModes();
    remove(j);
    return st;
}

pub fn backgroundCmd(ip: *Interp, spec: ?[]const u8, span: ast.Span) Error!u8 {
    const j = (try parseSpec(ip, spec, span)) orelse return ip.raise(span, "bg: no current job", .{});
    j.state = .running;
    _ = linux.kill(-j.pgid, .CONT);
    printJob(j, false);
    return 0;
}

pub fn disownCmd(ip: *Interp, spec: ?[]const u8, span: ast.Span) Error!u8 {
    const j = (try parseSpec(ip, spec, span)) orelse return ip.raise(span, "disown: no current job", .{});
    remove(j);
    return 0;
}

pub fn waitCmd(ip: *Interp, spec: ?[]const u8, span: ast.Span) Error!u8 {
    if (spec != null) {
        const j = (try parseSpec(ip, spec, span)) orelse return 0;
        const st = waitJob(ip, j);
        if (j.state == .done) remove(j);
        return st;
    }
    var st: u8 = 0;
    while (table.items.len > 0) {
        const j = table.items[0];
        if (j.state == .stopped) {
            _ = table.orderedRemove(0);
            continue;
        }
        st = waitJob(ip, j);
        remove(j);
    }
    return st;
}
