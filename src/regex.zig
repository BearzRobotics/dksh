//! Linear-time regular expression engine (SPEC 5.12): a Pike VM over a
//! compiled NFA, the same approach as RE2 and Go's `regexp`. A pattern can be
//! slow to compile but can never make matching super-linear, and
//! backreferences and lookaround are rejected up front.

const std = @import("std");
const mem = @import("mem.zig");
const uni = @import("unicode_tables");

/// Human-readable reason for the last failed `compile`, with a caret line.
pub var last_error: []const u8 = "";

pub const Group = struct { name: []const u8, index: usize };

const Range = struct { lo: u21, hi: u21 };

const max_cp: u21 = 0x10FFFF;
const max_prog = 200_000;
const no_pos = std.math.maxInt(usize);

// ================================================================ char sets

fn lessRange(_: void, a: Range, b: Range) bool {
    return a.lo < b.lo;
}

/// Sort and merge overlapping or touching ranges (in place; returns the slice).
fn normalize(list: *std.ArrayList(Range)) []const Range {
    std.mem.sort(Range, list.items, {}, lessRange);
    var w: usize = 0;
    for (list.items) |r| {
        if (w > 0 and @as(u32, list.items[w - 1].hi) + 1 >= r.lo) {
            if (r.hi > list.items[w - 1].hi) list.items[w - 1].hi = r.hi;
        } else {
            list.items[w] = r;
            w += 1;
        }
    }
    list.items.len = w;
    return list.items;
}

fn complement(sorted: []const Range) []const Range {
    var out: std.ArrayList(Range) = .empty;
    var next: u32 = 0;
    for (sorted) |r| {
        if (r.lo > next) out.append(mem.gpa, .{ .lo = @intCast(next), .hi = r.lo - 1 }) catch oom();
        next = @as(u32, r.hi) + 1;
    }
    if (next <= max_cp) out.append(mem.gpa, .{ .lo = @intCast(next), .hi = max_cp }) catch oom();
    return out.items;
}

fn oom() noreturn {
    @panic("out of memory");
}

fn contains(sorted: []const Range, c: u21) bool {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (c < sorted[mid].lo) {
            hi = mid;
        } else if (c > sorted[mid].hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

fn foldOf(c: u21) u21 {
    var lo: usize = 0;
    var hi: usize = uni.case_fold.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const f = uni.case_fold[mid][0];
        if (c < f) {
            hi = mid;
        } else if (c > f) {
            lo = mid + 1;
        } else return @intCast(uni.case_fold[mid][1]);
    }
    return c;
}

/// Add every case variant of members of `set` (simple folding with `unicode`,
/// ASCII-only otherwise).
fn caseClose(set: []const Range, unicode: bool) []const Range {
    var out: std.ArrayList(Range) = .empty;
    out.appendSlice(mem.gpa, set) catch oom();
    if (!unicode) {
        for (set) |r| {
            // Lower-case letters inside the range add their upper-case twin and vice versa.
            const lo_a = @max(r.lo, 'a');
            const hi_a = @min(r.hi, 'z');
            if (lo_a <= hi_a) out.append(mem.gpa, .{ .lo = lo_a - 32, .hi = hi_a - 32 }) catch oom();
            const lo_u = @max(r.lo, 'A');
            const hi_u = @min(r.hi, 'Z');
            if (lo_u <= hi_u) out.append(mem.gpa, .{ .lo = lo_u + 32, .hi = hi_u + 32 }) catch oom();
        }
        return normalize(&out);
    }
    for (uni.case_fold) |p| {
        const from: u21 = @intCast(p[0]);
        const to: u21 = @intCast(p[1]);
        // `to` is the canonical form; the whole orbit is {to} ∪ {x : fold(x) = to}.
        if (contains(set, from) or contains(set, to)) {
            out.append(mem.gpa, .{ .lo = from, .hi = from }) catch oom();
            out.append(mem.gpa, .{ .lo = to, .hi = to }) catch oom();
        }
    }
    // Members of the orbit that were reached only via a sibling.
    const first = normalize(&out);
    var again: std.ArrayList(Range) = .empty;
    again.appendSlice(mem.gpa, first) catch oom();
    for (uni.case_fold) |p| {
        const from: u21 = @intCast(p[0]);
        const to: u21 = @intCast(p[1]);
        if (contains(first, to)) again.append(mem.gpa, .{ .lo = from, .hi = from }) catch oom();
    }
    return normalize(&again);
}

// ----------------------------------------------------------- named classes

fn asciiRanges(comptime pairs: []const [2]u21) []const Range {
    const out = mem.gpa.alloc(Range, pairs.len) catch oom();
    for (pairs, 0..) |p, i| out[i] = .{ .lo = p[0], .hi = p[1] };
    return out;
}

fn catIndex(name: []const u8) ?usize {
    for (uni.category_names, 0..) |c, i| if (std.mem.eql(u8, c, name)) return i;
    return null;
}

/// Ranges of one general category, or of a whole group like `L`.
fn categorySet(name: []const u8) ?[]const Range {
    var out: std.ArrayList(Range) = .empty;
    var found = false;
    if (name.len == 1) {
        for (uni.category_names, 0..) |c, i| {
            if (c[0] != name[0]) continue;
            found = true;
            for (uni.categories) |r| if (r[2] == i) out.append(mem.gpa, .{ .lo = @intCast(r[0]), .hi = @intCast(r[1]) }) catch oom();
        }
    } else if (catIndex(name)) |idx| {
        found = true;
        for (uni.categories) |r| if (r[2] == idx) out.append(mem.gpa, .{ .lo = @intCast(r[0]), .hi = @intCast(r[1]) }) catch oom();
    }
    if (!found) return null;
    return normalize(&out);
}

fn scriptSet(name: []const u8) ?[]const Range {
    for (uni.script_names, 0..) |s, i| {
        if (!std.ascii.eqlIgnoreCase(s, name)) continue;
        var out: std.ArrayList(Range) = .empty;
        for (uni.scripts) |r| if (r[2] == i) out.append(mem.gpa, .{ .lo = @intCast(r[0]), .hi = @intCast(r[1]) }) catch oom();
        return normalize(&out);
    }
    return null;
}

fn tableSet(table: []const [3]u32, out: *std.ArrayList(Range)) void {
    for (table) |r| out.append(mem.gpa, .{ .lo = @intCast(r[0]), .hi = @intCast(r[1]) }) catch oom();
}

var uni_word_cache: ?[]const Range = null;

fn unicodeWord() []const Range {
    if (uni_word_cache) |w| return w;
    var out: std.ArrayList(Range) = .empty;
    tableSet(&uni.alphabetic, &out);
    tableSet(&uni.join_control, &out);
    for ([_][]const u8{ "M", "Nd", "Pc" }) |cat| out.appendSlice(mem.gpa, categorySet(cat).?) catch oom();
    uni_word_cache = normalize(&out);
    return uni_word_cache.?;
}

const ascii_digit = [_]Range{.{ .lo = '0', .hi = '9' }};
const ascii_word = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };
const ascii_space = [_]Range{ .{ .lo = 9, .hi = 13 }, .{ .lo = ' ', .hi = ' ' } };

fn digitSet(unicode: bool) []const Range {
    if (!unicode) return &ascii_digit;
    return categorySet("Nd").?;
}

fn wordSet(unicode: bool) []const Range {
    return if (unicode) unicodeWord() else &ascii_word;
}

fn spaceSet(unicode: bool) []const Range {
    if (!unicode) return &ascii_space;
    var out: std.ArrayList(Range) = .empty;
    tableSet(&uni.white_space, &out);
    return normalize(&out);
}

fn posixSet(name: []const u8) ?[]const Range {
    const R = struct {
        fn r(comptime pairs: []const [2]u21) []const Range {
            return asciiRanges(pairs);
        }
    };
    if (std.mem.eql(u8, name, "alpha")) return R.r(&.{ .{ 'A', 'Z' }, .{ 'a', 'z' } });
    if (std.mem.eql(u8, name, "digit")) return R.r(&.{.{ '0', '9' }});
    if (std.mem.eql(u8, name, "alnum")) return R.r(&.{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ 'a', 'z' } });
    if (std.mem.eql(u8, name, "upper")) return R.r(&.{.{ 'A', 'Z' }});
    if (std.mem.eql(u8, name, "lower")) return R.r(&.{.{ 'a', 'z' }});
    if (std.mem.eql(u8, name, "space")) return R.r(&.{ .{ 9, 13 }, .{ ' ', ' ' } });
    if (std.mem.eql(u8, name, "blank")) return R.r(&.{ .{ 9, 9 }, .{ ' ', ' ' } });
    if (std.mem.eql(u8, name, "punct")) return R.r(&.{ .{ '!', '/' }, .{ ':', '@' }, .{ '[', '`' }, .{ '{', '~' } });
    if (std.mem.eql(u8, name, "xdigit")) return R.r(&.{ .{ '0', '9' }, .{ 'A', 'F' }, .{ 'a', 'f' } });
    if (std.mem.eql(u8, name, "word")) return R.r(&.{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } });
    if (std.mem.eql(u8, name, "cntrl")) return R.r(&.{ .{ 0, 31 }, .{ 127, 127 } });
    if (std.mem.eql(u8, name, "print")) return R.r(&.{.{ ' ', '~' }});
    if (std.mem.eql(u8, name, "graph")) return R.r(&.{.{ '!', '~' }});
    if (std.mem.eql(u8, name, "ascii")) return R.r(&.{.{ 0, 127 }});
    return null;
}

// ================================================================== syntax

const Assertion = enum { bol, eol, bot, eot, word_b, not_word_b };

const Node = union(enum) {
    empty,
    char: u21,
    set: u32,
    cat: []const *Node,
    alt: []const *Node,
    repeat: struct { sub: *Node, min: u32, max: ?u32, greedy: bool },
    group: struct { sub: *Node, index: ?u32 },
    assert_: Assertion,
};

const Flags = struct {
    i: bool = false,
    m: bool = false,
    s: bool = false,
    x: bool = false,
    u: bool = false,
};

const ParseFail = error{Invalid};

const Parser = struct {
    pat: []const u8,
    pos: usize = 0,
    flags: Flags,
    sets: std.ArrayList([]const Range) = .empty,
    names: std.ArrayList(Group) = .empty,
    ngroups: u32 = 0,
    depth: u32 = 0,

    fn fail(p: *Parser, at: usize, len: usize, msg: []const u8) ParseFail {
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(mem.gpa, msg) catch oom();
        out.appendSlice(mem.gpa, "\n  pattern: ") catch oom();
        out.appendSlice(mem.gpa, p.pat) catch oom();
        out.appendSlice(mem.gpa, "\n           ") catch oom();
        out.appendNTimes(mem.gpa, ' ', at) catch oom();
        out.appendNTimes(mem.gpa, '^', @max(len, 1)) catch oom();
        last_error = out.items;
        return error.Invalid;
    }

    fn eof(p: *Parser) bool {
        return p.pos >= p.pat.len;
    }

    fn peek(p: *Parser) u8 {
        return if (p.pos < p.pat.len) p.pat[p.pos] else 0;
    }

    fn node(p: *Parser, n: Node) *Node {
        _ = p;
        const x = mem.gpa.create(Node) catch oom();
        x.* = n;
        return x;
    }

    fn addSet(p: *Parser, ranges: []const Range) *Node {
        p.sets.append(mem.gpa, ranges) catch oom();
        return p.node(.{ .set = @intCast(p.sets.items.len - 1) });
    }

    fn skipExtended(p: *Parser) void {
        if (!p.flags.x) return;
        while (!p.eof()) {
            const c = p.peek();
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                p.pos += 1;
            } else if (c == '#') {
                while (!p.eof() and p.peek() != '\n') p.pos += 1;
            } else break;
        }
    }

    fn parseAlt(p: *Parser) ParseFail!*Node {
        var branches: std.ArrayList(*Node) = .empty;
        branches.append(mem.gpa, try p.parseCat()) catch oom();
        while (p.peek() == '|' and !p.eof()) {
            p.pos += 1;
            branches.append(mem.gpa, try p.parseCat()) catch oom();
        }
        if (branches.items.len == 1) return branches.items[0];
        return p.node(.{ .alt = branches.items });
    }

    fn parseCat(p: *Parser) ParseFail!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (true) {
            p.skipExtended();
            if (p.eof() or p.peek() == '|' or p.peek() == ')') break;
            items.append(mem.gpa, try p.parseRepeat()) catch oom();
        }
        if (items.items.len == 0) return p.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return p.node(.{ .cat = items.items });
    }

    fn parseNumber(p: *Parser) ?u32 {
        const s = p.pos;
        while (!p.eof() and std.ascii.isDigit(p.peek())) p.pos += 1;
        if (p.pos == s) return null;
        return std.fmt.parseInt(u32, p.pat[s..p.pos], 10) catch 100_000;
    }

    fn parseRepeat(p: *Parser) ParseFail!*Node {
        var atom = try p.parseAtom();
        while (true) {
            p.skipExtended();
            if (p.eof()) break;
            const c = p.peek();
            const q_start = p.pos;
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => p.pos += 1,
                '+' => {
                    min = 1;
                    p.pos += 1;
                },
                '?' => {
                    max = 1;
                    p.pos += 1;
                },
                '{' => {
                    const save = p.pos;
                    p.pos += 1;
                    const lo = p.parseNumber();
                    if (lo == null) {
                        p.pos = save;
                        break;
                    }
                    min = lo.?;
                    max = min;
                    if (p.peek() == ',') {
                        p.pos += 1;
                        max = p.parseNumber();
                    }
                    if (p.peek() != '}') {
                        p.pos = save;
                        break;
                    }
                    p.pos += 1;
                    if (max != null and max.? < min) return p.fail(q_start, p.pos - q_start, "invalid repetition: max is smaller than min");
                    if (min > 1000 or (max orelse 0) > 1000) return p.fail(q_start, p.pos - q_start, "repetition count is too large (limit 1000)");
                },
                else => break,
            }
            var greedy = true;
            if (!p.eof() and p.peek() == '?') {
                greedy = false;
                p.pos += 1;
            } else if (!p.eof() and p.peek() == '+') {
                return p.fail(p.pos, 1, "possessive quantifiers are not supported");
            }
            switch (atom.*) {
                .assert_ => return p.fail(q_start, 1, "an assertion cannot be repeated"),
                else => {},
            }
            atom = p.node(.{ .repeat = .{ .sub = atom, .min = min, .max = max, .greedy = greedy } });
        }
        return atom;
    }

    fn literal(p: *Parser, c: u21) *Node {
        if (!p.flags.i) return p.node(.{ .char = c });
        const orbit = caseClose(&.{.{ .lo = c, .hi = c }}, p.flags.u);
        if (orbit.len == 1 and orbit[0].lo == orbit[0].hi) return p.node(.{ .char = c });
        return p.addSet(orbit);
    }

    fn nextCodepoint(p: *Parser) u21 {
        const n = std.unicode.utf8ByteSequenceLength(p.pat[p.pos]) catch 1;
        const end = @min(p.pos + n, p.pat.len);
        const cp = std.unicode.utf8Decode(p.pat[p.pos..end]) catch p.pat[p.pos];
        p.pos = end;
        return cp;
    }

    fn parseAtom(p: *Parser) ParseFail!*Node {
        p.skipExtended();
        const start = p.pos;
        const c = p.peek();
        switch (c) {
            '(' => return p.parseGroup(),
            '[' => return p.parseClass(),
            '.' => {
                p.pos += 1;
                const ranges: []const Range = if (p.flags.s)
                    &[_]Range{.{ .lo = 0, .hi = max_cp }}
                else
                    &[_]Range{ .{ .lo = 0, .hi = 9 }, .{ .lo = 11, .hi = max_cp } };
                return p.addSet(ranges);
            },
            '^' => {
                p.pos += 1;
                return p.node(.{ .assert_ = .bol });
            },
            '$' => {
                p.pos += 1;
                return p.node(.{ .assert_ = .eol });
            },
            '\\' => return p.parseEscape(),
            '*', '+', '?' => return p.fail(start, 1, "nothing to repeat"),
            else => {
                const cp = p.nextCodepoint();
                return p.literal(cp);
            },
        }
    }

    fn parseGroup(p: *Parser) ParseFail!*Node {
        const start = p.pos;
        p.pos += 1; // (
        var index: ?u32 = null;
        if (p.peek() == '?') {
            p.pos += 1;
            const c = p.peek();
            if (c == ':') {
                p.pos += 1;
            } else if (c == '=' or c == '!') {
                return p.fail(start, 3, "lookahead is not supported (patterns must run in linear time)");
            } else if (c == '<' or c == 'P') {
                if (c == 'P') p.pos += 1;
                if (p.peek() != '<') return p.fail(start, p.pos - start + 1, "unsupported group syntax");
                p.pos += 1;
                if (p.peek() == '=' or p.peek() == '!') return p.fail(start, 4, "lookbehind is not supported (patterns must run in linear time)");
                const ns = p.pos;
                while (!p.eof() and (std.ascii.isAlphanumeric(p.peek()) or p.peek() == '_')) p.pos += 1;
                const name = p.pat[ns..p.pos];
                if (name.len == 0 or p.peek() != '>') return p.fail(start, p.pos - start + 1, "invalid group name");
                p.pos += 1;
                for (p.names.items) |g| {
                    if (std.mem.eql(u8, g.name, name)) return p.fail(ns, name.len, "duplicate group name");
                }
                p.ngroups += 1;
                index = p.ngroups;
                p.names.append(mem.gpa, .{ .name = name, .index = p.ngroups }) catch oom();
            } else {
                return p.fail(start, 3, "inline flags and other (?...) groups are not supported; use the flags argument");
            }
        } else {
            p.ngroups += 1;
            index = p.ngroups;
        }
        p.depth += 1;
        if (p.depth > 200) return p.fail(start, 1, "pattern is nested too deeply");
        const sub = try p.parseAlt();
        p.depth -= 1;
        if (p.eof() or p.peek() != ')') return p.fail(start, 1, "missing closing )");
        p.pos += 1;
        return p.node(.{ .group = .{ .sub = sub, .index = index } });
    }

    fn parseHex(p: *Parser, start: usize) ParseFail!u21 {
        // After "\x" or "\u".
        const braces = p.peek() == '{';
        var digits: []const u8 = undefined;
        if (braces) {
            p.pos += 1;
            const s = p.pos;
            while (!p.eof() and p.peek() != '}') p.pos += 1;
            if (p.eof()) return p.fail(start, p.pos - start, "missing } in escape");
            digits = p.pat[s..p.pos];
            p.pos += 1;
        } else {
            const s = p.pos;
            var n: usize = 0;
            while (n < 2 and !p.eof() and std.ascii.isHex(p.peek())) : (n += 1) p.pos += 1;
            digits = p.pat[s..p.pos];
        }
        const v = std.fmt.parseInt(u32, digits, 16) catch return p.fail(start, p.pos - start, "invalid hex escape");
        if (v > max_cp or (v >= 0xD800 and v <= 0xDFFF)) return p.fail(start, p.pos - start, "code point out of range");
        return @intCast(v);
    }

    /// An escape that denotes a set: returns ranges, or null if it is not one.
    fn setEscape(p: *Parser, c: u8, start: usize) ParseFail!?[]const Range {
        switch (c) {
            'd' => return digitSet(p.flags.u),
            'D' => return complement(digitSet(p.flags.u)),
            'w' => return wordSet(p.flags.u),
            'W' => return complement(wordSet(p.flags.u)),
            's' => return spaceSet(p.flags.u),
            'S' => return complement(spaceSet(p.flags.u)),
            'p', 'P' => {
                if (!p.flags.u) return p.fail(start, 2, "\\p and \\P need the u flag");
                if (p.peek() != '{') return p.fail(start, 2, "expected { after \\p");
                p.pos += 1;
                const s = p.pos;
                while (!p.eof() and p.peek() != '}') p.pos += 1;
                if (p.eof()) return p.fail(start, p.pos - start, "missing } in \\p{...}");
                var name = p.pat[s..p.pos];
                p.pos += 1;
                var negate = c == 'P';
                if (name.len > 0 and name[0] == '^') {
                    negate = !negate;
                    name = name[1..];
                }
                const set = categorySet(name) orelse scriptSet(name) orelse
                    return p.fail(start, p.pos - start, "unknown Unicode category or script");
                return if (negate) complement(set) else set;
            },
            else => return null,
        }
    }

    fn parseEscape(p: *Parser) ParseFail!*Node {
        const start = p.pos;
        p.pos += 1;
        if (p.eof()) return p.fail(start, 1, "trailing backslash");
        const c = p.peek();
        p.pos += 1;
        switch (c) {
            'b' => return p.node(.{ .assert_ = .word_b }),
            'B' => return p.node(.{ .assert_ = .not_word_b }),
            'A' => return p.node(.{ .assert_ = .bot }),
            'z' => return p.node(.{ .assert_ = .eot }),
            '1'...'9' => return p.fail(start, 2, "backreferences are not supported (patterns must run in linear time)"),
            'k' => return p.fail(start, 2, "backreferences are not supported (patterns must run in linear time)"),
            else => {},
        }
        if (try p.setEscape(c, start)) |ranges| return p.addSet(ranges);
        const cp = try p.simpleEscape(c, start);
        return p.literal(cp);
    }

    /// Escapes that denote one code point.
    fn simpleEscape(p: *Parser, c: u8, start: usize) ParseFail!u21 {
        switch (c) {
            'n' => return '\n',
            't' => return '\t',
            'r' => return '\r',
            'f' => return 12,
            'v' => return 11,
            'a' => return 7,
            'e' => return 27,
            'x', 'u' => return p.parseHex(start),
            else => {
                if (std.ascii.isAlphanumeric(c)) return p.fail(start, 2, "unknown escape sequence");
                // Escaped punctuation (or a multi-byte character) stands for itself.
                p.pos -= 1;
                return p.nextCodepoint();
            },
        }
    }

    fn parseClass(p: *Parser) ParseFail!*Node {
        const start = p.pos;
        p.pos += 1; // [
        var negate = false;
        if (p.peek() == '^') {
            negate = true;
            p.pos += 1;
        }
        var items: std.ArrayList(Range) = .empty;
        var first = true;
        while (true) {
            if (p.eof()) return p.fail(start, 1, "missing closing ]");
            var c = p.peek();
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            const item_start = p.pos;
            var lo: u21 = 0;
            if (c == '[' and p.pos + 1 < p.pat.len and p.pat[p.pos + 1] == ':') {
                if (std.mem.indexOfPos(u8, p.pat, p.pos + 2, ":]")) |end| {
                    var name = p.pat[p.pos + 2 .. end];
                    var neg = false;
                    if (name.len > 0 and name[0] == '^') {
                        neg = true;
                        name = name[1..];
                    }
                    const set = posixSet(name) orelse return p.fail(item_start, end + 2 - item_start, "unknown POSIX class");
                    items.appendSlice(mem.gpa, if (neg) complement(set) else set) catch oom();
                    p.pos = end + 2;
                    continue;
                }
            }
            if (c == '\\') {
                p.pos += 1;
                if (p.eof()) return p.fail(item_start, 1, "trailing backslash");
                c = p.peek();
                p.pos += 1;
                if (try p.setEscape(c, item_start)) |ranges| {
                    items.appendSlice(mem.gpa, ranges) catch oom();
                    continue;
                }
                if (c == 'b') {
                    lo = 8; // backspace inside a class
                } else if (c >= '1' and c <= '9') {
                    return p.fail(item_start, 2, "backreferences are not supported");
                } else lo = try p.simpleEscape(c, item_start);
            } else lo = p.nextCodepoint();
            // A range "lo-hi"?
            if (p.peek() == '-' and p.pos + 1 < p.pat.len and p.pat[p.pos + 1] != ']') {
                p.pos += 1;
                var hi: u21 = 0;
                if (p.peek() == '\\') {
                    const es = p.pos;
                    p.pos += 1;
                    if (p.eof()) return p.fail(es, 1, "trailing backslash");
                    const ec = p.peek();
                    p.pos += 1;
                    if (try p.setEscape(ec, es) != null) return p.fail(item_start, p.pos - item_start, "a class cannot be a range endpoint");
                    hi = try p.simpleEscape(ec, es);
                } else hi = p.nextCodepoint();
                if (hi < lo) return p.fail(item_start, p.pos - item_start, "invalid range: end is before start");
                items.append(mem.gpa, .{ .lo = lo, .hi = hi }) catch oom();
            } else items.append(mem.gpa, .{ .lo = lo, .hi = lo }) catch oom();
        }
        var set = normalize(&items);
        if (p.flags.i) set = caseClose(set, p.flags.u);
        if (negate) set = complement(set);
        return p.addSet(set);
    }
};

// ================================================================= compiler

const Inst = union(enum) {
    char: u21,
    set: u32,
    split: struct { x: u32, y: u32 },
    jmp: u32,
    save: u32,
    assert_: Assertion,
    match,
};

const Compiler = struct {
    prog: std.ArrayList(Inst) = .empty,

    fn emit(c: *Compiler, i: Inst) ParseFail!u32 {
        if (c.prog.items.len >= max_prog) {
            last_error = "pattern is too large";
            return error.Invalid;
        }
        c.prog.append(mem.gpa, i) catch oom();
        return @intCast(c.prog.items.len - 1);
    }

    fn pc(c: *Compiler) u32 {
        return @intCast(c.prog.items.len);
    }

    fn compile(c: *Compiler, n: *const Node) ParseFail!void {
        switch (n.*) {
            .empty => {},
            .char => |ch| _ = try c.emit(.{ .char = ch }),
            .set => |s| _ = try c.emit(.{ .set = s }),
            .assert_ => |a| _ = try c.emit(.{ .assert_ = a }),
            .cat => |items| for (items) |it| try c.compile(it),
            .alt => |branches| {
                // split L1, next ; L1: b1 ; jmp end ; next: split ...
                var jumps: std.ArrayList(u32) = .empty;
                for (branches, 0..) |b, i| {
                    if (i + 1 < branches.len) {
                        const sp = try c.emit(.{ .split = .{ .x = 0, .y = 0 } });
                        c.prog.items[sp].split.x = c.pc();
                        try c.compile(b);
                        jumps.append(mem.gpa, try c.emit(.{ .jmp = 0 })) catch oom();
                        c.prog.items[sp].split.y = c.pc();
                    } else try c.compile(b);
                }
                for (jumps.items) |j| c.prog.items[j].jmp = c.pc();
            },
            .group => |g| {
                if (g.index) |idx| {
                    _ = try c.emit(.{ .save = idx * 2 });
                    try c.compile(g.sub);
                    _ = try c.emit(.{ .save = idx * 2 + 1 });
                } else try c.compile(g.sub);
            },
            .repeat => |r| try c.compileRepeat(r.sub, r.min, r.max, r.greedy),
        }
    }

    fn emitSplit(c: *Compiler, greedy: bool) ParseFail!u32 {
        _ = greedy;
        return c.emit(.{ .split = .{ .x = 0, .y = 0 } });
    }

    /// Point split `sp` at (body, out) in priority order.
    fn patch(c: *Compiler, sp: u32, body: u32, out: u32, greedy: bool) void {
        c.prog.items[sp].split = if (greedy) .{ .x = body, .y = out } else .{ .x = out, .y = body };
    }

    fn compileRepeat(c: *Compiler, sub: *const Node, min: u32, max: ?u32, greedy: bool) ParseFail!void {
        var i: u32 = 0;
        while (i < min) : (i += 1) try c.compile(sub);
        if (max) |mx| {
            // (mx - min) nested optional copies: x?(x?(x?...))
            var splits: std.ArrayList(u32) = .empty;
            var k: u32 = min;
            while (k < mx) : (k += 1) {
                const sp = try c.emitSplit(greedy);
                splits.append(mem.gpa, sp) catch oom();
                const body = c.pc();
                try c.compile(sub);
                c.prog.items[sp].split = .{ .x = body, .y = 0 };
            }
            const out = c.pc();
            for (splits.items) |sp| {
                const body = c.prog.items[sp].split.x;
                c.patch(sp, body, out, greedy);
            }
        } else if (min == 0 or true) {
            // x*: L1: split L2, out ; L2: x ; jmp L1
            const sp = try c.emitSplit(greedy);
            const body = c.pc();
            try c.compile(sub);
            _ = try c.emit(.{ .jmp = sp });
            c.patch(sp, body, c.pc(), greedy);
        }
    }
};

// ==================================================================== VM

const Sparse = struct {
    dense: []u32,
    sparse: []u32,
    n: u32 = 0,

    fn init(size: usize) Sparse {
        return .{
            .dense = mem.gpa.alloc(u32, size) catch oom(),
            .sparse = mem.gpa.alloc(u32, size) catch oom(),
        };
    }
    fn has(s: *const Sparse, pc: u32) bool {
        const i = s.sparse[pc];
        return i < s.n and s.dense[i] == pc;
    }
    fn add(s: *Sparse, pc: u32) u32 {
        s.dense[s.n] = pc;
        s.sparse[pc] = s.n;
        s.n += 1;
        return s.n - 1;
    }
};

const ThreadList = struct {
    set: Sparse,
    /// ncap entries per dense slot.
    caps: []usize,
};

const StackItem = struct { restore: bool, a: u32, b: usize };

pub const Regex = struct {
    pattern: []const u8,
    flags: []const u8 = "",
    ngroups: usize = 0,
    names: []const Group = &.{},
    unicode: bool = false,

    prog: []const Inst = &.{},
    sets: []const []const Range = &.{},
    ncap: usize = 2,
    multiline: bool = false,

    // Scratch space reused by every search (the shell is single-threaded).
    clist: ThreadList = undefined,
    nlist: ThreadList = undefined,
    stack: []StackItem = &.{},
    work: []usize = &.{},
    best: []usize = &.{},
    result: []?[2]usize = &.{},

    fn isWord(self: *const Regex, subject: []const u8, pos: usize, before: bool) bool {
        // Is the character before/after `pos` a word character?
        if (before) {
            if (pos == 0) return false;
            var s = pos - 1;
            while (s > 0 and (subject[s] & 0xC0) == 0x80 and pos - s < 4) s -= 1;
            const cp = decode(subject, s).cp;
            return self.wordChar(cp);
        }
        if (pos >= subject.len) return false;
        return self.wordChar(decode(subject, pos).cp);
    }

    fn wordChar(self: *const Regex, cp: u21) bool {
        return contains(wordSet(self.unicode), cp);
    }

    fn check(self: *const Regex, a: Assertion, subject: []const u8, pos: usize) bool {
        return switch (a) {
            .bot => pos == 0,
            .eot => pos == subject.len,
            .bol => pos == 0 or (self.multiline and subject[pos - 1] == '\n'),
            .eol => pos == subject.len or (self.multiline and subject[pos] == '\n'),
            .word_b => self.isWord(subject, pos, true) != self.isWord(subject, pos, false),
            .not_word_b => self.isWord(subject, pos, true) == self.isWord(subject, pos, false),
        };
    }

    /// Add the thread at `pc0` and everything reachable through empty moves,
    /// in priority order (SPEC 5.12: leftmost-first, like Perl and RE2).
    fn addThread(self: *Regex, list: *ThreadList, pc0: u32, subject: []const u8, pos: usize) void {
        var sp: usize = 0;
        self.stack[0] = .{ .restore = false, .a = pc0, .b = 0 };
        sp = 1;
        const ncap = self.ncap;
        while (sp > 0) {
            sp -= 1;
            const it = self.stack[sp];
            if (it.restore) {
                self.work[it.a] = it.b;
                continue;
            }
            const pc = it.a;
            if (list.set.has(pc)) continue;
            const slot = list.set.add(pc);
            switch (self.prog[pc]) {
                .jmp => |t| {
                    self.stack[sp] = .{ .restore = false, .a = t, .b = 0 };
                    sp += 1;
                },
                .split => |s| {
                    self.stack[sp] = .{ .restore = false, .a = s.y, .b = 0 };
                    self.stack[sp + 1] = .{ .restore = false, .a = s.x, .b = 0 };
                    sp += 2;
                },
                .save => |n| {
                    if (n < ncap) {
                        self.stack[sp] = .{ .restore = true, .a = n, .b = self.work[n] };
                        self.work[n] = pos;
                        self.stack[sp + 1] = .{ .restore = false, .a = pc + 1, .b = 0 };
                        sp += 2;
                    } else {
                        self.stack[sp] = .{ .restore = false, .a = pc + 1, .b = 0 };
                        sp += 1;
                    }
                },
                .assert_ => |a| {
                    if (self.check(a, subject, pos)) {
                        self.stack[sp] = .{ .restore = false, .a = pc + 1, .b = 0 };
                        sp += 1;
                    }
                },
                .char, .set, .match => {
                    @memcpy(list.caps[slot * ncap ..][0..ncap], self.work[0..ncap]);
                },
            }
        }
    }

    /// Leftmost match at or after `from`; capture 0 is the whole match.
    /// The returned slice is reused by the next `search` on this regex.
    pub fn search(self: *Regex, subject: []const u8, from: usize) ?[]const ?[2]usize {
        if (from > subject.len) return null;
        const ncap = self.ncap;
        var clist = &self.clist;
        var nlist = &self.nlist;
        clist.set.n = 0;
        nlist.set.n = 0;
        var matched = false;
        var pos = from;
        while (true) {
            if (!matched) {
                @memset(self.work[0..ncap], no_pos);
                self.addThread(clist, 0, subject, pos);
            }
            if (clist.set.n == 0) break;
            const d = if (pos < subject.len) decode(subject, pos) else Decoded{ .cp = 0, .len = 0 };
            const have_char = pos < subject.len;
            var i: u32 = 0;
            while (i < clist.set.n) : (i += 1) {
                const pc = clist.set.dense[i];
                const tcaps = clist.caps[i * ncap ..][0..ncap];
                switch (self.prog[pc]) {
                    .char => |ch| if (have_char and d.cp == ch) {
                        @memcpy(self.work[0..ncap], tcaps);
                        self.addThread(nlist, pc + 1, subject, pos + d.len);
                    },
                    .set => |s| if (have_char and contains(self.sets[s], d.cp)) {
                        @memcpy(self.work[0..ncap], tcaps);
                        self.addThread(nlist, pc + 1, subject, pos + d.len);
                    },
                    .match => {
                        @memcpy(self.best[0..ncap], tcaps);
                        matched = true;
                        break; // lower-priority threads lose
                    },
                    else => {},
                }
            }
            if (!have_char) break;
            const t = clist;
            clist = nlist;
            nlist = t;
            nlist.set.n = 0;
            pos += d.len;
        }
        // Keep the lists consistent for the next call whichever way we left.
        if (!matched) return null;
        for (0..self.ngroups + 1) |g| {
            const s = self.best[g * 2];
            const e = self.best[g * 2 + 1];
            self.result[g] = if (s == no_pos or e == no_pos) null else .{ s, e };
        }
        return self.result;
    }
};

const Decoded = struct { cp: u21, len: usize };

fn decode(s: []const u8, pos: usize) Decoded {
    const b = s[pos];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (pos + n > s.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(s[pos .. pos + n]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Compile `pattern`. `flags` is any of `i m s x u`; failures set `last_error`.
pub fn compile(pattern: []const u8, flags: []const u8) error{Invalid}!*Regex {
    var f: Flags = .{};
    for (flags) |c| switch (c) {
        'i' => f.i = true,
        'm' => f.m = true,
        's' => f.s = true,
        'x' => f.x = true,
        'u' => f.u = true,
        else => {
            last_error = mem.print("unknown regex flag '{c}' (valid flags: i m s x u)", .{c});
            return error.Invalid;
        },
    };
    var p: Parser = .{ .pat = pattern, .flags = f };
    const tree = try p.parseAlt();
    if (!p.eof()) {
        // Only a stray ')' can stop the top-level parse early.
        return p.fail(p.pos, 1, "unmatched )");
    }
    var c: Compiler = .{};
    _ = try c.emit(.{ .save = 0 });
    try c.compile(tree);
    _ = try c.emit(.{ .save = 1 });
    _ = try c.emit(.match);

    const re = mem.gpa.create(Regex) catch oom();
    const n = c.prog.items.len;
    const ncap = (p.ngroups + 1) * 2;
    re.* = .{
        .pattern = mem.dupe(pattern),
        .flags = mem.dupe(flags),
        .ngroups = p.ngroups,
        .names = p.names.items,
        .unicode = f.u,
        .prog = c.prog.items,
        .sets = p.sets.items,
        .ncap = ncap,
        .multiline = f.m,
        .clist = .{ .set = Sparse.init(n), .caps = mem.gpa.alloc(usize, n * ncap) catch oom() },
        .nlist = .{ .set = Sparse.init(n), .caps = mem.gpa.alloc(usize, n * ncap) catch oom() },
        .stack = mem.gpa.alloc(StackItem, n * 3 + 8) catch oom(),
        .work = mem.gpa.alloc(usize, ncap) catch oom(),
        .best = mem.gpa.alloc(usize, ncap) catch oom(),
        .result = mem.gpa.alloc(?[2]usize, p.ngroups + 1) catch oom(),
    };
    return re;
}

// ================================================================== tests

fn expectMatch(pat: []const u8, flags: []const u8, input: []const u8, want: ?[]const u8) !void {
    const re = try compile(pat, flags);
    const caps = re.search(input, 0);
    if (want) |w| {
        const c = caps orelse {
            std.debug.print("pattern {s} should match {s}\n", .{ pat, input });
            return error.TestExpectedMatch;
        };
        const got = input[c[0].?[0]..c[0].?[1]];
        try std.testing.expectEqualStrings(w, got);
    } else if (caps != null) {
        std.debug.print("pattern {s} should not match {s}\n", .{ pat, input });
        return error.TestUnexpectedMatch;
    }
}

// Cases adapted from RE2's search tests: literals, classes, anchors,
// quantifiers, alternation, and leftmost-first semantics.
test "re2 search: literals and anchors" {
    try expectMatch("a", "", "a", "a");
    try expectMatch("a", "", "zyzzyva", "a");
    try expectMatch("a+", "", "baaab", "aaa");
    try expectMatch("(?:(?:^).)", "", "\n", null);
    try expectMatch("^abc$", "", "abc", "abc");
    try expectMatch("^abc$", "", "xabc", null);
    try expectMatch("a$", "", "a\n", null);
    try expectMatch("^b", "m", "a\nb", "b");
    try expectMatch("a$", "m", "a\nb", "a");
    try expectMatch("\\Aab\\z", "m", "ab", "ab");
    try expectMatch("\\bfoo\\b", "", "a foo b", "foo");
    try expectMatch("\\bfoo\\b", "", "afoob", null);
    try expectMatch("\\Boo\\B", "", "foob", "oo");
}

test "re2 search: quantifiers" {
    try expectMatch("a*", "", "baaab", "");
    try expectMatch("a*", "", "aaab", "aaa");
    try expectMatch("a+?", "", "aaa", "a");
    try expectMatch("a*?", "", "aaa", "");
    try expectMatch("a??", "", "a", "");
    try expectMatch("a{2}", "", "aaa", "aa");
    try expectMatch("a{2,}", "", "aaaa", "aaaa");
    try expectMatch("a{2,3}", "", "aaaa", "aaa");
    try expectMatch("a{2,3}?", "", "aaaa", "aa");
    try expectMatch("(abc){2}", "", "abcabcabc", "abcabc");
    try expectMatch("a{,2}", "", "a{,2}", "a{,2}");
    try expectMatch("x{1}{2}", "", "xx", "xx");
    try expectMatch("(a*)*", "", "b", "");
    try expectMatch("(a*)+", "", "b", "");
    try expectMatch("(a|b)*", "", "abba", "abba");
}

test "re2 search: alternation is leftmost-first" {
    try expectMatch("a|ab", "", "ab", "a");
    try expectMatch("ab|a", "", "ab", "ab");
    try expectMatch("(a|ab)(c|bcd)", "", "abcd", "abcd");
    try expectMatch("a+b|a+", "", "aaa", "aaa");
    try expectMatch("x*|y", "", "y", "");
    try expectMatch("(?:a|b)c", "", "bc", "bc");
}

test "re2 search: classes" {
    try expectMatch("[a-c]+", "", "xabcabcx", "abcabc");
    try expectMatch("[^a-c]+", "", "abcxyzabc", "xyz");
    try expectMatch("[[:alpha:]]+", "", "123abc456", "abc");
    try expectMatch("[[:^alpha:]]+", "", "abc123def", "123");
    try expectMatch("[\\d]+", "", "ab12cd", "12");
    try expectMatch("[\\D]+", "", "12ab34", "ab");
    try expectMatch("[]a]+", "", "x]a]x", "]a]");
    try expectMatch("[a-]+", "", "x-a-x", "-a-");
    try expectMatch("\\w+", "", "  foo_1 ", "foo_1");
    try expectMatch("\\s+", "", "a \t\nb", " \t\n");
    try expectMatch("\\S+", "", "  ab ", "ab");
    try expectMatch(".", "", "\n", null);
    try expectMatch(".", "s", "\n", "\n");
    try expectMatch(".+", "", "ab\ncd", "ab");
}

test "re2 search: escapes and flags" {
    try expectMatch("\\x41", "", "A", "A");
    try expectMatch("\\x{41}", "", "A", "A");
    try expectMatch("\\u{263A}", "", "\u{263A}", "\u{263A}");
    try expectMatch("a\\.b", "", "a.b", "a.b");
    try expectMatch("a\\.b", "", "axb", null);
    try expectMatch("\\t\\n", "", "\t\n", "\t\n");
    try expectMatch("ABC", "i", "xabcx", "abc");
    try expectMatch("[a-z]+", "i", "ABC", "ABC");
    try expectMatch("[^a]", "i", "A", null);
    try expectMatch("a b # comment\n c", "x", "abc", "abc");
    try expectMatch("a b", "x", "a b", null);
}

test "re2 search: groups" {
    const re = try compile("(?<key>\\w+)\\s*=\\s*(?<value>.*)", "");
    const caps = re.search("name = dakota", 0).?;
    try std.testing.expectEqual(@as(usize, 3), caps.len);
    try std.testing.expectEqualStrings("name", "name = dakota"[caps[1].?[0]..caps[1].?[1]]);
    try std.testing.expectEqualStrings("dakota", "name = dakota"[caps[2].?[0]..caps[2].?[1]]);
    try std.testing.expectEqualStrings("key", re.names[0].name);
    const opt = try compile("(a)|(b)", "");
    const oc = opt.search("b", 0).?;
    try std.testing.expect(oc[1] == null);
    try std.testing.expect(oc[2] != null);
}

test "re2 search: searching from an offset keeps context" {
    const re = try compile("\\bab", "");
    try std.testing.expect(re.search("xab ab", 1) != null);
    try std.testing.expectEqual(@as(usize, 4), re.search("xab ab", 1).?[0].?[0]);
    const anchored = try compile("^a", "");
    try std.testing.expect(anchored.search("aa", 1) == null);
}

test "unicode: u flag" {
    try expectMatch("^\\p{Lu}", "u", "\u{C4}", "\u{C4}"); // Ä
    try expectMatch("^\\p{Lu}", "u", "\u{E4}", null); // ä
    try expectMatch("\\p{Greek}+", "u", "abc\u{3B1}\u{3B2}def", "\u{3B1}\u{3B2}");
    try expectMatch("\\P{L}+", "u", "ab12cd", "12");
    try expectMatch("\\w+", "u", "na\u{EF}ve!", "na\u{EF}ve");
    try expectMatch("\\w+", "", "na\u{EF}ve!", "na");
    try expectMatch("\u{DF}", "iu", "SS", null); // simple folding only
    try expectMatch("\u{E4}", "iu", "\u{C4}", "\u{C4}");
    try expectMatch("\u{3C3}", "iu", "\u{3A3}", "\u{3A3}");
    try expectMatch(".", "", "\u{1F600}", "\u{1F600}");
    try expectMatch("\\d", "u", "\u{663}", "\u{663}"); // Arabic-Indic digit
    try expectMatch("\\d", "", "\u{663}", null);
}

test "rejects what would break linear time" {
    for ([_][]const u8{ "(a)\\1", "(?=a)", "(?!a)", "(?<=a)", "(?<!a)", "a*+", "\\k<x>" }) |pat| {
        try std.testing.expectError(error.Invalid, compile(pat, ""));
        try std.testing.expect(last_error.len > 0);
    }
    try std.testing.expectError(error.Invalid, compile("(", ""));
    try std.testing.expectError(error.Invalid, compile(")", ""));
    try std.testing.expectError(error.Invalid, compile("[a", ""));
    try std.testing.expectError(error.Invalid, compile("a{3,2}", ""));
    try std.testing.expectError(error.Invalid, compile("*a", ""));
    try std.testing.expectError(error.Invalid, compile("\\p{L}", ""));
    try std.testing.expectError(error.Invalid, compile("a", "q"));
}

test "pathological pattern runs in linear time" {
    const re = try compile("(a*)*b", "");
    const input = try std.testing.allocator.alloc(u8, 100_000);
    defer std.testing.allocator.free(input);
    @memset(input, 'a');
    try std.testing.expect(re.search(input, 0) == null);
    const re2 = try compile("(a|aa)+$", "");
    try std.testing.expect(re2.search(input, 0) != null);
}
