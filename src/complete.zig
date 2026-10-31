//! Tab completion (SPEC 6.2): commands, files, variables and members.

const std = @import("std");
const mem = @import("mem.zig");
const sys = @import("sys.zig");
const builtins = @import("builtins.zig");
const editor = @import("editor.zig");
const value = @import("value.zig");
const Interp = @import("interp.zig").Interp;

const Item = editor.Item;

const keywords = [_][]const u8{ "var", "const", "if", "else", "while", "for", "fn", "class", "return", "break", "continue", "try", "catch", "import" };

fn lessItem(_: void, a: Item, b: Item) bool {
    return std.mem.lessThan(u8, a.shown, b.shown);
}

const Collector = struct {
    items: std.ArrayList(Item) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn add(c: *Collector, it: Item) void {
        if (c.seen.contains(it.text)) return;
        c.seen.put(mem.gpa, it.text, {}) catch return;
        c.items.append(mem.gpa, it) catch return;
    }

    fn addName(c: *Collector, prefix: []const u8, name: []const u8, append: []const u8) void {
        if (std.mem.startsWith(u8, name, prefix)) c.add(.{ .text = name, .shown = name, .append = append });
    }
};

/// Characters that need a backslash in an unquoted word.
fn needsEscape(c: u8, first: bool) bool {
    return switch (c) {
        ' ', '\t', '"', '\'', '$', '*', '?', '[', ']', '(', ')', '<', '>', '|', '&', ';', '\\', '{', '}' => true,
        '#', '~' => first,
        else => false,
    };
}

fn escapeWord(s: []const u8, quote: u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |c, i| {
        if (quote == 0) {
            if (needsEscape(c, i == 0)) out.append(mem.gpa, '\\') catch {};
        } else if (c == quote or (quote == '"' and (c == '$' or c == '\\'))) {
            out.append(mem.gpa, '\\') catch {};
        }
        out.append(mem.gpa, c) catch {};
    }
    return out.items;
}

fn unescapeWord(s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) i += 1;
        out.append(mem.gpa, s[i]) catch {};
    }
    return out.items;
}

const WordInfo = struct {
    start: usize,
    quote: u8,
    /// First word of its command?
    command_position: bool,
    /// Where the current command starts in the text.
    cmd_start: usize,
};

fn findWord(text: []const u8, cursor: usize) WordInfo {
    var quote: u8 = 0;
    var start: usize = 0;
    var words: usize = 0; // words seen so far in the current command, including this one
    var in_word = false;
    var i: usize = 0;
    var cmd_start: usize = 0;
    while (i < cursor) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (c == '\\' and quote == '"' and i + 1 < cursor) {
                i += 1;
            } else if (c == quote) quote = 0;
            continue;
        }
        if (c == '\\' and i + 1 < cursor) {
            if (!in_word) {
                in_word = true;
                start = i;
                words += 1;
            }
            i += 1;
            continue;
        }
        const sep = c == ' ' or c == '\t' or c == '\n';
        const op = c == '|' or c == ';' or c == '&' or c == '(' or c == '{' or c == '\n';
        if (sep or op or c == ')' or c == '<' or c == '>') {
            in_word = false;
            if (op) {
                words = 0;
                cmd_start = i + 1;
            }
            start = i + 1;
            continue;
        }
        if (!in_word) {
            in_word = true;
            start = i;
            words += 1;
        }
        if (c == '"' or c == '\'') quote = c;
    }
    if (!in_word) {
        start = cursor;
        words += 1;
    }
    return .{ .start = start, .quote = 0, .command_position = words == 1, .cmd_start = cmd_start };
}

fn addVariables(ip: *Interp, c: *Collector, prefix: []const u8, append: []const u8) void {
    var it = ip.globals.vars.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.value != .func) c.addName(prefix, e.key_ptr.*, append);
    }
    for (ip.env_map.m.keys()) |k| c.addName(prefix, k, append);
    c.addName(prefix, "args", append);
}

fn addMembers(ip: *Interp, c: *Collector, name: []const u8, prefix: []const u8) bool {
    const slot = ip.globals.lookup(name) orelse return false;
    switch (slot.value) {
        .map => |m| {
            for (m.m.keys()) |k| c.addName(prefix, k, "");
            return true;
        },
        .object => |o| {
            for (o.fields.keys()) |k| c.addName(prefix, k, "");
            var cls: ?*value.Class = o.class;
            while (cls) |cl| : (cls = cl.parent) {
                var mi = cl.methods.iterator();
                while (mi.next()) |e| c.addName(prefix, e.key_ptr.*, "(");
            }
            return true;
        },
        .regex => {
            for ([_][]const u8{ "test", "match", "matchAll", "replace", "split" }) |m| c.addName(prefix, m, "(");
            return true;
        },
        else => return false,
    }
}

fn addCommands(ip: *Interp, c: *Collector, prefix: []const u8) void {
    // Names are also valid here when the cursor is inside an expression like print(na|.
    addVariables(ip, c, prefix, "");
    for (keywords) |k| c.addName(prefix, k, " ");
    for (builtins.commandNames()) |cmd| c.addName(prefix, cmd.name, " ");
    for (builtins.nativeNames()) |n| c.addName(prefix, n.name, "(");
    var it = ip.globals.vars.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.value == .func) c.addName(prefix, e.key_ptr.*, " ");
    }
    const pv = ip.env_map.get("PATH");
    const path = if (pv) |p| (if (p == .str) p.str else "") else "/usr/bin:/bin";
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        const names = sys.listDir(mem.gpa, if (dir.len == 0) "." else dir) catch continue;
        for (names) |n| {
            if (!std.mem.startsWith(u8, n, prefix)) continue;
            if (n[0] == '.' and prefix.len == 0) continue;
            const full = std.fs.path.join(mem.gpa, &.{ dir, n }) catch continue;
            if (sys.isExecutable(mem.gpa, full)) c.add(.{ .text = escapeWord(n, 0), .shown = n, .append = " " });
        }
    }
}

fn addFiles(ip: *Interp, c: *Collector, word: []const u8, quote: u8) void {
    const slash = std.mem.lastIndexOfScalar(u8, word, '/');
    const dir_part = if (slash) |s| word[0 .. s + 1] else "";
    const base = if (slash) |s| word[s + 1 ..] else word;
    var list_dir: []const u8 = if (dir_part.len == 0) "." else dir_part;
    if (std.mem.startsWith(u8, dir_part, "~")) {
        const home = if (ip.env_map.get("HOME")) |h| (if (h == .str) h.str else "") else "";
        list_dir = mem.print("{s}{s}", .{ home, dir_part[1..] });
    }
    const names = sys.listDir(mem.gpa, list_dir) catch return;
    for (names) |n| {
        if (!std.mem.startsWith(u8, n, base)) continue;
        if (n[0] == '.' and !std.mem.startsWith(u8, base, ".")) continue;
        const full = std.fs.path.join(mem.gpa, &.{ list_dir, n }) catch continue;
        const is_dir = sys.kindOf(mem.gpa, full) == .dir;
        // The directory part is kept as typed (escaped), tilde included.
        const text = mem.print("{s}{s}", .{ escapeWordKeepTilde(dir_part, quote), escapeWord(n, quote) });
        const shown = if (is_dir) mem.print("{s}/", .{n}) else n;
        const append: []const u8 = if (is_dir) "/" else switch (quote) {
            '"' => "\" ",
            '\'' => "' ",
            else => " ",
        };
        c.add(.{ .text = text, .shown = shown, .append = append });
    }
}

fn escapeWordKeepTilde(s: []const u8, quote: u8) []const u8 {
    if (s.len > 0 and s[0] == '~') return mem.print("~{s}", .{escapeWord(s[1..], quote)});
    return escapeWord(s, quote);
}

/// Per-command completion: a user function `complete_<command>(words, word)`
/// returns the candidates (an array of strings). Returns false when no such
/// function exists or it returns null, so file completion takes over.
fn userCompletion(ip: *Interp, c: *Collector, text: []const u8, info: WordInfo, word: []const u8) bool {
    var words_it = std.mem.tokenizeAny(u8, text[info.cmd_start..info.start], " \t\n");
    const words = value.Value.newArray();
    var first: ?[]const u8 = null;
    while (words_it.next()) |w| {
        if (first == null) first = w;
        words.items.append(mem.gpa, .{ .str = w }) catch return false;
    }
    const cmd = first orelse return false;
    var name: std.ArrayList(u8) = .empty;
    name.appendSlice(mem.gpa, "complete_") catch return false;
    for (cmd) |ch| name.append(mem.gpa, if (std.ascii.isAlphanumeric(ch) or ch == '_') ch else '_') catch return false;
    const slot = ip.globals.lookup(name.items) orelse return false;
    if (slot.value != .func) return false;
    const r = ip.callFunc(slot.value.func, null, &.{ .{ .array = words }, .{ .str = word } }, .{}) catch return false;
    if (r != .array) return false;
    for (r.array.items.items) |item| {
        if (item != .str) continue;
        if (!std.mem.startsWith(u8, item.str, word)) continue;
        c.add(.{ .text = escapeWord(item.str, info.quote), .shown = item.str, .append = " " });
    }
    return true;
}

pub fn complete(ip: *Interp, text: []const u8, cursor: usize) ?editor.Completion {
    var info = findWord(text, cursor);
    var raw = text[info.start..cursor];
    if (raw.len > 0 and (raw[0] == '"' or raw[0] == '\'')) {
        info.quote = raw[0];
        raw = raw[1..];
        info.start += 1;
    }
    var c: Collector = .{};

    // $name and ${name
    if (std.mem.lastIndexOfScalar(u8, raw, '$')) |d| {
        var name_start = d + 1;
        var close: []const u8 = "";
        if (name_start < raw.len and raw[name_start] == '{') {
            name_start += 1;
            close = "}";
        }
        const frag = raw[name_start..];
        var ok = true;
        for (frag) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) ok = false;
        }
        if (ok) {
            addVariables(ip, &c, frag, close);
            std.mem.sort(Item, c.items.items, {}, lessItem);
            return .{ .start = info.start + name_start, .end = cursor, .items = c.items.items };
        }
    }

    // name.member
    if (std.mem.lastIndexOfScalar(u8, raw, '.')) |dot| {
        const frag = raw[dot + 1 ..];
        var ok = frag.len == 0 or true;
        for (frag) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) ok = false;
        }
        var s = dot;
        while (s > 0 and (std.ascii.isAlphanumeric(raw[s - 1]) or raw[s - 1] == '_')) s -= 1;
        const obj = raw[s..dot];
        if (ok and obj.len > 0 and addMembers(ip, &c, obj, frag)) {
            std.mem.sort(Item, c.items.items, {}, lessItem);
            return .{ .start = info.start + dot + 1, .end = cursor, .items = c.items.items };
        }
    }

    const word = if (info.quote == 0) unescapeWord(raw) else raw;
    if (!info.command_position) {
        if (userCompletion(ip, &c, text, info, word)) {
            std.mem.sort(Item, c.items.items, {}, lessItem);
            return .{ .start = info.start, .end = cursor, .items = c.items.items };
        }
    }
    if (info.command_position and std.mem.indexOfScalar(u8, word, '/') == null and !std.mem.startsWith(u8, word, "~")) {
        addCommands(ip, &c, word);
    } else {
        addFiles(ip, &c, word, info.quote);
    }
    std.mem.sort(Item, c.items.items, {}, lessItem);
    return .{ .start = info.start, .end = cursor, .items = c.items.items };
}
