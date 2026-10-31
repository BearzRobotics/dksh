//! Signal traps for scripts (`trap("INT", fn)`). The handler only records
//! that a signal arrived; the interpreter runs the script's function between
//! statements, where it is safe to run arbitrary code.

const std = @import("std");
const linux = std.os.linux;

/// Bit n set = signal n arrived and has not been handled yet.
pub var pending: u32 = 0;

fn handler(sig: linux.SIG) callconv(.c) void {
    _ = @atomicRmw(u32, &pending, .Or, @as(u32, 1) << @intCast(@intFromEnum(sig)), .monotonic);
}

pub fn anyPending() bool {
    return @atomicLoad(u32, &pending, .monotonic) != 0;
}

/// Take and clear the set of pending signals.
pub fn takePending() u32 {
    return @atomicRmw(u32, &pending, .Xchg, 0, .monotonic);
}

pub const names = [_]struct { name: []const u8, sig: linux.SIG }{
    .{ .name = "HUP", .sig = .HUP },
    .{ .name = "INT", .sig = .INT },
    .{ .name = "QUIT", .sig = .QUIT },
    .{ .name = "USR1", .sig = .USR1 },
    .{ .name = "USR2", .sig = .USR2 },
    .{ .name = "PIPE", .sig = .PIPE },
    .{ .name = "ALRM", .sig = .ALRM },
    .{ .name = "TERM", .sig = .TERM },
    .{ .name = "CHLD", .sig = .CHLD },
    .{ .name = "CONT", .sig = .CONT },
    .{ .name = "TSTP", .sig = .TSTP },
    .{ .name = "WINCH", .sig = .WINCH },
    .{ .name = "KILL", .sig = .KILL },
    .{ .name = "STOP", .sig = .STOP },
};

/// "INT", "SIGINT" or a number.
pub fn parse(text: []const u8) ?linux.SIG {
    var t = text;
    if (std.mem.startsWith(u8, t, "SIG")) t = t[3..];
    for (names) |n| if (std.mem.eql(u8, n.name, t)) return n.sig;
    const num = std.fmt.parseInt(u8, t, 10) catch return null;
    if (num == 0 or num >= 32) return null;
    return @enumFromInt(num);
}

pub fn nameOf(sig: linux.SIG) []const u8 {
    for (names) |n| if (n.sig == sig) return n.name;
    return "?";
}

pub const Disposition = enum { catch_, default, ignore };

pub fn set(sig: linux.SIG, d: Disposition) void {
    const act: linux.Sigaction = .{
        .handler = .{ .handler = switch (d) {
            .catch_ => handler,
            .default => linux.SIG.DFL,
            .ignore => linux.SIG.IGN,
        } },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(sig, &act, null);
}
