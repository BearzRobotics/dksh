//! Loaded source files and source-located diagnostics (SPEC 5.8).

const std = @import("std");
const ast = @import("ast.zig");
const mem = @import("mem.zig");

pub const File = struct { name: []const u8, text: []const u8 };

var files: std.ArrayList(File) = .empty;

/// Register a file and return its id for use in `Span.file`.
pub fn add(name: []const u8, text: []const u8) u16 {
    files.append(mem.gpa, .{ .name = name, .text = text }) catch @panic("out of memory");
    return @intCast(files.items.len - 1);
}

pub fn get(id: u16) File {
    return files.items[id];
}

pub const Loc = struct { line: u32, col: u32, line_start: u32, line_end: u32 };

pub fn locate(span: ast.Span) Loc {
    const text = files.items[span.file].text;
    const pos = @min(span.start, text.len);
    var line: u32 = 1;
    var ls: u32 = 0;
    for (text[0..pos], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            ls = @intCast(i + 1);
        }
    }
    var le: u32 = ls;
    while (le < text.len and text[le] != '\n') le += 1;
    return .{ .line = line, .col = pos - ls + 1, .line_start = ls, .line_end = le };
}

fn digits(n: u32) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

fn spaces(w: *std.ArrayList(u8), n: usize) void {
    w.appendNTimes(mem.gpa, ' ', n) catch {};
}

/// Render a diagnostic in the format shown in SPEC 5.8.
pub fn render(severity: []const u8, message: []const u8, span: ast.Span) []u8 {
    const f = files.items[span.file];
    const loc = locate(span);
    var out: std.ArrayList(u8) = .empty;
    const pad = digits(loc.line);
    out.print(mem.gpa, "{s}: {s}\n", .{ severity, message }) catch {};
    spaces(&out, pad);
    out.print(mem.gpa, "--> {s}:{d}:{d}\n", .{ f.name, loc.line, loc.col }) catch {};
    spaces(&out, pad + 1);
    out.appendSlice(mem.gpa, "|\n") catch {};
    const line_text = f.text[loc.line_start..loc.line_end];
    out.print(mem.gpa, "{d} | {s}\n", .{ loc.line, line_text }) catch {};
    spaces(&out, pad + 1);
    out.appendSlice(mem.gpa, "| ") catch {};
    const col0 = loc.col - 1;
    for (line_text[0..@min(col0, line_text.len)]) |c| out.append(mem.gpa, if (c == '\t') '\t' else ' ') catch {};
    const end = @min(span.end, loc.line_end);
    const len = if (end > span.start) end - span.start else 1;
    out.appendNTimes(mem.gpa, '^', @max(len, 1)) catch {};
    out.append(mem.gpa, '\n') catch {};
    return out.items;
}
