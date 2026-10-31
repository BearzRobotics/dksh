//! Interactive line editor on raw termios (SPEC 6.1): Emacs keys, multi-line
//! editing, shared history, Ctrl-R search, prefix history search, and a hook
//! for tab completion.

const std = @import("std");
const linux = std.os.linux;
const mem = @import("mem.zig");
const sys = @import("sys.zig");

// ============================================================ completions

/// One way to finish the word being completed.
pub const Item = struct {
    /// Replacement for the whole word (`start`..`end` of the result).
    text: []const u8,
    /// Text shown in the candidate list (defaults to `text`).
    shown: []const u8,
    /// Appended after `text` when this is the only candidate.
    append: []const u8 = "",
};

pub const Completion = struct {
    start: usize,
    end: usize,
    items: []const Item,
};

pub const Hooks = struct {
    ctx: *anyopaque,
    /// False when the text is an unfinished construct (more lines needed).
    isComplete: *const fn (ctx: *anyopaque, text: []const u8) bool,
    complete: *const fn (ctx: *anyopaque, text: []const u8, cursor: usize) ?Completion,
    /// Fill `classes[i]` (a `Class`) for every byte of `text`; null = no colors.
    highlight: ?*const fn (ctx: *anyopaque, text: []const u8, classes: []u8) void = null,
    /// Show history suggestions and syntax colors (off for dumb terminals).
    colors: bool = false,
};

/// Meaning of a byte in the edited line, for syntax highlighting.
pub const Class = struct {
    pub const plain: u8 = 0;
    pub const command_ok: u8 = 1;
    pub const command_bad: u8 = 2;
    pub const string: u8 = 3;
    pub const comment: u8 = 4;
    pub const variable: u8 = 5;
    pub const keyword: u8 = 6;
};

const class_colors = [_][]const u8{ "", "\x1b[32m", "\x1b[31m", "\x1b[33m", "\x1b[90m", "\x1b[36m", "\x1b[34m" };

// ================================================================= history

var history: std.ArrayList([]const u8) = .empty;
var history_path: ?[]const u8 = null;

fn escapeLine(line: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (line) |c| switch (c) {
        '\\' => out.appendSlice(mem.gpa, "\\\\") catch {},
        '\n' => out.appendSlice(mem.gpa, "\\n") catch {},
        else => out.append(mem.gpa, c) catch {},
    };
    return out.items;
}

fn unescapeLine(line: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and i + 1 < line.len) {
            i += 1;
            out.append(mem.gpa, if (line[i] == 'n') '\n' else line[i]) catch {};
        } else out.append(mem.gpa, line[i]) catch {};
    }
    return out.items;
}

/// Load the history file; later `addHistory` calls append to it.
pub fn loadHistory(path: []const u8) void {
    history_path = path;
    const data = sys.readFile(mem.gpa, path) catch return;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        history.append(mem.gpa, unescapeLine(l)) catch {};
    }
}

/// Record a command line, appending to the history file straight away so
/// other sessions see it.
pub fn addHistory(line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t\n");
    if (trimmed.len == 0) return;
    if (history.items.len > 0 and std.mem.eql(u8, history.items[history.items.len - 1], trimmed)) return;
    const copy = mem.dupe(trimmed);
    history.append(mem.gpa, copy) catch return;
    if (history_path) |p| {
        if (std.fs.path.dirname(p)) |d| makePath(d);
        sys.writeFile(mem.gpa, p, mem.print("{s}\n", .{escapeLine(copy)}), true) catch {};
    }
}

fn makePath(path: []const u8) void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const z = sys.dupeZ(mem.gpa, path[0..i]) catch return;
            _ = linux.mkdir(z.ptr, 0o755);
        }
    }
}

pub fn printHistory() void {
    for (history.items, 0..) |l, i| sys.write(1, mem.print("{d: >5}  {s}\n", .{ i + 1, l }));
}

// ================================================================= terminal

var saved_termios: ?linux.termios = null;

fn enterRaw() bool {
    var t: linux.termios = undefined;
    if (linux.errno(linux.tcgetattr(0, &t)) != .SUCCESS) return false;
    saved_termios = t;
    t.lflag.ICANON = false;
    t.lflag.ECHO = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
    t.iflag.IXON = false;
    t.iflag.ICRNL = false;
    t.iflag.INLCR = false;
    t.iflag.ISTRIP = false;
    t.iflag.BRKINT = false;
    t.cc[@intFromEnum(linux.V.MIN)] = 1;
    t.cc[@intFromEnum(linux.V.TIME)] = 0;
    _ = linux.tcsetattr(0, .DRAIN, &t);
    return true;
}

fn leaveRaw() void {
    if (saved_termios) |t| _ = linux.tcsetattr(0, .DRAIN, &t);
    saved_termios = null;
}

fn termWidth() usize {
    var ws: std.posix.winsize = undefined;
    if (linux.errno(linux.ioctl(1, linux.T.IOCGWINSZ, @intFromPtr(&ws))) == .SUCCESS and ws.col > 0) return ws.col;
    return 80;
}

const Key = union(enum) {
    char: u21,
    ctrl: u8, // letter, lower case
    alt: u21,
    up,
    down,
    left,
    right,
    home,
    end,
    delete,
    backspace,
    enter,
    tab,
    ctrl_left,
    ctrl_right,
    eof,
};

fn readByte(timeout_ms: i32) ?u8 {
    if (timeout_ms >= 0) {
        var fds = [_]linux.pollfd{.{ .fd = 0, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&fds, 1, timeout_ms);
        if (linux.errno(rc) == .INTR) return null;
        if (rc == 0) return null;
    }
    var b: [1]u8 = undefined;
    const n = sys.read(0, &b) catch return null;
    if (n == 0) return 0xFF; // EOF marker handled by caller
    return b[0];
}

fn readKey() Key {
    while (true) {
        const b = readByte(-1) orelse continue;
        switch (b) {
            0xFF => return .eof,
            '\r', '\n' => return .enter,
            '\t' => return .tab,
            127, 8 => return .backspace,
            27 => return readEscape(),
            1...7, 11...12, 14...26 => return .{ .ctrl = b + 'a' - 1 },
            else => {
                if (b < 0x80) return .{ .char = b };
                const n = std.unicode.utf8ByteSequenceLength(b) catch continue;
                var buf: [4]u8 = undefined;
                buf[0] = b;
                var i: usize = 1;
                while (i < n) : (i += 1) buf[i] = readByte(-1) orelse break;
                const cp = std.unicode.utf8Decode(buf[0..n]) catch continue;
                return .{ .char = cp };
            },
        }
    }
}

fn readEscape() Key {
    const b = readByte(60) orelse return .{ .alt = 27 };
    if (b == '[') {
        var params: [8]u8 = undefined;
        var n: usize = 0;
        while (true) {
            const c = readByte(60) orelse return .{ .alt = '[' };
            if ((c >= '0' and c <= '9') or c == ';') {
                if (n < params.len) {
                    params[n] = c;
                    n += 1;
                }
                continue;
            }
            const p = params[0..n];
            switch (c) {
                'A' => return .up,
                'B' => return .down,
                'C' => return if (std.mem.eql(u8, p, "1;5")) .ctrl_right else .right,
                'D' => return if (std.mem.eql(u8, p, "1;5")) .ctrl_left else .left,
                'H' => return .home,
                'F' => return .end,
                '~' => {
                    if (std.mem.eql(u8, p, "3")) return .delete;
                    if (std.mem.eql(u8, p, "1") or std.mem.eql(u8, p, "7")) return .home;
                    if (std.mem.eql(u8, p, "4") or std.mem.eql(u8, p, "8")) return .end;
                    return .{ .alt = 0 };
                },
                else => return .{ .alt = 0 },
            }
        }
    }
    if (b == 'O') {
        const c = readByte(60) orelse return .{ .alt = 'O' };
        return switch (c) {
            'H' => .home,
            'F' => .end,
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => .{ .alt = 0 },
        };
    }
    if (b == 127 or b == 8) return .{ .alt = 127 };
    return .{ .alt = b };
}

// ================================================================== editing

const State = struct {
    prompt: []const u8,
    cont: []const u8,
    hooks: Hooks,
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    rows_above_cursor: usize = 0,
    kill: []const u8 = "",
    hist_idx: usize = 0,
    hist_saved: []const u8 = "",
    hist_prefix: ?[]const u8 = null,
    last_was_tab: bool = false,
    /// Grey completion from history, drawn after the cursor; Right/End accepts it.
    ghost: []const u8 = "",
    show_ghost: bool = true,
};

/// Visible width of `s` (escape sequences take no space).
fn visibleWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == 27 and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7E)) i += 1;
            i += 1;
        } else if (c == 1 or c == 2) {
            i += 1; // readline-style invisible markers
        } else if ((c & 0xC0) == 0x80) {
            i += 1;
        } else {
            w += 1;
            i += 1;
        }
    }
    return w;
}

fn stripMarkers(s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| if (c != 1 and c != 2) out.append(mem.gpa, c) catch {};
    return out.items;
}

fn prevBoundary(s: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and (s[p] & 0xC0) == 0x80) p -= 1;
    return p;
}

fn nextBoundary(s: []const u8, pos: usize) usize {
    if (pos >= s.len) return s.len;
    var p = pos + 1;
    while (p < s.len and (s[p] & 0xC0) == 0x80) p += 1;
    return p;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn wordLeft(s: []const u8, pos: usize) usize {
    var p = pos;
    while (p > 0 and !isWordByte(s[p - 1])) p -= 1;
    while (p > 0 and isWordByte(s[p - 1])) p -= 1;
    return p;
}

fn wordRight(s: []const u8, pos: usize) usize {
    var p = pos;
    while (p < s.len and !isWordByte(s[p])) p += 1;
    while (p < s.len and isWordByte(s[p])) p += 1;
    return p;
}

const Layout = struct { end_row: usize, end_col: usize, cur_row: usize, cur_col: usize };

fn layout(st: *State, width: usize, prompt_w: usize, cont_w: usize) Layout {
    var row: usize = 0;
    var col: usize = prompt_w;
    var cur_row: usize = 0;
    var cur_col: usize = prompt_w;
    const text = st.buf.items;
    var i: usize = 0;
    while (i <= text.len) {
        if (i == st.cursor) {
            cur_row = row;
            cur_col = col;
        }
        if (i == text.len) break;
        const c = text[i];
        if (c == '\n') {
            row += 1;
            col = cont_w;
            i += 1;
            continue;
        }
        const n = nextBoundary(text, i) - i;
        col += 1;
        if (col >= width) {
            row += 1;
            col = 0;
        }
        i += n;
    }
    return .{ .end_row = row, .end_col = col, .cur_row = cur_row, .cur_col = cur_col };
}

/// The rest of the newest history entry that starts with the buffer.
fn suggestion(st: *State) []const u8 {
    const text = st.buf.items;
    if (!st.hooks.colors or !st.show_ghost or text.len == 0 or st.cursor != text.len) return "";
    if (std.mem.indexOfScalar(u8, text, '\n') != null) return "";
    var i = history.items.len;
    while (i > 0) {
        i -= 1;
        const h = history.items[i];
        if (h.len > text.len and std.mem.startsWith(u8, h, text) and std.mem.indexOfScalar(u8, h, '\n') == null) return h[text.len..];
    }
    return "";
}

fn refresh(st: *State) void {
    const width = termWidth();
    var out: std.ArrayList(u8) = .empty;
    if (st.rows_above_cursor > 0) out.print(mem.gpa, "\x1b[{d}A", .{st.rows_above_cursor}) catch {};
    out.appendSlice(mem.gpa, "\r\x1b[J") catch {};
    out.appendSlice(mem.gpa, stripMarkers(st.prompt)) catch {};
    const text = st.buf.items;
    var col: usize = visibleWidth(st.prompt);
    const cont_w = visibleWidth(st.cont);
    var classes: []u8 = &.{};
    if (st.hooks.colors) {
        if (st.hooks.highlight) |hl| {
            classes = mem.gpa.alloc(u8, text.len) catch &.{};
            if (classes.len == text.len) {
                @memset(classes, 0);
                hl(st.hooks.ctx, text, classes);
            } else classes = &.{};
        }
    }
    var cur_class: u8 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (classes.len > 0 and classes[i] != cur_class and c != '\n') {
            cur_class = classes[i];
            out.appendSlice(mem.gpa, "\x1b[0m") catch {};
            if (cur_class < class_colors.len) out.appendSlice(mem.gpa, class_colors[cur_class]) catch {};
        }
        if (c == '\n') {
            out.appendSlice(mem.gpa, "\r\n") catch {};
            out.appendSlice(mem.gpa, stripMarkers(st.cont)) catch {};
            col = cont_w;
            i += 1;
            continue;
        }
        const n = nextBoundary(text, i) - i;
        out.appendSlice(mem.gpa, text[i .. i + n]) catch {};
        col += 1;
        if (col >= width) {
            out.appendSlice(mem.gpa, "\r\n") catch {};
            col = 0;
        }
        i += n;
    }
    if (cur_class != 0) out.appendSlice(mem.gpa, "\x1b[0m") catch {};
    const lay = layout(st, width, visibleWidth(st.prompt), cont_w);
    // Draw the suggestion only when it fits on the current row.
    st.ghost = suggestion(st);
    if (st.ghost.len > 0) {
        if (lay.end_col + visibleWidth(st.ghost) + 1 < width) {
            out.print(mem.gpa, "\x1b[90m{s}\x1b[0m", .{st.ghost}) catch {};
        } else st.ghost = "";
    }
    if (lay.end_row > lay.cur_row) out.print(mem.gpa, "\x1b[{d}A", .{lay.end_row - lay.cur_row}) catch {};
    out.appendSlice(mem.gpa, "\r") catch {};
    if (lay.cur_col > 0) out.print(mem.gpa, "\x1b[{d}C", .{lay.cur_col}) catch {};
    st.rows_above_cursor = lay.cur_row;
    sys.write(1, out.items);
}

fn insertText(st: *State, s: []const u8) void {
    st.buf.insertSlice(mem.gpa, st.cursor, s) catch return;
    st.cursor += s.len;
}

fn deleteRange(st: *State, from: usize, to: usize) void {
    if (from >= to) return;
    st.buf.replaceRange(mem.gpa, from, to - from, &.{}) catch return;
    if (st.cursor > from) st.cursor = if (st.cursor >= to) st.cursor - (to - from) else from;
}

fn killRange(st: *State, from: usize, to: usize) void {
    if (from >= to) return;
    st.kill = mem.dupe(st.buf.items[from..to]);
    deleteRange(st, from, to);
}

fn setBuffer(st: *State, text: []const u8) void {
    st.buf.clearRetainingCapacity();
    st.buf.appendSlice(mem.gpa, text) catch {};
    st.cursor = st.buf.items.len;
}

fn lineStart(st: *State) usize {
    var p = st.cursor;
    while (p > 0 and st.buf.items[p - 1] != '\n') p -= 1;
    return p;
}

fn lineEnd(st: *State) usize {
    var p = st.cursor;
    while (p < st.buf.items.len and st.buf.items[p] != '\n') p += 1;
    return p;
}

// ----------------------------------------------------------------- history

fn historyUp(st: *State) void {
    if (st.hist_idx == history.items.len) {
        st.hist_saved = mem.dupe(st.buf.items);
        // A partly typed line searches by prefix.
        st.hist_prefix = if (st.cursor > 0) mem.dupe(st.buf.items[0..st.cursor]) else null;
    }
    var i = st.hist_idx;
    while (i > 0) {
        i -= 1;
        if (st.hist_prefix == null or std.mem.startsWith(u8, history.items[i], st.hist_prefix.?)) {
            st.hist_idx = i;
            setBuffer(st, history.items[i]);
            return;
        }
    }
}

fn historyDown(st: *State) void {
    if (st.hist_idx >= history.items.len) return;
    var i = st.hist_idx + 1;
    while (i < history.items.len) : (i += 1) {
        if (st.hist_prefix == null or std.mem.startsWith(u8, history.items[i], st.hist_prefix.?)) {
            st.hist_idx = i;
            setBuffer(st, history.items[i]);
            return;
        }
    }
    st.hist_idx = history.items.len;
    setBuffer(st, st.hist_saved);
    if (st.hist_prefix) |p| st.cursor = p.len;
}

fn resetHistoryNav(st: *State) void {
    st.hist_idx = history.items.len;
    st.hist_prefix = null;
}

// ------------------------------------------------------------------ Ctrl-R

/// Incremental search. Returns the key that ended it (to be processed
/// normally) or null if the search accepted the line with Enter.
fn reverseSearch(st: *State) ?Key {
    var query: std.ArrayList(u8) = .empty;
    var found: ?usize = null;
    var from: usize = history.items.len;
    const saved = mem.dupe(st.buf.items);
    while (true) {
        // Draw the search prompt on the current line.
        const shown = if (found) |f| history.items[f] else "";
        sys.write(1, mem.print("\r\x1b[J(reverse-i-search)`{s}': {s}", .{ query.items, shown }));
        const key = readKey();
        switch (key) {
            .char => |c| {
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &b) catch continue;
                query.appendSlice(mem.gpa, b[0..n]) catch {};
                from = history.items.len;
                found = searchBack(query.items, &from, true);
            },
            .backspace => {
                if (query.items.len > 0) query.items.len = prevBoundary(query.items, query.items.len);
                from = history.items.len;
                found = searchBack(query.items, &from, true);
            },
            .ctrl => |c| switch (c) {
                'r' => {
                    if (found) |f| from = f;
                    if (searchBack(query.items, &from, false)) |nf| found = nf;
                },
                'g', 'c' => {
                    setBuffer(st, saved);
                    st.rows_above_cursor = 0;
                    sys.write(1, "\r\x1b[J");
                    return .{ .char = 0 }; // consumed: redraw only
                },
                else => {
                    if (found) |f| setBuffer(st, history.items[f]);
                    st.rows_above_cursor = 0;
                    sys.write(1, "\r\x1b[J");
                    return key;
                },
            },
            .enter => {
                if (found) |f| setBuffer(st, history.items[f]);
                st.rows_above_cursor = 0;
                sys.write(1, "\r\x1b[J");
                return null;
            },
            else => {
                if (found) |f| setBuffer(st, history.items[f]);
                st.rows_above_cursor = 0;
                sys.write(1, "\r\x1b[J");
                return key;
            },
        }
    }
}

/// Find the newest entry before `*from` containing `q` (or equal to the
/// start when `inclusive` and the current match should be kept).
fn searchBack(q: []const u8, from: *usize, restart: bool) ?usize {
    _ = restart;
    if (q.len == 0) return null;
    var i = from.*;
    while (i > 0) {
        i -= 1;
        if (std.mem.indexOf(u8, history.items[i], q) != null) {
            from.* = i;
            return i;
        }
    }
    return null;
}

// -------------------------------------------------------------- completion

fn commonPrefix(items: []const Item) []const u8 {
    var p: []const u8 = items[0].text;
    for (items[1..]) |it| {
        var n: usize = 0;
        while (n < p.len and n < it.text.len and p[n] == it.text[n]) n += 1;
        p = p[0..n];
    }
    // Do not split a UTF-8 sequence.
    while (p.len > 0 and p.len < items[0].text.len and (items[0].text[p.len] & 0xC0) == 0x80) p = p[0 .. p.len - 1];
    return p;
}

fn showCandidates(st: *State, items: []const Item) void {
    // Move below the edited text, list, then redraw from a fresh line.
    const width = termWidth();
    const lay = layout(st, width, visibleWidth(st.prompt), visibleWidth(st.cont));
    var out: std.ArrayList(u8) = .empty;
    if (lay.end_row > lay.cur_row) out.print(mem.gpa, "\x1b[{d}B", .{lay.end_row - lay.cur_row}) catch {};
    out.appendSlice(mem.gpa, "\r\n") catch {};
    var maxw: usize = 0;
    for (items) |it| maxw = @max(maxw, visibleWidth(it.shown));
    const colw = maxw + 2;
    const cols = @max(1, width / colw);
    for (items, 0..) |it, i| {
        out.appendSlice(mem.gpa, it.shown) catch {};
        if ((i + 1) % cols == 0 or i + 1 == items.len) {
            out.appendSlice(mem.gpa, "\r\n") catch {};
        } else out.appendNTimes(mem.gpa, ' ', colw - visibleWidth(it.shown)) catch {};
    }
    sys.write(1, out.items);
    st.rows_above_cursor = 0;
}

fn doComplete(st: *State) void {
    const comp = st.hooks.complete(st.hooks.ctx, st.buf.items, st.cursor) orelse return;
    if (comp.items.len == 0) return;
    if (comp.items.len == 1) {
        const it = comp.items[0];
        const rep = mem.print("{s}{s}", .{ it.text, it.append });
        st.buf.replaceRange(mem.gpa, comp.start, comp.end - comp.start, rep) catch return;
        st.cursor = comp.start + rep.len;
        st.last_was_tab = false;
        return;
    }
    const lcp = commonPrefix(comp.items);
    if (lcp.len > comp.end - comp.start or !std.mem.eql(u8, lcp, st.buf.items[comp.start..comp.end])) {
        st.buf.replaceRange(mem.gpa, comp.start, comp.end - comp.start, lcp) catch return;
        st.cursor = comp.start + lcp.len;
        // Still ambiguous: the next Tab lists the candidates.
        st.last_was_tab = true;
        return;
    }
    if (st.last_was_tab) {
        showCandidates(st, comp.items);
        st.last_was_tab = false;
    } else st.last_was_tab = true;
}

// -------------------------------------------------------------------- main

fn transpose(st: *State) void {
    const s = st.buf.items;
    if (s.len < 2) return;
    var at = st.cursor;
    if (at == s.len) at = prevBoundary(s, at);
    if (at == 0) return;
    const a = prevBoundary(s, at);
    const b = nextBoundary(s, at);
    const first = mem.dupe(s[a..at]);
    const second = mem.dupe(s[at..b]);
    st.buf.replaceRange(mem.gpa, a, b - a, mem.print("{s}{s}", .{ second, first })) catch return;
    st.cursor = b;
}

/// Read one (possibly multi-line) command. Null means end of input.
pub fn readLine(prompt: []const u8, cont_prompt: []const u8, hooks: Hooks) ?[]const u8 {
    if (!enterRaw()) {
        // Not a terminal: plain buffered read.
        sys.write(1, stripMarkers(prompt));
        return readPlain();
    }
    defer leaveRaw();
    var st: State = .{ .prompt = prompt, .cont = cont_prompt, .hooks = hooks };
    st.hist_idx = history.items.len;
    refresh(&st);

    var pending: ?Key = null;
    while (true) {
        const key = pending orelse readKey();
        pending = null;
        st.show_ghost = true;
        var tab = false;
        switch (key) {
            .eof => return null,
            .enter => {
                if (!hooks.isComplete(hooks.ctx, st.buf.items)) {
                    st.cursor = st.buf.items.len;
                    insertText(&st, "\n");
                    refresh(&st);
                    continue;
                }
                st.cursor = st.buf.items.len;
                st.show_ghost = false;
                refresh(&st);
                sys.write(1, "\r\n");
                return st.buf.items;
            },
            .char => |c| {
                if (c == 0) {} else {
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(c, &b) catch continue;
                    insertText(&st, b[0..n]);
                    resetHistoryNav(&st);
                }
            },
            .backspace => {
                deleteRange(&st, prevBoundary(st.buf.items, st.cursor), st.cursor);
                resetHistoryNav(&st);
            },
            .delete => deleteRange(&st, st.cursor, nextBoundary(st.buf.items, st.cursor)),
            .left => st.cursor = prevBoundary(st.buf.items, st.cursor),
            .right => {
                if (st.cursor == st.buf.items.len and st.ghost.len > 0) {
                    insertText(&st, st.ghost);
                } else st.cursor = nextBoundary(st.buf.items, st.cursor);
            },
            .home => st.cursor = lineStart(&st),
            .end => {
                if (st.cursor == st.buf.items.len and st.ghost.len > 0) {
                    insertText(&st, st.ghost);
                } else st.cursor = lineEnd(&st);
            },
            .ctrl_left => st.cursor = wordLeft(st.buf.items, st.cursor),
            .ctrl_right => st.cursor = wordRight(st.buf.items, st.cursor),
            .up => historyUp(&st),
            .down => historyDown(&st),
            .tab => {
                tab = true;
                doComplete(&st);
            },
            .alt => |c| switch (c) {
                'b' => st.cursor = wordLeft(st.buf.items, st.cursor),
                'f' => st.cursor = wordRight(st.buf.items, st.cursor),
                'd' => killRange(&st, st.cursor, wordRight(st.buf.items, st.cursor)),
                127 => killRange(&st, wordLeft(st.buf.items, st.cursor), st.cursor),
                else => {},
            },
            .ctrl => |c| switch (c) {
                'a' => st.cursor = lineStart(&st),
                'e' => {
                    if (st.cursor == st.buf.items.len and st.ghost.len > 0) {
                        insertText(&st, st.ghost);
                    } else st.cursor = lineEnd(&st);
                },
                'b' => st.cursor = prevBoundary(st.buf.items, st.cursor),
                'f' => {
                    if (st.cursor == st.buf.items.len and st.ghost.len > 0) {
                        insertText(&st, st.ghost);
                    } else st.cursor = nextBoundary(st.buf.items, st.cursor);
                },
                'd' => {
                    if (st.buf.items.len == 0) return null;
                    deleteRange(&st, st.cursor, nextBoundary(st.buf.items, st.cursor));
                },
                'h' => deleteRange(&st, prevBoundary(st.buf.items, st.cursor), st.cursor),
                'k' => killRange(&st, st.cursor, if (st.cursor < st.buf.items.len and st.buf.items[st.cursor] == '\n') st.cursor + 1 else lineEnd(&st)),
                'u' => killRange(&st, lineStart(&st), st.cursor),
                'w' => killRange(&st, wordLeft(st.buf.items, st.cursor), st.cursor),
                'y' => insertText(&st, st.kill),
                't' => transpose(&st),
                'l' => {
                    sys.write(1, "\x1b[H\x1b[2J");
                    st.rows_above_cursor = 0;
                },
                'p' => historyUp(&st),
                'n' => historyDown(&st),
                'r' => {
                    pending = reverseSearch(&st);
                    if (pending == null) {
                        // Enter during search: accept and run the found line.
                        refresh(&st);
                        sys.write(1, "\r\n");
                        return st.buf.items;
                    }
                    if (pending.? == .char and pending.?.char == 0) pending = null;
                },
                'c' => {
                    sys.write(1, "^C\r\n");
                    return "";
                },
                'j' => {
                    if (hooks.isComplete(hooks.ctx, st.buf.items)) {
                        st.cursor = st.buf.items.len;
                        refresh(&st);
                        sys.write(1, "\r\n");
                        return st.buf.items;
                    }
                },
                else => {},
            },
        }
        if (!tab) st.last_was_tab = false;
        refresh(&st);
    }
}

fn readPlain() ?[]const u8 {
    var line: std.ArrayList(u8) = .empty;
    var b: [1]u8 = undefined;
    var any = false;
    while (true) {
        const n = sys.read(0, &b) catch return null;
        if (n == 0) break;
        any = true;
        if (b[0] == '\n') return line.items;
        line.append(mem.gpa, b[0]) catch return null;
    }
    return if (any) line.items else null;
}

/// Restore the terminal (used on exit paths).
pub fn restoreTerminal() void {
    leaveRaw();
}
