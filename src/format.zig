//! `printf` / `sprintf` with C format strings (SPEC 7.3). `%n` is rejected, and
//! a conversion that does not match its argument's type is an error.

const std = @import("std");
const ast = @import("ast.zig");
const mem = @import("mem.zig");
const value = @import("value.zig");
const Interp = @import("interp.zig").Interp;

const Value = value.Value;
const Error = value.Error;

const Spec = struct {
    minus: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    zero: bool = false,
    width: usize = 0,
    prec: ?usize = null,
};

fn pad(out: *std.ArrayList(u8), spec: Spec, prefix: []const u8, body: []const u8, numeric: bool) void {
    const total = prefix.len + body.len;
    const fill = if (spec.width > total) spec.width - total else 0;
    if (spec.minus) {
        out.appendSlice(mem.gpa, prefix) catch {};
        out.appendSlice(mem.gpa, body) catch {};
        out.appendNTimes(mem.gpa, ' ', fill) catch {};
    } else if (spec.zero and numeric) {
        out.appendSlice(mem.gpa, prefix) catch {};
        out.appendNTimes(mem.gpa, '0', fill) catch {};
        out.appendSlice(mem.gpa, body) catch {};
    } else {
        out.appendNTimes(mem.gpa, ' ', fill) catch {};
        out.appendSlice(mem.gpa, prefix) catch {};
        out.appendSlice(mem.gpa, body) catch {};
    }
}

fn signPrefix(spec: Spec, negative: bool) []const u8 {
    if (negative) return "-";
    if (spec.plus) return "+";
    if (spec.space) return " ";
    return "";
}

fn fmtInt(out: *std.ArrayList(u8), spec: Spec, v: i64, conv: u8) void {
    var digits_buf: [80]u8 = undefined;
    var prefix: []const u8 = "";
    var digits: []const u8 = undefined;
    switch (conv) {
        'd', 'i' => {
            const neg = v < 0;
            const mag: u64 = if (neg) @as(u64, @intCast(-(v + 1))) + 1 else @intCast(v);
            digits = std.fmt.bufPrint(&digits_buf, "{d}", .{mag}) catch "";
            prefix = signPrefix(spec, neg);
        },
        else => {
            const u: u64 = @bitCast(v);
            digits = switch (conv) {
                'u' => std.fmt.bufPrint(&digits_buf, "{d}", .{u}) catch "",
                'o' => std.fmt.bufPrint(&digits_buf, "{o}", .{u}) catch "",
                'x' => std.fmt.bufPrint(&digits_buf, "{x}", .{u}) catch "",
                else => std.fmt.bufPrint(&digits_buf, "{X}", .{u}) catch "",
            };
            if (spec.alt and u != 0) {
                if (conv == 'x') prefix = "0x";
                if (conv == 'X') prefix = "0X";
            }
        },
    }
    var body: []const u8 = digits;
    if (spec.prec) |p| {
        if (p == 0 and v == 0) body = "";
        if (body.len < p) {
            const z = mem.gpa.alloc(u8, p) catch return;
            @memset(z[0 .. p - body.len], '0');
            @memcpy(z[p - body.len ..], body);
            body = z;
        }
    }
    if (conv == 'o' and spec.alt and (body.len == 0 or body[0] != '0')) body = mem.print("0{s}", .{body});
    var s = spec;
    if (spec.prec != null) s.zero = false;
    pad(out, s, prefix, body, true);
}

/// Rewrite Zig's `1.5e2` exponent into C's `1.5e+02`.
fn fixExponent(text: []const u8, upper: bool) []const u8 {
    const epos = std.mem.indexOfScalar(u8, text, 'e') orelse return text;
    var exp = text[epos + 1 ..];
    var sign: u8 = '+';
    if (exp.len > 0 and (exp[0] == '-' or exp[0] == '+')) {
        sign = exp[0];
        exp = exp[1..];
    }
    const e_char: u8 = if (upper) 'E' else 'e';
    if (exp.len < 2) return mem.print("{s}{c}{c}0{s}", .{ text[0..epos], e_char, sign, exp });
    return mem.print("{s}{c}{c}{s}", .{ text[0..epos], e_char, sign, exp });
}

fn fixedText(f: f64, prec: usize) []const u8 {
    return std.fmt.allocPrint(mem.gpa, "{d:.[1]}", .{ f, prec }) catch "";
}

fn expText(f: f64, prec: usize, upper: bool) []const u8 {
    const raw = std.fmt.allocPrint(mem.gpa, "{e:.[1]}", .{ f, prec }) catch "";
    return fixExponent(raw, upper);
}

fn stripZeros(text: []const u8) []const u8 {
    // Remove trailing zeros of the fraction (before any exponent).
    const epos = std.mem.indexOfAny(u8, text, "eE") orelse text.len;
    var mant = text[0..epos];
    if (std.mem.indexOfScalar(u8, mant, '.') != null) {
        while (mant.len > 0 and mant[mant.len - 1] == '0') mant = mant[0 .. mant.len - 1];
        if (mant.len > 0 and mant[mant.len - 1] == '.') mant = mant[0 .. mant.len - 1];
    }
    return mem.print("{s}{s}", .{ mant, text[epos..] });
}

fn hexFloat(f: f64, upper: bool) []const u8 {
    if (f == 0) return if (upper) "0X0P+0" else "0x0p+0";
    const bits: u64 = @bitCast(f);
    const exp_bits: i32 = @intCast((bits >> 52) & 0x7ff);
    var mant = bits & ((1 << 52) - 1);
    var lead: u8 = '1';
    var e: i32 = exp_bits - 1023;
    if (exp_bits == 0) {
        lead = '0';
        e = -1022;
    }
    var hex_buf: [13]u8 = undefined;
    _ = std.fmt.bufPrint(&hex_buf, "{x:0>13}", .{mant}) catch {};
    mant = 0;
    var hex: []const u8 = &hex_buf;
    while (hex.len > 0 and hex[hex.len - 1] == '0') hex = hex[0 .. hex.len - 1];
    const s = if (hex.len > 0)
        mem.print("0x{c}.{s}p{s}{d}", .{ lead, hex, if (e < 0) "-" else "+", @abs(e) })
    else
        mem.print("0x{c}p{s}{d}", .{ lead, if (e < 0) "-" else "+", @abs(e) });
    return if (upper) std.ascii.allocUpperString(mem.gpa, s) catch s else s;
}

fn fmtFloat(out: *std.ArrayList(u8), spec: Spec, f: f64, conv: u8) void {
    const upper = std.ascii.isUpper(conv);
    const neg = std.math.signbit(f) and !std.math.isNan(f);
    const a = @abs(f);
    var body: []const u8 = undefined;
    var numeric = true;
    if (std.math.isNan(f) or std.math.isInf(f)) {
        body = if (std.math.isNan(f)) (if (upper) "NAN" else "nan") else (if (upper) "INF" else "inf");
        numeric = false;
    } else switch (std.ascii.toLower(conv)) {
        'f' => {
            body = fixedText(a, spec.prec orelse 6);
            if (spec.alt and spec.prec == 0) body = mem.print("{s}.", .{body});
        },
        'e' => body = expText(a, spec.prec orelse 6, upper),
        'g' => {
            var p = spec.prec orelse 6;
            if (p == 0) p = 1;
            const probe = expText(a, p - 1, false);
            const epos = std.mem.indexOfScalar(u8, probe, 'e').?;
            const x = std.fmt.parseInt(i32, probe[epos + 1 ..], 10) catch 0;
            if (a != 0 and (x < -4 or x >= @as(i32, @intCast(p)))) {
                body = expText(a, p - 1, upper);
            } else {
                const fp: i32 = @as(i32, @intCast(p)) - 1 - (if (a == 0) 0 else x);
                body = fixedText(a, @intCast(@max(fp, 0)));
            }
            if (!spec.alt) body = stripZeros(body);
        },
        else => body = hexFloat(a, upper), // 'a'
    }
    var s = spec;
    if (!numeric) s.zero = false;
    pad(out, s, signPrefix(spec, neg), body, numeric);
}

pub fn sprintf(ip: *Interp, fmt: []const u8, args: []const Value, span: ast.Span) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var argi: usize = 0;
    var i: usize = 0;

    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            out.append(mem.gpa, c) catch @panic("out of memory");
            i += 1;
            continue;
        }
        i += 1;
        if (i >= fmt.len) return ip.raise(span, "printf: format ends with a lone '%'", .{});
        var spec: Spec = .{};
        // Flags.
        while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '-' => spec.minus = true,
                '+' => spec.plus = true,
                ' ' => spec.space = true,
                '#' => spec.alt = true,
                '0' => spec.zero = true,
                else => break,
            }
        }
        // Width.
        if (i < fmt.len and fmt[i] == '*') {
            i += 1;
            if (argi >= args.len or args[argi] != .int) return ip.raise(span, "printf: '*' needs an int argument", .{});
            const w = args[argi].int;
            argi += 1;
            if (w < 0) {
                spec.minus = true;
                spec.width = @intCast(-w);
            } else spec.width = @intCast(w);
        } else {
            while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) spec.width = spec.width * 10 + (fmt[i] - '0');
        }
        // Precision.
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            spec.prec = 0;
            if (i < fmt.len and fmt[i] == '*') {
                i += 1;
                if (argi >= args.len or args[argi] != .int) return ip.raise(span, "printf: '*' needs an int argument", .{});
                const p = args[argi].int;
                argi += 1;
                spec.prec = if (p < 0) null else @intCast(p);
            } else {
                while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) spec.prec = spec.prec.? * 10 + (fmt[i] - '0');
            }
        }
        // Length modifiers are accepted and ignored: every int is 64-bit.
        while (i < fmt.len and std.mem.indexOfScalar(u8, "hlLqjzt", fmt[i]) != null) i += 1;
        if (i >= fmt.len) return ip.raise(span, "printf: incomplete conversion in format", .{});
        const conv = fmt[i];
        i += 1;

        if (conv == '%') {
            out.append(mem.gpa, '%') catch @panic("out of memory");
            continue;
        }
        if (conv == 'n') return ip.raise(span, "printf: %n is not supported", .{});
        if (argi >= args.len) return ip.raise(span, "printf: not enough arguments for '%{c}'", .{conv});
        const arg = args[argi];
        argi += 1;

        switch (conv) {
            'd', 'i', 'u', 'o', 'x', 'X' => {
                if (arg != .int) return ip.raise(span, "printf: '%{c}' needs an int, got {s}", .{ conv, arg.typeName() });
                fmtInt(&out, spec, arg.int, conv);
            },
            'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A' => {
                const f: f64 = switch (arg) {
                    .float => |x| x,
                    .int => |x| @floatFromInt(x),
                    else => return ip.raise(span, "printf: '%{c}' needs a number, got {s}", .{ conv, arg.typeName() }),
                };
                fmtFloat(&out, spec, f, conv);
            },
            'c' => {
                var buf: [4]u8 = undefined;
                const text: []const u8 = switch (arg) {
                    .int => |cp| blk: {
                        if (cp < 0 or cp > 0x10ffff) return ip.raise(span, "printf: invalid character code {d}", .{cp});
                        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return ip.raise(span, "printf: invalid character code {d}", .{cp});
                        break :blk buf[0..n];
                    },
                    .str => |s| blk: {
                        const n = std.unicode.utf8ByteSequenceLength(if (s.len > 0) s[0] else 0) catch 0;
                        if (s.len == 0 or n != s.len) return ip.raise(span, "printf: '%c' needs a single character", .{});
                        break :blk s;
                    },
                    else => return ip.raise(span, "printf: '%c' needs an int or a character, got {s}", .{arg.typeName()}),
                };
                pad(&out, spec, "", text, false);
            },
            's' => {
                var text: []const u8 = value.toDisplayString(arg);
                if (spec.prec) |p| {
                    if (text.len > p) text = text[0..p];
                }
                pad(&out, spec, "", text, false);
            },
            else => return ip.raise(span, "printf: unknown conversion '%{c}'", .{conv}),
        }
    }
    return out.items;
}
