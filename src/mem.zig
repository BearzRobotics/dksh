//! Process-wide allocator. It is garbage collected (see gc.zig, which also
//! explains how this differs from the reference counting sketched in SPEC 5.3),
//! so nothing is ever freed by hand.

const std = @import("std");
const gc = @import("gc.zig");

pub const gpa: std.mem.Allocator = gc.allocator;

pub fn dupe(s: []const u8) []const u8 {
    return gpa.dupe(u8, s) catch @panic("out of memory");
}

pub fn print(comptime fmt: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(gpa, fmt, args) catch @panic("out of memory");
}
