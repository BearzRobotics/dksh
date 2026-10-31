//! Our own `fnmatch` and filename globbing (SPEC 4.2). Backslash escapes the
//! next pattern character, which is how quoted text is kept literal.

const std = @import("std");
const mem = @import("mem.zig");
const sys = @import("sys.zig");

pub fn isMagic(comp: []const u8) bool {
    var i: usize = 0;
    while (i < comp.len) : (i += 1) {
        switch (comp[i]) {
            '\\' => i += 1,
            '*', '?', '[' => return true,
            else => {},
        }
    }
    return false;
}

fn unescape(comp: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < comp.len) : (i += 1) {
        if (comp[i] == '\\' and i + 1 < comp.len) i += 1;
        out.append(mem.gpa, comp[i]) catch @panic("out of memory");
    }
    return out.items;
}

/// Match one `[...]` class at pat[pi] (which is '['). Returns null when the
/// bracket is unterminated, otherwise whether `c` matched and where it ends.
fn matchClass(pat: []const u8, pi: usize, c: u8) ?struct { hit: bool, next: usize } {
    var i = pi + 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }
    var hit = false;
    var first = true;
    while (i < pat.len) {
        if (pat[i] == ']' and !first) {
            return .{ .hit = hit != negate, .next = i + 1 };
        }
        first = false;
        var lo = pat[i];
        if (lo == '[' and i + 1 < pat.len and pat[i + 1] == ':') {
            if (std.mem.indexOfPos(u8, pat, i + 2, ":]")) |end| {
                const name = pat[i + 2 .. end];
                const ok = if (std.mem.eql(u8, name, "alpha")) std.ascii.isAlphabetic(c) else if (std.mem.eql(u8, name, "digit")) std.ascii.isDigit(c) else if (std.mem.eql(u8, name, "alnum")) std.ascii.isAlphanumeric(c) else if (std.mem.eql(u8, name, "upper")) std.ascii.isUpper(c) else if (std.mem.eql(u8, name, "lower")) std.ascii.isLower(c) else if (std.mem.eql(u8, name, "space")) std.ascii.isWhitespace(c) else if (std.mem.eql(u8, name, "punct")) (std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ') else if (std.mem.eql(u8, name, "xdigit")) std.ascii.isHex(c) else false;
                if (ok) hit = true;
                i = end + 2;
                continue;
            }
        }
        if (lo == '\\' and i + 1 < pat.len) {
            i += 1;
            lo = pat[i];
        }
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            var hi = pat[i + 2];
            var adv: usize = 3;
            if (hi == '\\' and i + 3 < pat.len) {
                hi = pat[i + 3];
                adv = 4;
            }
            if (c >= lo and c <= hi) hit = true;
            i += adv;
        } else {
            if (c == lo) hit = true;
            i += 1;
        }
    }
    return null;
}

pub fn fnmatch(pat: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;
    while (si < s.len) {
        if (pi < pat.len) {
            const p = pat[pi];
            switch (p) {
                '*' => {
                    star_pi = pi;
                    star_si = si;
                    pi += 1;
                    continue;
                },
                '?' => {
                    pi += 1;
                    si += 1;
                    continue;
                },
                '[' => {
                    if (matchClass(pat, pi, s[si])) |m| {
                        if (m.hit) {
                            pi = m.next;
                            si += 1;
                            continue;
                        }
                    } else if (s[si] == '[') {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                },
                '\\' => {
                    if (pi + 1 < pat.len and pat[pi + 1] == s[si]) {
                        pi += 2;
                        si += 1;
                        continue;
                    }
                },
                else => if (p == s[si]) {
                    pi += 1;
                    si += 1;
                    continue;
                },
            }
        }
        if (star_pi) |sp| {
            pi = sp + 1;
            star_si += 1;
            si = star_si;
            continue;
        }
        return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Expand `pattern` against the filesystem. Result is sorted.
pub fn expand(pattern: []const u8) ![]const []const u8 {
    var comps: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, pattern, '/');
    while (it.next()) |c| comps.append(mem.gpa, c) catch @panic("out of memory");

    var current: std.ArrayList([]const u8) = .empty;
    const absolute = pattern.len > 0 and pattern[0] == '/';
    current.append(mem.gpa, if (absolute) "/" else "") catch @panic("out of memory");

    var any_magic = false;
    for (comps.items, 0..) |comp, ci| {
        if (comp.len == 0) continue; // leading '/' or '//' or trailing '/'
        const last = ci == comps.items.len - 1 or blk: {
            // A trailing slash makes the last real component a directory match.
            break :blk false;
        };
        _ = last;
        var next: std.ArrayList([]const u8) = .empty;
        const is_magic = isMagic(comp);
        if (is_magic) any_magic = true;
        for (current.items) |base| {
            if (!is_magic) {
                next.append(mem.gpa, join(base, unescape(comp))) catch @panic("out of memory");
                continue;
            }
            const dir = if (base.len == 0) "." else base;
            const names = sys.listDir(mem.gpa, dir) catch continue;
            for (names) |name| {
                if (name[0] == '.' and comp[0] != '.') continue;
                if (fnmatch(comp, name)) next.append(mem.gpa, join(base, name)) catch @panic("out of memory");
            }
        }
        current = next;
    }
    // Make sure results exist (non-magic tails are not checked until here)
    // and respect a trailing slash.
    const want_dir = pattern.len > 1 and pattern[pattern.len - 1] == '/';
    var result: std.ArrayList([]const u8) = .empty;
    for (current.items) |p| {
        const kind = sys.kindOf(mem.gpa, p);
        if (kind == .none) continue;
        if (want_dir) {
            if (kind != .dir) continue;
            result.append(mem.gpa, mem.print("{s}/", .{p})) catch @panic("out of memory");
        } else result.append(mem.gpa, p) catch @panic("out of memory");
    }
    std.mem.sort([]const u8, result.items, {}, lessThan);
    return result.items;
}

fn join(base: []const u8, name: []const u8) []const u8 {
    if (base.len == 0) return name;
    if (base[base.len - 1] == '/') return mem.print("{s}{s}", .{ base, name });
    return mem.print("{s}/{s}", .{ base, name });
}

test "fnmatch" {
    const t = std.testing;
    try t.expect(fnmatch("*.txt", "a.txt"));
    try t.expect(!fnmatch("*.txt", "a.txt.bak"));
    try t.expect(fnmatch("a?c", "abc"));
    try t.expect(fnmatch("[a-c]x", "bx"));
    try t.expect(!fnmatch("[!a-c]x", "bx"));
    try t.expect(fnmatch("[[:digit:]]*", "9lives"));
    try t.expect(fnmatch("\\*", "*"));
    try t.expect(!fnmatch("\\*", "a"));
    try t.expect(fnmatch("a*b*c", "aXXbYYc"));
}
