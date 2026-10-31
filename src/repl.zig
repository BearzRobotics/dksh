//! The interactive loop: prompt, read, run (SPEC 6).

const std = @import("std");
const mem = @import("mem.zig");
const sys = @import("sys.zig");
const parser = @import("parser.zig");
const editor = @import("editor.zig");
const complete = @import("complete.zig");
const jobs = @import("jobs.zig");
const prompts = @import("prompt.zig");
const interp_mod = @import("interp.zig");
const Interp = interp_mod.Interp;

fn envStr(ip: *Interp, name: []const u8) ?[]const u8 {
    const v = ip.env_map.get(name) orelse return null;
    return if (v == .str and v.str.len > 0) v.str else null;
}

fn configDir(ip: *Interp) []const u8 {
    if (envStr(ip, "XDG_CONFIG_HOME")) |d| return mem.print("{s}/dksh", .{d});
    return mem.print("{s}/.config/dksh", .{envStr(ip, "HOME") orelse ""});
}

fn stateDir(ip: *Interp) []const u8 {
    if (envStr(ip, "XDG_STATE_HOME")) |d| return mem.print("{s}/dksh", .{d});
    return mem.print("{s}/.local/state/dksh", .{envStr(ip, "HOME") orelse ""});
}

fn sourceIfExists(ip: *Interp, path: []const u8) void {
    const text = sys.readFile(mem.gpa, path) catch return;
    _ = ip.runSource(path, text, ip.globals);
}

fn defaultPrompt(ip: *Interp) []const u8 {
    const uid = sys.getuid();
    const user = envStr(ip, "USER") orelse sys.userNameOf(uid) orelse "user";
    const host = sys.hostName(mem.gpa) catch "host";
    const cwd = sys.getcwd(mem.gpa) catch "?";
    var shown = cwd;
    if (envStr(ip, "HOME")) |h| {
        if (h.len > 1 and std.mem.startsWith(u8, cwd, h) and (cwd.len == h.len or cwd[h.len] == '/')) shown = mem.print("~{s}", .{cwd[h.len..]});
    }
    return mem.print("{s}@{s} {s} {c} ", .{ user, host, shown, @as(u8, if (uid == 0) '#' else '>') });
}

/// The text of the `prompt` function, or the default.
fn promptText(ip: *Interp) []const u8 {
    if (ip.globals.lookup("prompt")) |slot| {
        if (slot.value == .func) {
            const r = ip.callFunc(slot.value.func, null, &.{}, .{}) catch |e| {
                if (e == error.Raise) ip.report();
                return defaultPrompt(ip);
            };
            if (r == .str) return r.str;
        }
    }
    if (prompts.template(ip, "PS1")) |t| return prompts.render(ip, t);
    return defaultPrompt(ip);
}

const Ctx = struct {
    ip: *Interp,
    /// Whether a command word resolves, cached until the next prompt.
    known: std.StringHashMapUnmanaged(bool) = .empty,
};

const keyword_list = [_][]const u8{ "var", "const", "if", "else", "while", "for", "fn", "class", "return", "break", "continue", "try", "catch", "finally", "import", "subshell", "extends", "in" };

fn commandExists(ctx: *Ctx, word: []const u8) bool {
    if (ctx.known.get(word)) |v| return v;
    const ip = ctx.ip;
    var ok = false;
    if (ip.globals.lookup(word) != null) {
        ok = true;
    } else if (@import("builtins.zig").findCommand(word) != null or @import("builtins.zig").find(word) != null) {
        ok = true;
    } else if (std.mem.indexOfScalar(u8, word, '/') != null) {
        ok = sys.kindOf(mem.gpa, word) != .none;
    } else if (std.mem.startsWith(u8, word, "~") or std.mem.startsWith(u8, word, "$")) {
        ok = true;
    } else ok = @import("builtins.zig").findExecutable(ip, word) != null;
    ctx.known.put(mem.gpa, mem.dupe(word), ok) catch {};
    return ok;
}

/// Syntax colors: command words (green when they resolve, red when not),
/// keywords, quoted text, `$variables` and comments.
fn highlightHook(ctx_ptr: *anyopaque, text: []const u8, classes: []u8) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const C = editor.Class;
    var i: usize = 0;
    var cmd_pos = true;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '#' and (i == 0 or std.mem.indexOfScalar(u8, " \t\n;|&(", text[i - 1]) != null)) {
            while (i < text.len and text[i] != '\n') : (i += 1) classes[i] = C.comment;
            continue;
        }
        if (ch == '\n' or ch == ';' or ch == '|' or ch == '&' or ch == '(' or ch == '{') {
            cmd_pos = true;
            i += 1;
            continue;
        }
        if (ch == ' ' or ch == '\t' or ch == ')' or ch == '<' or ch == '>' or ch == '}') {
            i += 1;
            continue;
        }
        // One word.
        const start = i;
        var quote: u8 = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (quote != 0) {
                classes[i] = C.string;
                if (c == '\\' and quote == '"' and i + 1 < text.len) {
                    i += 1;
                    classes[i] = C.string;
                } else if (c == '$' and quote == '"' and i + 1 < text.len and (std.ascii.isAlphabetic(text[i + 1]) or text[i + 1] == '_' or text[i + 1] == '{')) {
                    classes[i] = C.variable;
                } else if (c == quote) quote = 0;
                continue;
            }
            if (c == '"' or c == '\'') {
                quote = c;
                classes[i] = C.string;
                continue;
            }
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\n' or c == ';' or c == '|' or c == '&' or c == '(' or c == ')' or c == '<' or c == '>') break;
            if (c == '$' and i + 1 < text.len and (std.ascii.isAlphabetic(text[i + 1]) or text[i + 1] == '_' or text[i + 1] == '{' or text[i + 1] == '(')) classes[i] = C.variable;
        }
        if (cmd_pos) {
            const word = text[start..i];
            var cls: u8 = undefined;
            var is_kw = false;
            for (keyword_list) |k| {
                if (std.mem.eql(u8, k, word)) is_kw = true;
            }
            if (is_kw) {
                cls = C.keyword;
            } else cls = if (commandExists(ctx, word)) C.command_ok else C.command_bad;
            for (start..i) |k| {
                if (classes[k] == C.plain) classes[k] = cls;
            }
            // After these the next word is still a command position (`if grep ...`, `else if`).
            cmd_pos = is_kw and !std.mem.eql(u8, word, "var") and !std.mem.eql(u8, word, "const") and !std.mem.eql(u8, word, "fn") and !std.mem.eql(u8, word, "class") and !std.mem.eql(u8, word, "import") and !std.mem.eql(u8, word, "for") and !std.mem.eql(u8, word, "catch") and !std.mem.eql(u8, word, "extends");
        } else cmd_pos = false;
    }
}

fn isComplete(ctx: *anyopaque, text: []const u8) bool {
    _ = ctx;
    // A trailing backslash continues the line.
    var bs: usize = 0;
    var i = text.len;
    while (i > 0 and text[i - 1] == '\\') : (i -= 1) bs += 1;
    if (bs % 2 == 1) return false;
    const file = @import("source.zig").add("<prompt>", text);
    var p = parser.Parser.init(file);
    _ = p.parseProgram() catch |e| return e != error.Incomplete;
    return true;
}

fn completeHook(ctx: *anyopaque, text: []const u8, cursor: usize) ?editor.Completion {
    const c: *Ctx = @ptrCast(@alignCast(ctx));
    return complete.complete(c.ip, text, cursor);
}

/// Login shells read the profile files first, whether they then run a
/// command, a script or the prompt (`su - user -c cmd`, `sudo -i cmd`).
pub fn sourceProfiles(ip: *Interp) void {
    sourceIfExists(ip, "/etc/dksh/profile.dksh");
    sourceIfExists(ip, mem.print("{s}/profile.dksh", .{configDir(ip)}));
}

pub fn run(ip: *Interp, login: bool, force: bool) u8 {
    if (!force and !sys.isatty(0)) {
        // Input redirected: behave like a script read from standard input.
        const text = sys.readAll(mem.gpa, 0) catch return 1;
        return ip.runSource("<stdin>", text, ip.globals);
    }
    ip.interactive = true;
    ip.errexit = false;
    jobs.initInteractive();
    if (ip.env_map.get("PWD") == null) {
        if (sys.getcwd(mem.gpa)) |cwd| ip.env_map.put("PWD", .{ .str = cwd }) else |_| {}
    }

    // Login profiles were already read by main (for every mode).
    _ = login;
    sourceIfExists(ip, "/etc/dksh/dkshrc.dksh");
    sourceIfExists(ip, mem.print("{s}/dkshrc.dksh", .{configDir(ip)}));

    editor.loadHistory(mem.print("{s}/history", .{stateDir(ip)}));

    var ctx: Ctx = .{ .ip = ip };
    const no_color = envStr(ip, "NO_COLOR") != null;
    const dumb = if (envStr(ip, "TERM")) |t| std.mem.eql(u8, t, "dumb") else true;
    const hooks: editor.Hooks = .{
        .ctx = &ctx,
        .isComplete = isComplete,
        .complete = completeHook,
        .highlight = highlightHook,
        .colors = !no_color and !dumb,
    };

    while (true) {
        jobs.reapAndReport();
        ctx.known = .empty; // PATH may have changed since the last command
        // `precmd()` runs before every prompt, like bash's PROMPT_COMMAND.
        if (ip.globals.lookup("precmd")) |slot| {
            if (slot.value == .func) {
                _ = ip.callFunc(slot.value.func, null, &.{}, .{}) catch |e| {
                    if (e == error.Raise) ip.report();
                };
            }
        }
        const prompt = promptText(ip);
        const cont: []const u8 = if (prompts.template(ip, "PS2")) |t| prompts.render(ip, t) else "... ";
        const line = editor.readLine(prompt, cont, hooks) orelse {
            sys.write(1, "exit\n");
            return ip.last_status;
        };
        if (std.mem.trim(u8, line, " \t\n").len == 0) continue;
        editor.addHistory(line);
        ip.cmd_number += 1;
        const st = ip.runSource("<stdin>", mem.dupe(line), ip.globals);
        if (st != ip.last_status or true) ip.last_status = st;
        if (ip.exit_code != 0 or ip.exit_requested) return ip.exit_code;
    }
}
