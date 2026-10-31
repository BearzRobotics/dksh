//! JSON for `jsonParse` / `jsonStringify`. Objects become maps, so key order
//! is preserved; integers that fit become `int`, everything else `float`.

const std = @import("std");
const mem = @import("mem.zig");
const value = @import("value.zig");
const Value = value.Value;

pub const Failure = struct { message: []const u8, offset: usize };

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    fail: ?Failure = null,
    depth: u32 = 0,

    fn bad(p: *Parser, msg: []const u8) ?Value {
        if (p.fail == null) p.fail = .{ .message = msg, .offset = p.i };
        return null;
    }

    fn ws(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t' or p.s[p.i] == '\n' or p.s[p.i] == '\r')) p.i += 1;
    }

    fn lit(p: *Parser, word: []const u8, v: Value) ?Value {
        if (std.mem.startsWith(u8, p.s[p.i..], word)) {
            p.i += word.len;
            return v;
        }
        return p.bad("invalid literal");
    }

    fn hex4(p: *Parser) ?u21 {
        if (p.i + 4 > p.s.len) return null;
        const v = std.fmt.parseInt(u21, p.s[p.i .. p.i + 4], 16) catch return null;
        p.i += 4;
        return v;
    }

    fn string(p: *Parser) ?[]const u8 {
        p.i += 1; // opening quote
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.i >= p.s.len) {
                _ = p.bad("unterminated string");
                return null;
            }
            const c = p.s[p.i];
            p.i += 1;
            if (c == '"') return out.items;
            if (c < 0x20) {
                p.i -= 1;
                _ = p.bad("control character in string");
                return null;
            }
            if (c != '\\') {
                out.append(mem.gpa, c) catch @panic("out of memory");
                continue;
            }
            if (p.i >= p.s.len) {
                _ = p.bad("unterminated escape");
                return null;
            }
            const e = p.s[p.i];
            p.i += 1;
            switch (e) {
                '"', '\\', '/' => out.append(mem.gpa, e) catch @panic("out of memory"),
                'b' => out.append(mem.gpa, 8) catch @panic("out of memory"),
                'f' => out.append(mem.gpa, 12) catch @panic("out of memory"),
                'n' => out.append(mem.gpa, '\n') catch @panic("out of memory"),
                'r' => out.append(mem.gpa, '\r') catch @panic("out of memory"),
                't' => out.append(mem.gpa, '\t') catch @panic("out of memory"),
                'u' => {
                    var cp = p.hex4() orelse {
                        _ = p.bad("invalid \\u escape");
                        return null;
                    };
                    if (cp >= 0xD800 and cp < 0xDC00) {
                        // High surrogate: needs a following low surrogate.
                        if (std.mem.startsWith(u8, p.s[p.i..], "\\u")) {
                            p.i += 2;
                            const lo = p.hex4() orelse {
                                _ = p.bad("invalid \\u escape");
                                return null;
                            };
                            if (lo < 0xDC00 or lo > 0xDFFF) {
                                _ = p.bad("invalid surrogate pair");
                                return null;
                            }
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        } else {
                            _ = p.bad("unpaired surrogate");
                            return null;
                        }
                    } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                        _ = p.bad("unpaired surrogate");
                        return null;
                    }
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch {
                        _ = p.bad("invalid code point");
                        return null;
                    };
                    out.appendSlice(mem.gpa, buf[0..n]) catch @panic("out of memory");
                },
                else => {
                    p.i -= 1;
                    _ = p.bad("invalid escape");
                    return null;
                },
            }
        }
    }

    fn number(p: *Parser) ?Value {
        const start = p.i;
        if (p.s[p.i] == '-') p.i += 1;
        const digits_start = p.i;
        while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        if (p.i == digits_start) return p.bad("invalid number");
        if (p.s[digits_start] == '0' and p.i - digits_start > 1) return p.bad("leading zero in number");
        var is_float = false;
        if (p.i < p.s.len and p.s[p.i] == '.') {
            is_float = true;
            p.i += 1;
            const f = p.i;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
            if (p.i == f) return p.bad("invalid number");
        }
        if (p.i < p.s.len and (p.s[p.i] == 'e' or p.s[p.i] == 'E')) {
            is_float = true;
            p.i += 1;
            if (p.i < p.s.len and (p.s[p.i] == '+' or p.s[p.i] == '-')) p.i += 1;
            const f = p.i;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
            if (p.i == f) return p.bad("invalid number");
        }
        const text = p.s[start..p.i];
        if (!is_float) {
            if (std.fmt.parseInt(i64, text, 10)) |v| return .{ .int = v } else |_| {}
        }
        const f = std.fmt.parseFloat(f64, text) catch return p.bad("invalid number");
        return .{ .float = f };
    }

    fn val(p: *Parser) ?Value {
        p.ws();
        if (p.i >= p.s.len) return p.bad("unexpected end of input");
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > 200) return p.bad("nested too deeply");
        switch (p.s[p.i]) {
            '{' => {
                p.i += 1;
                const m = Value.newMap();
                p.ws();
                if (p.i < p.s.len and p.s[p.i] == '}') {
                    p.i += 1;
                    return .{ .map = m };
                }
                while (true) {
                    p.ws();
                    if (p.i >= p.s.len or p.s[p.i] != '"') return p.bad("expected a string key");
                    const k = p.string() orelse return null;
                    p.ws();
                    if (p.i >= p.s.len or p.s[p.i] != ':') return p.bad("expected ':'");
                    p.i += 1;
                    const v = p.val() orelse return null;
                    m.put(k, v);
                    p.ws();
                    if (p.i < p.s.len and p.s[p.i] == ',') {
                        p.i += 1;
                        continue;
                    }
                    if (p.i < p.s.len and p.s[p.i] == '}') {
                        p.i += 1;
                        return .{ .map = m };
                    }
                    return p.bad("expected ',' or '}'");
                }
            },
            '[' => {
                p.i += 1;
                const a = Value.newArray();
                p.ws();
                if (p.i < p.s.len and p.s[p.i] == ']') {
                    p.i += 1;
                    return .{ .array = a };
                }
                while (true) {
                    const v = p.val() orelse return null;
                    a.items.append(mem.gpa, v) catch @panic("out of memory");
                    p.ws();
                    if (p.i < p.s.len and p.s[p.i] == ',') {
                        p.i += 1;
                        continue;
                    }
                    if (p.i < p.s.len and p.s[p.i] == ']') {
                        p.i += 1;
                        return .{ .array = a };
                    }
                    return p.bad("expected ',' or ']'");
                }
            },
            '"' => {
                const s = p.string() orelse return null;
                return .{ .str = s };
            },
            't' => return p.lit("true", .{ .bool_ = true }),
            'f' => return p.lit("false", .{ .bool_ = false }),
            'n' => return p.lit("null", .null_),
            '-', '0'...'9' => return p.number(),
            else => return p.bad("unexpected character"),
        }
    }
};

/// Parse `text`; on failure returns null and fills `failure`.
pub fn parse(text: []const u8, failure: *Failure) ?Value {
    var p: Parser = .{ .s = text };
    const v = p.val();
    if (v != null) {
        p.ws();
        if (p.i < p.s.len) {
            failure.* = .{ .message = "unexpected data after the value", .offset = p.i };
            return null;
        }
        return v;
    }
    failure.* = p.fail orelse .{ .message = "invalid JSON", .offset = p.i };
    return null;
}

fn quote(out: *std.ArrayList(u8), s: []const u8) void {
    out.append(mem.gpa, '"') catch {};
    for (s) |c| switch (c) {
        '"' => out.appendSlice(mem.gpa, "\\\"") catch {},
        '\\' => out.appendSlice(mem.gpa, "\\\\") catch {},
        '\n' => out.appendSlice(mem.gpa, "\\n") catch {},
        '\r' => out.appendSlice(mem.gpa, "\\r") catch {},
        '\t' => out.appendSlice(mem.gpa, "\\t") catch {},
        8 => out.appendSlice(mem.gpa, "\\b") catch {},
        12 => out.appendSlice(mem.gpa, "\\f") catch {},
        0...7, 11, 14...31 => out.print(mem.gpa, "\\u{x:0>4}", .{c}) catch {},
        else => out.append(mem.gpa, c) catch {},
    };
    out.append(mem.gpa, '"') catch {};
}

fn newline(out: *std.ArrayList(u8), indent: usize, level: usize) void {
    if (indent == 0) return;
    out.append(mem.gpa, '\n') catch {};
    out.appendNTimes(mem.gpa, ' ', indent * level) catch {};
}

/// Append `v` as JSON. Returns the type name of the first value that has no
/// JSON form (functions, objects, ...), or null on success.
pub fn stringify(out: *std.ArrayList(u8), v: Value, indent: usize, level: usize) ?[]const u8 {
    switch (v) {
        .null_ => out.appendSlice(mem.gpa, "null") catch {},
        .bool_ => |b| out.appendSlice(mem.gpa, if (b) "true" else "false") catch {},
        .int => |i| out.print(mem.gpa, "{d}", .{i}) catch {},
        .float => |f| {
            if (std.math.isNan(f) or std.math.isInf(f)) return "nan or inf";
            value.formatFloat(out, f);
        },
        .str => |s| quote(out, s),
        .array => |a| {
            if (a.items.items.len == 0) {
                out.appendSlice(mem.gpa, "[]") catch {};
                return null;
            }
            out.append(mem.gpa, '[') catch {};
            for (a.items.items, 0..) |item, i| {
                if (i > 0) out.append(mem.gpa, ',') catch {};
                newline(out, indent, level + 1);
                if (stringify(out, item, indent, level + 1)) |bad| return bad;
            }
            newline(out, indent, level);
            out.append(mem.gpa, ']') catch {};
        },
        .map => |m| {
            if (m.m.count() == 0) {
                out.appendSlice(mem.gpa, "{}") catch {};
                return null;
            }
            out.append(mem.gpa, '{') catch {};
            var i: usize = 0;
            var it = m.m.iterator();
            while (it.next()) |e| : (i += 1) {
                if (i > 0) out.append(mem.gpa, ',') catch {};
                newline(out, indent, level + 1);
                quote(out, e.key_ptr.*);
                out.appendSlice(mem.gpa, if (indent == 0) ":" else ": ") catch {};
                if (stringify(out, e.value_ptr.*, indent, level + 1)) |bad| return bad;
            }
            newline(out, indent, level);
            out.append(mem.gpa, '}') catch {};
        },
        else => return v.typeName(),
    }
    return null;
}
