//! Prompt strings: bash-style `PS1`/`PS2` escapes plus dksh interpolation.
//!
//! A template goes through two steps:
//!   1. backslash escapes (`\u`, `\w`, `\$`, `\[`...`\]`, ...), as in bash;
//!   2. dksh string interpolation: `${expr}`, `$name` and `$(command)`.
//! If step 2 fails (an undefined name, say), the error is shown once and the
//! text after step 1 is used as it is, so a typo never leaves you without a prompt.

const std = @import("std");
const mem = @import("mem.zig");
const sys = @import("sys.zig");
const time = @import("time.zig");
const parser = @import("parser.zig");
const editor = @import("editor.zig");
const jobs = @import("jobs.zig");
const ast = @import("ast.zig");
const Interp = @import("interp.zig").Interp;

pub const version = "0.0.1";

// Markers that survive interpolation. 1 and 2 are the editor's "zero width"
// brackets; 3 stands for `\$` until the very end so it is not interpolated.
const non_printing_start: u8 = 1;
const non_printing_end: u8 = 2;
const dollar_marker: u8 = 3;

fn envStr(ip: *Interp, name: []const u8) ?[]const u8 {
    const v = ip.env_map.get(name) orelse return null;
    return if (v == .str and v.str.len > 0) v.str else null;
}

fn timeText(ip: *Interp, fmt: []const u8) []const u8 {
    const ts = sys.unixTime();
    return time.strftime(fmt, time.localCivil(ts, envStr(ip, "TZ")), ts);
}

/// `\w` with the home directory shown as `~`, trimmed by `PROMPT_DIRTRIM`.
fn workingDir(ip: *Interp) []const u8 {
    const cwd = sys.getcwd(mem.gpa) catch return "?";
    var shown: []const u8 = cwd;
    var tilde = false;
    if (envStr(ip, "HOME")) |h| {
        if (h.len > 1 and std.mem.startsWith(u8, cwd, h) and (cwd.len == h.len or cwd[h.len] == '/')) {
            shown = cwd[h.len..];
            tilde = true;
        }
    }
    const keep: usize = blk: {
        const s = envStr(ip, "PROMPT_DIRTRIM") orelse break :blk 0;
        break :blk std.fmt.parseInt(usize, s, 10) catch 0;
    };
    if (keep > 0) {
        var parts: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, shown, '/');
        while (it.next()) |p| parts.append(mem.gpa, p) catch {};
        if (parts.items.len > keep) {
            const tail = parts.items[parts.items.len - keep ..];
            const joined = std.mem.join(mem.gpa, "/", tail) catch return shown;
            return mem.print("{s}.../{s}", .{ if (tilde) "~/" else "", joined });
        }
    }
    if (tilde) return mem.print("~{s}", .{shown});
    return shown;
}

fn ttyName() []const u8 {
    var buf: [128]u8 = undefined;
    const n = std.os.linux.readlink("/proc/self/fd/0", &buf, buf.len);
    if (std.os.linux.errno(n) != .SUCCESS) return "tty";
    return mem.dupe(std.fs.path.basename(buf[0..n]));
}

fn hostShort(full: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, full, '.')) |i| full[0..i] else full;
}

/// Step 1: bash backslash escapes.
fn expandEscapes(ip: *Interp, t: []const u8) []const u8 {
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] != '\\' or i + 1 >= t.len) {
            o.append(mem.gpa, t[i]) catch {};
            continue;
        }
        i += 1;
        const c = t[i];
        switch (c) {
            'a' => o.append(mem.gpa, 7) catch {},
            'e' => o.append(mem.gpa, 27) catch {},
            'n' => o.append(mem.gpa, '\n') catch {},
            'r' => o.append(mem.gpa, '\r') catch {},
            '\\' => o.append(mem.gpa, '\\') catch {},
            '[' => o.append(mem.gpa, non_printing_start) catch {},
            ']' => o.append(mem.gpa, non_printing_end) catch {},
            '$' => o.append(mem.gpa, dollar_marker) catch {},
            'u' => {
                const user = envStr(ip, "USER") orelse sys.userNameOf(sys.getuid()) orelse "user";
                o.appendSlice(mem.gpa, user) catch {};
            },
            'h' => o.appendSlice(mem.gpa, hostShort(sys.hostName(mem.gpa) catch "host")) catch {},
            'H' => o.appendSlice(mem.gpa, sys.hostName(mem.gpa) catch "host") catch {},
            'w' => o.appendSlice(mem.gpa, workingDir(ip)) catch {},
            'W' => {
                const w = workingDir(ip);
                if (std.mem.eql(u8, w, "~") or std.mem.eql(u8, w, "/")) {
                    o.appendSlice(mem.gpa, w) catch {};
                } else o.appendSlice(mem.gpa, std.fs.path.basename(w)) catch {};
            },
            's' => o.appendSlice(mem.gpa, "dksh") catch {},
            'v' => o.appendSlice(mem.gpa, version[0 .. std.mem.lastIndexOfScalar(u8, version, '.') orelse version.len]) catch {},
            'V' => o.appendSlice(mem.gpa, version) catch {},
            'j' => o.print(mem.gpa, "{d}", .{jobs.count()}) catch {},
            'l' => o.appendSlice(mem.gpa, ttyName()) catch {},
            '!' => o.print(mem.gpa, "{d}", .{editor.historyCount() + 1}) catch {},
            '#' => o.print(mem.gpa, "{d}", .{ip.cmd_number + 1}) catch {},
            '?' => o.print(mem.gpa, "{d}", .{ip.last_status}) catch {}, // dksh extension
            'd' => o.appendSlice(mem.gpa, timeText(ip, "%a %b %d")) catch {},
            't' => o.appendSlice(mem.gpa, timeText(ip, "%H:%M:%S")) catch {},
            'T' => o.appendSlice(mem.gpa, timeText(ip, "%I:%M:%S")) catch {},
            '@' => o.appendSlice(mem.gpa, timeText(ip, "%I:%M %p")) catch {},
            'A' => o.appendSlice(mem.gpa, timeText(ip, "%H:%M")) catch {},
            'D' => {
                // \D{strftime format}
                if (i + 1 < t.len and t[i + 1] == '{') {
                    if (std.mem.indexOfScalarPos(u8, t, i + 2, '}')) |end| {
                        const fmt = t[i + 2 .. end];
                        o.appendSlice(mem.gpa, timeText(ip, if (fmt.len == 0) "%H:%M:%S" else fmt)) catch {};
                        i = end;
                        continue;
                    }
                }
                o.appendSlice(mem.gpa, "\\D") catch {};
            },
            '0'...'7' => {
                // \nnn: up to three octal digits.
                var v: u16 = 0;
                var n: usize = 0;
                while (n < 3 and i < t.len and t[i] >= '0' and t[i] <= '7') : (n += 1) {
                    v = v * 8 + (t[i] - '0');
                    i += 1;
                }
                i -= 1;
                o.append(mem.gpa, @truncate(v)) catch {};
            },
            else => {
                o.append(mem.gpa, '\\') catch {};
                o.append(mem.gpa, c) catch {};
            },
        }
    }
    return o.items;
}

var error_shown = false;

/// Index just past the bracket that closes the one at `open`, skipping quoted
/// text and nested brackets. An unterminated bracket runs to the end.
fn matchingClose(text: []const u8, open: usize) usize {
    var depth: usize = 0;
    var i = open;
    var quote: u8 = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (c == '\\' and quote == '"' and i + 1 < text.len) {
                i += 1;
            } else if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '{', '(' => depth += 1,
            '}', ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return text.len;
}

/// Step 2: evaluate `$(cmd)`, `${expr}` and `$name` with dksh's string rules.
fn interpolate(ip: *Interp, text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '$') == null) return text;
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(mem.gpa, "var __ps = \"") catch return text;
    // Literal text is escaped for a dksh string; `${...}` and `$(...)` are code
    // and are copied as they are, up to their matching close.
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '$' and i + 1 < text.len and (text[i + 1] == '{' or text[i + 1] == '(')) {
            const end = matchingClose(text, i + 1);
            src.appendSlice(mem.gpa, text[i..end]) catch {};
            i = end;
            continue;
        }
        if (c == '\\' or c == '"') src.append(mem.gpa, '\\') catch {};
        src.append(mem.gpa, c) catch {};
        i += 1;
    }
    src.append(mem.gpa, '"') catch {};

    const prog = parser.parseSource("<prompt>", src.items) catch {
        if (!error_shown) {
            error_shown = true;
            sys.write(2, mem.print("dksh: prompt: {s}\n", .{parser.diag.message}));
        }
        return text;
    };
    if (prog.stmts.len != 1 or prog.stmts[0].kind != .var_decl) return text;
    const v = ip.eval(prog.stmts[0].kind.var_decl.init, ip.globals) catch |e| {
        if (e == error.Raise and !error_shown) {
            error_shown = true;
            sys.write(2, mem.print("dksh: prompt: {s} (showing the template as it is)\n", .{ip.err.message}));
        }
        return text;
    };
    return if (v == .str) v.str else text;
}

/// Expand a prompt template (the value of PS1 or PS2).
pub fn render(ip: *Interp, text: []const u8) []const u8 {
    const step1 = expandEscapes(ip, text);
    const step2 = interpolate(ip, step1);
    const sign: u8 = if (sys.getuid() == 0) '#' else '$';
    const out = mem.gpa.dupe(u8, step2) catch return step2;
    for (out) |*c| {
        if (c.* == dollar_marker) c.* = sign;
    }
    return out;
}

/// The template for PS1/PS2: a global variable wins over the environment.
pub fn template(ip: *Interp, name: []const u8) ?[]const u8 {
    if (ip.globals.lookup(name)) |slot| {
        if (slot.value == .str) return slot.value.str;
    }
    return envStr(ip, name);
}
