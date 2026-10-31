//! Local time from `/etc/localtime` (TZif) and POSIX TZ rules, plus a
//! `strftime` subset (SPEC 4.2). No libc, no locale.

const std = @import("std");
const mem = @import("mem.zig");
const sys = @import("sys.zig");

pub const Civil = struct {
    year: i64,
    month: u8, // 1..12
    day: u8,
    hour: u8,
    min: u8,
    sec: u8,
    wday: u8, // 0 = Sunday
    yday: u16, // 0-based
    offset: i32 = 0,
    abbr: []const u8 = "UTC",
};

fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn civilFromTimestamp(ts: i64, offset: i32, abbr: []const u8) Civil {
    const t = ts + offset;
    const days = @divFloor(t, 86400);
    const rem = @mod(t, 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    return .{
        .year = year,
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = @intCast(@divFloor(rem, 3600)),
        .min = @intCast(@divFloor(@mod(rem, 3600), 60)),
        .sec = @intCast(@mod(rem, 60)),
        .wday = @intCast(@mod(days + 4, 7)),
        .yday = @intCast(days - daysFromCivil(year, 1, 1)),
        .offset = offset,
        .abbr = abbr,
    };
}

// ------------------------------------------------------------ POSIX TZ rule

const RuleDate = struct {
    kind: enum { julian1, julian0, month },
    a: i64 = 0, // day or month
    w: i64 = 0,
    d: i64 = 0,
    time: i64 = 7200,
};

const Posix = struct {
    std_abbr: []const u8,
    std_off: i32, // seconds east of UTC
    dst_abbr: []const u8 = "",
    dst_off: i32 = 0,
    has_dst: bool = false,
    start: RuleDate = .{ .kind = .month, .a = 3, .w = 2, .d = 0 },
    end: RuleDate = .{ .kind = .month, .a = 11, .w = 1, .d = 0 },
};

const PosixParser = struct {
    s: []const u8,
    i: usize = 0,

    fn name(self: *PosixParser) ?[]const u8 {
        if (self.i < self.s.len and self.s[self.i] == '<') {
            const e = std.mem.indexOfScalarPos(u8, self.s, self.i, '>') orelse return null;
            const r = self.s[self.i + 1 .. e];
            self.i = e + 1;
            return r;
        }
        const st = self.i;
        while (self.i < self.s.len and std.ascii.isAlphabetic(self.s[self.i])) self.i += 1;
        if (self.i - st < 3) return null;
        return self.s[st..self.i];
    }

    fn hms(self: *PosixParser) ?i64 {
        var sign: i64 = 1;
        if (self.i < self.s.len and (self.s[self.i] == '+' or self.s[self.i] == '-')) {
            if (self.s[self.i] == '-') sign = -1;
            self.i += 1;
        }
        var parts: [3]i64 = .{ 0, 0, 0 };
        var n: usize = 0;
        while (n < 3) : (n += 1) {
            const st = self.i;
            while (self.i < self.s.len and std.ascii.isDigit(self.s[self.i])) self.i += 1;
            if (self.i == st) {
                if (n == 0) return null;
                break;
            }
            parts[n] = std.fmt.parseInt(i64, self.s[st..self.i], 10) catch return null;
            if (self.i < self.s.len and self.s[self.i] == ':' and n < 2) self.i += 1 else break;
        }
        return sign * (parts[0] * 3600 + parts[1] * 60 + parts[2]);
    }

    fn number(self: *PosixParser) ?i64 {
        const st = self.i;
        while (self.i < self.s.len and std.ascii.isDigit(self.s[self.i])) self.i += 1;
        if (self.i == st) return null;
        return std.fmt.parseInt(i64, self.s[st..self.i], 10) catch null;
    }

    fn rule(self: *PosixParser) ?RuleDate {
        var r: RuleDate = .{ .kind = .month };
        if (self.i >= self.s.len) return null;
        if (self.s[self.i] == 'M') {
            self.i += 1;
            r.a = self.number() orelse return null;
            if (self.i >= self.s.len or self.s[self.i] != '.') return null;
            self.i += 1;
            r.w = self.number() orelse return null;
            if (self.i >= self.s.len or self.s[self.i] != '.') return null;
            self.i += 1;
            r.d = self.number() orelse return null;
        } else if (self.s[self.i] == 'J') {
            self.i += 1;
            r.kind = .julian1;
            r.a = self.number() orelse return null;
        } else {
            r.kind = .julian0;
            r.a = self.number() orelse return null;
        }
        if (self.i < self.s.len and self.s[self.i] == '/') {
            self.i += 1;
            r.time = self.hms() orelse return null;
        }
        return r;
    }
};

fn parsePosix(s: []const u8) ?Posix {
    var p = PosixParser{ .s = s };
    const sname = p.name() orelse return null;
    const soff = p.hms() orelse return null;
    var out: Posix = .{ .std_abbr = sname, .std_off = @intCast(-soff) };
    if (p.i >= s.len) return out;
    const dname = p.name() orelse return out;
    out.dst_abbr = dname;
    out.has_dst = true;
    out.dst_off = out.std_off + 3600;
    if (p.i < s.len and s[p.i] != ',') {
        const doff = p.hms() orelse return null;
        out.dst_off = @intCast(-doff);
    }
    if (p.i < s.len and s[p.i] == ',') {
        p.i += 1;
        out.start = p.rule() orelse return null;
        if (p.i >= s.len or s[p.i] != ',') return null;
        p.i += 1;
        out.end = p.rule() orelse return null;
    }
    return out;
}

/// Seconds since the epoch (as if in UTC) of the rule's moment in `year`.
fn ruleMoment(r: RuleDate, year: i64) i64 {
    const day: i64 = switch (r.kind) {
        .julian1 => blk: {
            var d = daysFromCivil(year, 1, 1) + r.a - 1;
            if (isLeap(year) and r.a >= 60) d += 1;
            break :blk d;
        },
        .julian0 => daysFromCivil(year, 1, 1) + r.a,
        .month => blk: {
            const first = daysFromCivil(year, r.a, 1);
            const wday_first = @mod(first + 4, 7);
            var d = first + @mod(r.d - wday_first + 7, 7) + (r.w - 1) * 7;
            const mdays = daysInMonth(year, r.a);
            while (d - first >= mdays) d -= 7;
            break :blk d;
        },
    };
    return day * 86400 + r.time;
}

fn daysInMonth(year: i64, m: i64) i64 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeap(year)) 29 else 28,
    };
}

const Offset = struct { off: i32, abbr: []const u8 };

fn posixOffset(p: Posix, ts: i64) Offset {
    if (!p.has_dst) return .{ .off = p.std_off, .abbr = p.std_abbr };
    const year = civilFromTimestamp(ts, p.std_off, "").year;
    const start = ruleMoment(p.start, year) - p.std_off;
    const end = ruleMoment(p.end, year) - p.dst_off;
    const in_dst = if (start < end) (ts >= start and ts < end) else !(ts >= end and ts < start);
    return if (in_dst) .{ .off = p.dst_off, .abbr = p.dst_abbr } else .{ .off = p.std_off, .abbr = p.std_abbr };
}

// ------------------------------------------------------------------- TZif

const Zone = struct {
    times: []const i64 = &.{},
    idx: []const u8 = &.{},
    offs: []const i32 = &.{},
    isdst: []const bool = &.{},
    abbrs: []const []const u8 = &.{},
    footer: ?Posix = null,
};

fn be32(b: []const u8) i32 {
    return @bitCast(std.mem.readInt(u32, b[0..4], .big));
}

fn parseTzif(data: []const u8) ?Zone {
    if (data.len < 44 or !std.mem.eql(u8, data[0..4], "TZif")) return null;
    const version = data[4];
    var off: usize = 0;
    var tsize: usize = 4;
    var counts = readCounts(data, 0);
    if (version >= '2') {
        // Skip the 32-bit block.
        const skip = 44 + counts.timecnt * 4 + counts.timecnt + counts.typecnt * 6 + counts.charcnt + counts.leapcnt * 8 + counts.isstdcnt + counts.isutcnt;
        if (data.len < skip + 44) return null;
        off = skip;
        tsize = 8;
        counts = readCounts(data, off);
    }
    var p = off + 44;
    var z: Zone = .{};
    const times = mem.gpa.alloc(i64, counts.timecnt) catch return null;
    for (times, 0..) |*t, i| {
        if (p + tsize > data.len) return null;
        t.* = if (tsize == 8) @bitCast(std.mem.readInt(u64, data[p + i * 8 ..][0..8], .big)) else be32(data[p + i * 4 ..]);
    }
    p += counts.timecnt * tsize;
    if (p + counts.timecnt > data.len) return null;
    z.times = times;
    z.idx = data[p .. p + counts.timecnt];
    p += counts.timecnt;
    const offs = mem.gpa.alloc(i32, counts.typecnt) catch return null;
    const isdst = mem.gpa.alloc(bool, counts.typecnt) catch return null;
    const abbr_idx = mem.gpa.alloc(u8, counts.typecnt) catch return null;
    if (p + counts.typecnt * 6 > data.len) return null;
    for (0..counts.typecnt) |i| {
        offs[i] = be32(data[p + i * 6 ..]);
        isdst[i] = data[p + i * 6 + 4] != 0;
        abbr_idx[i] = data[p + i * 6 + 5];
    }
    p += counts.typecnt * 6;
    if (p + counts.charcnt > data.len) return null;
    const chars = data[p .. p + counts.charcnt];
    p += counts.charcnt + counts.leapcnt * (tsize + 4) + counts.isstdcnt + counts.isutcnt;
    const abbrs = mem.gpa.alloc([]const u8, counts.typecnt) catch return null;
    for (abbrs, 0..) |*a, i| {
        const st = abbr_idx[i];
        const e = std.mem.indexOfScalarPos(u8, chars, st, 0) orelse chars.len;
        a.* = chars[st..e];
    }
    z.offs = offs;
    z.isdst = isdst;
    z.abbrs = abbrs;
    if (version >= '2' and p < data.len and data[p] == '\n') {
        const rest = data[p + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, '\n')) |e| z.footer = parsePosix(rest[0..e]);
    }
    return z;
}

const Counts = struct { isutcnt: usize, isstdcnt: usize, leapcnt: usize, timecnt: usize, typecnt: usize, charcnt: usize };

fn readCounts(data: []const u8, at: usize) Counts {
    const h = data[at + 20 ..];
    return .{
        .isutcnt = @intCast(be32(h[0..])),
        .isstdcnt = @intCast(be32(h[4..])),
        .leapcnt = @intCast(be32(h[8..])),
        .timecnt = @intCast(be32(h[12..])),
        .typecnt = @intCast(be32(h[16..])),
        .charcnt = @intCast(be32(h[20..])),
    };
}

fn zoneOffset(z: Zone, ts: i64) Offset {
    if (z.times.len == 0 or ts < z.times[0]) {
        if (z.times.len == 0 and z.footer != null) return posixOffset(z.footer.?, ts);
        // Before the first transition: first standard-time type.
        for (z.offs, 0..) |o, i| if (!z.isdst[i]) return .{ .off = o, .abbr = z.abbrs[i] };
        if (z.offs.len > 0) return .{ .off = z.offs[0], .abbr = z.abbrs[0] };
        return .{ .off = 0, .abbr = "UTC" };
    }
    if (ts >= z.times[z.times.len - 1]) {
        if (z.footer) |f| return posixOffset(f, ts);
    }
    var lo: usize = 0;
    var hi: usize = z.times.len;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (z.times[mid] <= ts) lo = mid else hi = mid;
    }
    const t = z.idx[lo];
    return .{ .off = z.offs[t], .abbr = z.abbrs[t] };
}

// ------------------------------------------------------------- local zone

const Local = union(enum) { utc, zone: Zone, posix: Posix };
var local_cache: ?Local = null;

fn loadLocal(tz_env: ?[]const u8) Local {
    if (tz_env) |raw| {
        var tz = raw;
        if (tz.len > 0 and tz[0] == ':') tz = tz[1..];
        if (tz.len == 0) return .utc;
        const path = if (tz[0] == '/') tz else mem.print("/usr/share/zoneinfo/{s}", .{tz});
        if (sys.readFile(mem.gpa, path)) |data| {
            if (parseTzif(data)) |z| return .{ .zone = z };
        } else |_| {}
        if (parsePosix(tz)) |p| return .{ .posix = p };
        return .utc;
    }
    if (sys.readFile(mem.gpa, "/etc/localtime")) |data| {
        if (parseTzif(data)) |z| return .{ .zone = z };
    } else |_| {}
    return .utc;
}

/// Break a timestamp down in the local zone (`tz_env` is the value of TZ).
pub fn localCivil(ts: i64, tz_env: ?[]const u8) Civil {
    if (local_cache == null) local_cache = loadLocal(tz_env);
    const o: Offset = switch (local_cache.?) {
        .utc => .{ .off = 0, .abbr = "UTC" },
        .zone => |z| zoneOffset(z, ts),
        .posix => |p| posixOffset(p, ts),
    };
    return civilFromTimestamp(ts, o.off, o.abbr);
}

/// Forget the cached zone (after TZ changes).
pub fn resetZone() void {
    local_cache = null;
}

const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

fn isoWeek(c: Civil) struct { year: i64, week: i64 } {
    const wd: i64 = @mod(@as(i64, c.wday) + 6, 7); // Monday = 0
    var week = @divFloor(@as(i64, c.yday) - wd + 10, 7);
    var year = c.year;
    if (week < 1) {
        year -= 1;
        const dec31_yday: i64 = if (isLeap(year)) 365 else 364;
        const wd2 = @mod(wd - @as(i64, c.yday) - 1, 7);
        week = @divFloor(dec31_yday - wd2 + 10, 7);
    } else if (week == 53) {
        const ylen: i64 = if (isLeap(year)) 366 else 365;
        if (@as(i64, c.yday) - wd + 3 >= ylen) {
            week = 1;
            year += 1;
        }
    }
    return .{ .year = year, .week = week };
}

pub fn strftime(fmt: []const u8, c: Civil, ts: i64) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            out.append(mem.gpa, fmt[i]) catch {};
            continue;
        }
        i += 1;
        var conv = fmt[i];
        // Flags: '-' drops padding, '_' pads with spaces.
        var no_pad = false;
        if (conv == '-' and i + 1 < fmt.len) {
            no_pad = true;
            i += 1;
            conv = fmt[i];
        }
        const h12: u8 = if (c.hour % 12 == 0) 12 else c.hour % 12;
        switch (conv) {
            'Y' => out.print(mem.gpa, "{d}", .{c.year}) catch {},
            'y' => out.print(mem.gpa, "{d:0>2}", .{@mod(c.year, 100)}) catch {},
            'C' => out.print(mem.gpa, "{d:0>2}", .{@divFloor(c.year, 100)}) catch {},
            'm' => if (no_pad) out.print(mem.gpa, "{d}", .{c.month}) catch {} else out.print(mem.gpa, "{d:0>2}", .{c.month}) catch {},
            'd' => if (no_pad) out.print(mem.gpa, "{d}", .{c.day}) catch {} else out.print(mem.gpa, "{d:0>2}", .{c.day}) catch {},
            'e' => out.print(mem.gpa, "{d: >2}", .{c.day}) catch {},
            'H' => if (no_pad) out.print(mem.gpa, "{d}", .{c.hour}) catch {} else out.print(mem.gpa, "{d:0>2}", .{c.hour}) catch {},
            'I' => if (no_pad) out.print(mem.gpa, "{d}", .{h12}) catch {} else out.print(mem.gpa, "{d:0>2}", .{h12}) catch {},
            'k' => out.print(mem.gpa, "{d: >2}", .{c.hour}) catch {},
            'l' => out.print(mem.gpa, "{d: >2}", .{h12}) catch {},
            'M' => out.print(mem.gpa, "{d:0>2}", .{c.min}) catch {},
            'S' => out.print(mem.gpa, "{d:0>2}", .{c.sec}) catch {},
            'p' => out.appendSlice(mem.gpa, if (c.hour < 12) "AM" else "PM") catch {},
            'P' => out.appendSlice(mem.gpa, if (c.hour < 12) "am" else "pm") catch {},
            'A' => out.appendSlice(mem.gpa, weekdays[c.wday]) catch {},
            'a' => out.appendSlice(mem.gpa, weekdays[c.wday][0..3]) catch {},
            'B' => out.appendSlice(mem.gpa, months[c.month - 1]) catch {},
            'b', 'h' => out.appendSlice(mem.gpa, months[c.month - 1][0..3]) catch {},
            'j' => out.print(mem.gpa, "{d:0>3}", .{c.yday + 1}) catch {},
            'u' => out.print(mem.gpa, "{d}", .{if (c.wday == 0) 7 else c.wday}) catch {},
            'w' => out.print(mem.gpa, "{d}", .{c.wday}) catch {},
            'U' => out.print(mem.gpa, "{d:0>2}", .{@divFloor(@as(i64, c.yday) + 7 - c.wday, 7)}) catch {},
            'W' => out.print(mem.gpa, "{d:0>2}", .{@divFloor(@as(i64, c.yday) + 7 - @mod(@as(i64, c.wday) + 6, 7), 7)}) catch {},
            'V' => out.print(mem.gpa, "{d:0>2}", .{isoWeek(c).week}) catch {},
            'G' => out.print(mem.gpa, "{d}", .{isoWeek(c).year}) catch {},
            'Z' => out.appendSlice(mem.gpa, c.abbr) catch {},
            'z' => {
                const o = c.offset;
                const a: u32 = @abs(o);
                out.print(mem.gpa, "{c}{d:0>2}{d:0>2}", .{ @as(u8, if (o < 0) '-' else '+'), a / 3600, (a % 3600) / 60 }) catch {};
            },
            's' => out.print(mem.gpa, "{d}", .{ts}) catch {},
            'F' => out.print(mem.gpa, "{d}-{d:0>2}-{d:0>2}", .{ c.year, c.month, c.day }) catch {},
            'T' => out.print(mem.gpa, "{d:0>2}:{d:0>2}:{d:0>2}", .{ c.hour, c.min, c.sec }) catch {},
            'R' => out.print(mem.gpa, "{d:0>2}:{d:0>2}", .{ c.hour, c.min }) catch {},
            'D' => out.print(mem.gpa, "{d:0>2}/{d:0>2}/{d:0>2}", .{ c.month, c.day, @mod(c.year, 100) }) catch {},
            'c' => out.print(mem.gpa, "{s} {s} {d: >2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{ weekdays[c.wday][0..3], months[c.month - 1][0..3], c.day, c.hour, c.min, c.sec, c.year }) catch {},
            'x' => out.print(mem.gpa, "{d:0>2}/{d:0>2}/{d:0>2}", .{ c.month, c.day, @mod(c.year, 100) }) catch {},
            'X' => out.print(mem.gpa, "{d:0>2}:{d:0>2}:{d:0>2}", .{ c.hour, c.min, c.sec }) catch {},
            'n' => out.append(mem.gpa, '\n') catch {},
            't' => out.append(mem.gpa, '\t') catch {},
            '%' => out.append(mem.gpa, '%') catch {},
            else => {
                out.append(mem.gpa, '%') catch {};
                out.append(mem.gpa, conv) catch {};
            },
        }
    }
    return out.items;
}

test "civil conversion and strftime" {
    const c = civilFromTimestamp(1_700_000_000, 0, "UTC"); // 2023-11-14 22:13:20 UTC, a Tuesday
    try std.testing.expectEqual(@as(i64, 2023), c.year);
    try std.testing.expectEqual(@as(u8, 11), c.month);
    try std.testing.expectEqual(@as(u8, 2), c.wday);
    try std.testing.expectEqualStrings("2023-11-14 22:13:20 Tuesday", strftime("%Y-%m-%d %H:%M:%S %A", c, 1_700_000_000));
}

test "POSIX TZ rules switch to daylight time" {
    const p = parsePosix("EST5EDT,M3.2.0,M11.1.0").?;
    try std.testing.expectEqual(@as(i32, -18000), posixOffset(p, 1_705_000_000).off); // January
    try std.testing.expectEqual(@as(i32, -14400), posixOffset(p, 1_720_000_000).off); // July
    try std.testing.expectEqualStrings("EDT", posixOffset(p, 1_720_000_000).abbr);
}
