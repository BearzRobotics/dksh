//! Built-in commands (SPEC 7.1) and the standard library (SPEC 7.2).

const std = @import("std");
const linux = std.os.linux;
const ast = @import("ast.zig");
const mem = @import("mem.zig");
const sys = @import("sys.zig");
const glob = @import("glob.zig");
const format = @import("format.zig");
const time = @import("time.zig");
const value = @import("value.zig");
const regex = @import("regex.zig");
const jobs = @import("jobs.zig");
const json = @import("json.zig");
const signals = @import("signals.zig");
const prompts = @import("prompt.zig");
const editor = @import("editor.zig");
const Interp = @import("interp.zig").Interp;

const Value = value.Value;
const Span = ast.Span;
const Error = value.Error;

// ============================================================ commands (7.1)

pub const CommandFn = *const fn (ip: *Interp, argv: []const []const u8, span: Span) Error!u8;

const Command = struct { name: []const u8, run: CommandFn };

const commands = [_]Command{
    .{ .name = "cd", .run = cmdCd },
    .{ .name = "exit", .run = cmdExit },
    .{ .name = "source", .run = cmdSource },
    .{ .name = "jobs", .run = cmdJobs },
    .{ .name = "fg", .run = cmdFg },
    .{ .name = "bg", .run = cmdBg },
    .{ .name = "wait", .run = cmdWait },
    .{ .name = "disown", .run = cmdDisown },
    .{ .name = "exec", .run = cmdExec },
    .{ .name = "history", .run = cmdHistory },
    .{ .name = "type", .run = cmdType },
    .{ .name = "umask", .run = cmdUmask },
    .{ .name = "ulimit", .run = cmdUlimit },
};

pub fn findCommand(name: []const u8) ?CommandFn {
    for (commands) |c| if (std.mem.eql(u8, c.name, name)) return c.run;
    return null;
}

pub fn isCommandName(name: []const u8) bool {
    return findCommand(name) != null;
}

pub fn commandNames() []const Command {
    return &commands;
}

fn errOut(comptime fmt: []const u8, args: anytype) void {
    sys.write(2, mem.print(fmt, args));
}

fn setEnv(ip: *Interp, key: []const u8, v: []const u8) void {
    ip.env_map.put(mem.dupe(key), .{ .str = mem.dupe(v) });
}

fn cmdCd(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    if (argv.len > 2) return ip.raise(span, "cd: too many arguments", .{});
    const home: []const u8 = if (ip.env_map.get("HOME")) |h| (if (h == .str) h.str else "/") else "/";
    var target: []const u8 = if (argv.len == 2) argv[1] else home;
    var print_it = false;
    if (std.mem.eql(u8, target, "-")) {
        const old = ip.env_map.get("OLDPWD") orelse return ip.raise(span, "cd: OLDPWD is not set", .{});
        target = value.toDisplayString(old);
        print_it = true;
    }
    const before = sys.getcwd(mem.gpa) catch "";
    sys.chdir(mem.gpa, target) catch {
        errOut("cd: {s}: {s}\n", .{ target, sys.errnoText() });
        return 1;
    };
    const now = sys.getcwd(mem.gpa) catch target;
    setEnv(ip, "OLDPWD", before);
    setEnv(ip, "PWD", now);
    if (print_it) sys.write(1, mem.print("{s}\n", .{now}));
    return 0;
}

fn cmdExit(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    var code: u8 = ip.last_status;
    if (argv.len > 1) {
        const n = std.fmt.parseInt(i64, argv[1], 10) catch return ip.raise(span, "exit: numeric argument required", .{});
        code = @truncate(@as(u64, @bitCast(n)));
    }
    ip.exit_code = code;
    return error.Exit;
}

fn cmdSource(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    if (argv.len < 2) return ip.raise(span, "source: expected a file name", .{});
    const text = sys.readFile(mem.gpa, argv[1]) catch {
        errOut("source: {s}: {s}\n", .{ argv[1], sys.errnoText() });
        return 1;
    };
    return ip.runSource(argv[1], text, ip.globals);
}

fn cmdJobs(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    _ = ip;
    _ = argv;
    _ = span;
    jobs.printJobs();
    return 0;
}

fn cmdFg(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    return jobs.foregroundCmd(ip, if (argv.len > 1) argv[1] else null, span);
}

fn cmdBg(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    return jobs.backgroundCmd(ip, if (argv.len > 1) argv[1] else null, span);
}

fn cmdWait(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    return jobs.waitCmd(ip, if (argv.len > 1) argv[1] else null, span);
}

fn cmdDisown(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    return jobs.disownCmd(ip, if (argv.len > 1) argv[1] else null, span);
}

fn cmdHistory(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    _ = ip;
    _ = argv;
    _ = span;
    editor.printHistory();
    return 0;
}

fn cmdExec(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    if (argv.len < 2) return 0;
    const path = findExecutable(ip, argv[1]) orelse return ip.raiseStatus(span, 127, "exec: command not found: {s}", .{argv[1]});
    const args = mem.gpa.alloc(?[*:0]const u8, argv.len) catch @panic("out of memory");
    for (argv[1..], 0..) |a, i| args[i] = (sys.dupeZ(mem.gpa, a) catch @panic("out of memory")).ptr;
    args[argv.len - 1] = null;
    const envp = envBlock(ip);
    const e = sys.execve(path, @ptrCast(args.ptr), envp);
    errOut("exec: {s}: {s}\n", .{ argv[1], @tagName(e) });
    return 126;
}

pub fn envBlock(ip: *Interp) [*:null]const ?[*:0]const u8 {
    const m = ip.env_map.m;
    const arr = mem.gpa.alloc(?[*:0]const u8, m.count() + 1) catch @panic("out of memory");
    var i: usize = 0;
    var it = m.iterator();
    while (it.next()) |e| {
        const s = sys.dupeZ(mem.gpa, mem.print("{s}={s}", .{ e.key_ptr.*, value.toDisplayString(e.value_ptr.*) })) catch @panic("out of memory");
        arr[i] = s.ptr;
        i += 1;
    }
    arr[i] = null;
    return @ptrCast(arr.ptr);
}

pub fn findExecutable(ip: *Interp, name: []const u8) ?[:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (sys.isExecutable(mem.gpa, name)) return sys.dupeZ(mem.gpa, name) catch null;
        return null;
    }
    const pv = ip.env_map.get("PATH");
    const path = if (pv) |p| (if (p == .str) p.str else "/usr/bin:/bin") else "/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = std.fs.path.join(mem.gpa, &.{ if (dir.len == 0) "." else dir, name }) catch continue;
        if (sys.isExecutable(mem.gpa, full)) return sys.dupeZ(mem.gpa, full) catch null;
    }
    return null;
}

const Limit = struct { flag: u8, res: std.os.linux.rlimit_resource, unit: u64, what: []const u8 };

/// Units follow bash: -f and -c count 512-byte blocks, -s -d -v -m -l kilobytes.
const limits = [_]Limit{
    .{ .flag = 'c', .res = .CORE, .unit = 512, .what = "core file size (blocks)" },
    .{ .flag = 'd', .res = .DATA, .unit = 1024, .what = "data seg size (kbytes)" },
    .{ .flag = 'f', .res = .FSIZE, .unit = 512, .what = "file size (blocks)" },
    .{ .flag = 'l', .res = .MEMLOCK, .unit = 1024, .what = "max locked memory (kbytes)" },
    .{ .flag = 'm', .res = .RSS, .unit = 1024, .what = "max memory size (kbytes)" },
    .{ .flag = 'n', .res = .NOFILE, .unit = 1, .what = "open files" },
    .{ .flag = 's', .res = .STACK, .unit = 1024, .what = "stack size (kbytes)" },
    .{ .flag = 't', .res = .CPU, .unit = 1, .what = "cpu time (seconds)" },
    .{ .flag = 'u', .res = .NPROC, .unit = 1, .what = "max user processes" },
    .{ .flag = 'v', .res = .AS, .unit = 1024, .what = "virtual memory (kbytes)" },
};

fn showLimit(l: Limit, hard: bool) void {
    var r: std.os.linux.rlimit = undefined;
    if (std.os.linux.errno(std.os.linux.getrlimit(l.res, &r)) != .SUCCESS) return;
    const v = if (hard) r.max else r.cur;
    if (v == std.math.maxInt(u64)) {
        sys.write(1, "unlimited\n");
    } else sys.write(1, mem.print("{d}\n", .{v / l.unit}));
}

/// ulimit [-H|-S] [-a] [-c|-d|-f|-l|-m|-n|-s|-t|-u|-v] [limit|unlimited]
fn cmdUlimit(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    var which: Limit = limits[2]; // -f, like bash
    var hard = false;
    var soft = false;
    var all = false;
    var value_arg: ?[]const u8 = null;
    for (argv[1..]) |a| {
        if (a.len > 1 and a[0] == '-') {
            for (a[1..]) |f| {
                switch (f) {
                    'H' => hard = true,
                    'S' => soft = true,
                    'a' => all = true,
                    else => {
                        var found = false;
                        for (limits) |l| {
                            if (l.flag == f) {
                                which = l;
                                found = true;
                            }
                        }
                        if (!found) return ip.raise(span, "ulimit: unknown option -{c}", .{f});
                    },
                }
            }
        } else value_arg = a;
    }
    if (all) {
        for (limits) |l| {
            var r: std.os.linux.rlimit = undefined;
            if (std.os.linux.errno(std.os.linux.getrlimit(l.res, &r)) != .SUCCESS) continue;
            const v = if (hard) r.max else r.cur;
            const text = if (v == std.math.maxInt(u64)) "unlimited" else mem.print("{d}", .{v / l.unit});
            sys.write(1, mem.print("-{c}: {s: <28} {s}\n", .{ l.flag, l.what, text }));
        }
        return 0;
    }
    const text = value_arg orelse {
        showLimit(which, hard and !soft);
        return 0;
    };
    var r: std.os.linux.rlimit = undefined;
    _ = std.os.linux.getrlimit(which.res, &r);
    const new: u64 = if (std.mem.eql(u8, text, "unlimited")) std.math.maxInt(u64) else blk: {
        const n = std.fmt.parseInt(u64, text, 10) catch return ip.raise(span, "ulimit: invalid limit: {s}", .{text});
        break :blk std.math.mul(u64, n, which.unit) catch return ip.raise(span, "ulimit: limit too large: {s}", .{text});
    };
    // Neither flag sets both, as in bash.
    if (hard or !soft) r.max = new;
    if (soft or !hard) r.cur = new;
    if (!hard and !soft and r.cur > r.max) r.cur = r.max;
    if (std.os.linux.errno(std.os.linux.setrlimit(which.res, &r)) != .SUCCESS) {
        errOut("ulimit: cannot set limit: operation not permitted\n", .{});
        return 1;
    }
    return 0;
}

fn cmdUmask(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    if (argv.len == 1) {
        const old = linux.syscall1(.umask, 0o022);
        _ = linux.syscall1(.umask, old);
        sys.write(1, mem.print("{o:0>4}\n", .{old}));
        return 0;
    }
    const m = std.fmt.parseInt(u32, argv[1], 8) catch return ip.raise(span, "umask: expected an octal mode, got {s}", .{argv[1]});
    if (m > 0o777) return ip.raise(span, "umask: mode out of range: {s}", .{argv[1]});
    _ = linux.syscall1(.umask, m);
    return 0;
}

fn cmdType(ip: *Interp, argv: []const []const u8, span: Span) Error!u8 {
    _ = span;
    var status: u8 = 0;
    for (argv[1..]) |name| {
        if (ip.globals.lookup(name)) |v| {
            if (v.value == .func) {
                sys.write(1, mem.print("{s} is a function\n", .{name}));
                continue;
            }
        }
        if (findCommand(name) != null) {
            sys.write(1, mem.print("{s} is a builtin\n", .{name}));
        } else if (findExecutable(ip, name)) |p| {
            sys.write(1, mem.print("{s} is {s}\n", .{ name, p }));
        } else {
            errOut("type: {s}: not found\n", .{name});
            status = 1;
        }
    }
    return status;
}

// ========================================================= standard library

fn native(comptime name: []const u8, comptime min: u8, comptime max: u8, comptime f: value.NativeFn) value.Native {
    return .{ .name = name, .call = f, .min_args = min, .max_args = max };
}

const many: u8 = 255;

const natives = [_]value.Native{
    native("print", 0, many, nPrint),
    native("printErr", 0, many, nPrintErr),
    native("printf", 1, many, nPrintf),
    native("sprintf", 1, many, nSprintf),
    native("regex", 1, 2, nRegex),
    native("readLine", 0, 1, nReadLine),
    native("readPassword", 0, 1, nReadPassword),
    native("type", 1, 1, nType),
    native("int", 1, 1, nInt),
    native("float", 1, 1, nFloat),
    native("str", 1, 1, nStr),
    native("bool", 1, 1, nBool),
    native("isInstance", 2, 2, nIsInstance),
    native("len", 1, 1, nLen),
    native("push", 2, 2, nPush),
    native("pop", 1, 1, nPop),
    native("keys", 1, 1, nKeys),
    native("values", 1, 1, nValues),
    native("sort", 1, 2, nSort),
    native("map", 2, 2, nMap),
    native("filter", 2, 2, nFilter),
    native("split", 2, 2, nSplit),
    native("join", 2, 2, nJoin),
    native("trim", 1, 1, nTrim),
    native("startsWith", 2, 2, nStartsWith),
    native("endsWith", 2, 2, nEndsWith),
    native("contains", 2, 2, nContains),
    native("replace", 3, 3, nReplace),
    native("upper", 1, 1, nUpper),
    native("lower", 1, 1, nLower),
    native("exists", 1, 1, nExists),
    native("isFile", 1, 1, nIsFile),
    native("isDir", 1, 1, nIsDir),
    native("readFile", 1, 1, nReadFile),
    native("writeFile", 2, 2, nWriteFile),
    native("appendFile", 2, 2, nAppendFile),
    native("baseName", 1, 1, nBaseName),
    native("dirName", 1, 1, nDirName),
    native("glob", 1, 1, nGlob),
    native("cwd", 0, 0, nCwd),
    native("hostName", 0, 0, nHostName),
    native("pid", 0, 0, nPid),
    native("shortPath", 1, 1, nShortPath),
    native("date", 0, 1, nDate),
    native("exit", 0, 1, nExit),
    native("error", 1, 1, nError),
    native("trap", 1, 2, nTrap),
    native("expandPrompt", 1, 1, nExpandPrompt),
    native("kill", 1, 2, nKill),
    native("sleep", 1, 1, nSleep),
    native("now", 0, 0, nNow),
    native("time", 1, 1, nTime),
    native("readLines", 0, 1, nReadLines),
    native("readStdin", 0, 0, nReadStdin),
    native("shellQuote", 1, 1, nShellQuote),
    native("jsonParse", 1, 1, nJsonParse),
    native("jsonStringify", 1, 2, nJsonStringify),
};

pub fn find(name: []const u8) ?*const value.Native {
    for (&natives) |*n| if (std.mem.eql(u8, n.name, name)) return n;
    return null;
}

pub fn nativeNames() []const value.Native {
    return &natives;
}

// ----------------------------------------------------------------- helpers

fn needStr(ip: *Interp, v: Value, span: Span, what: []const u8) Error![]const u8 {
    if (v != .str) return ip.raise(span, "{s} must be a string, got {s}", .{ what, v.typeName() });
    return v.str;
}

fn needInt(ip: *Interp, v: Value, span: Span, what: []const u8) Error!i64 {
    if (v != .int) return ip.raise(span, "{s} must be an int, got {s}", .{ what, v.typeName() });
    return v.int;
}

fn needArray(ip: *Interp, v: Value, span: Span, what: []const u8) Error!*value.Array {
    if (v != .array) return ip.raise(span, "{s} must be an array, got {s}", .{ what, v.typeName() });
    return v.array;
}

fn joinArgs(args: []const Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (args, 0..) |a, i| {
        if (i > 0) buf.append(mem.gpa, ' ') catch {};
        value.display(&buf, a, false);
    }
    buf.append(mem.gpa, '\n') catch {};
    return buf.items;
}

// ------------------------------------------------------------------ output

fn nPrint(ip: *Interp, args: []const Value, span: Span) Error!Value {
    _ = ip;
    _ = span;
    sys.write(1, joinArgs(args));
    return .null_;
}

fn nPrintErr(ip: *Interp, args: []const Value, span: Span) Error!Value {
    _ = ip;
    _ = span;
    sys.write(2, joinArgs(args));
    return .null_;
}

fn nPrintf(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const f = try needStr(ip, args[0], span, "format");
    sys.write(1, try format.sprintf(ip, f, args[1..], span));
    return .null_;
}

fn nSprintf(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const f = try needStr(ip, args[0], span, "format");
    return .{ .str = try format.sprintf(ip, f, args[1..], span) };
}

// ------------------------------------------------------------------- input

fn nReadLine(ip: *Interp, args: []const Value, span: Span) Error!Value {
    if (args.len > 0) sys.write(1, try needStr(ip, args[0], span, "prompt"));
    var line: std.ArrayList(u8) = .empty;
    var b: [1]u8 = undefined;
    var got_any = false;
    while (true) {
        const n = sys.read(0, &b) catch break;
        if (n == 0) break;
        got_any = true;
        if (b[0] == '\n') return .{ .str = line.items };
        line.append(mem.gpa, b[0]) catch @panic("out of memory");
    }
    if (!got_any) return .null_;
    return .{ .str = line.items };
}

fn nReadPassword(ip: *Interp, args: []const Value, span: Span) Error!Value {
    if (args.len > 0) sys.write(2, try needStr(ip, args[0], span, "prompt"));
    var saved: linux.termios = undefined;
    const have_tty = linux.errno(linux.tcgetattr(0, &saved)) == .SUCCESS;
    if (have_tty) {
        var raw = saved;
        raw.lflag.ECHO = false;
        _ = linux.tcsetattr(0, .FLUSH, &raw);
    }
    const v = try nReadLine(ip, &.{}, span);
    if (have_tty) {
        _ = linux.tcsetattr(0, .FLUSH, &saved);
        sys.write(2, "\n");
    }
    return v;
}

// ------------------------------------------------------------------- types

fn nType(ip: *Interp, args: []const Value, span: Span) Error!Value {
    _ = ip;
    _ = span;
    return .{ .str = args[0].typeName() };
}

fn nInt(ip: *Interp, args: []const Value, span: Span) Error!Value {
    switch (args[0]) {
        .int => return args[0],
        .float => |f| {
            if (std.math.isNan(f) or std.math.isInf(f) or f >= 9.3e18 or f <= -9.3e18) return ip.raise(span, "cannot convert {d} to int", .{f});
            return .{ .int = @intFromFloat(f) };
        },
        .bool_ => |b| return .{ .int = @intFromBool(b) },
        .str => |s| {
            const t = std.mem.trim(u8, s, " \t\n");
            const clean = std.mem.replaceOwned(u8, mem.gpa, t, "_", "") catch @panic("out of memory");
            const v = std.fmt.parseInt(i64, clean, 0) catch return ip.raise(span, "cannot convert \"{s}\" to int", .{s});
            return .{ .int = v };
        },
        else => return ip.raise(span, "cannot convert {s} to int", .{args[0].typeName()}),
    }
}

fn nFloat(ip: *Interp, args: []const Value, span: Span) Error!Value {
    switch (args[0]) {
        .float => return args[0],
        .int => |i| return .{ .float = @floatFromInt(i) },
        .str => |s| {
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\n")) catch return ip.raise(span, "cannot convert \"{s}\" to float", .{s});
            return .{ .float = v };
        },
        else => return ip.raise(span, "cannot convert {s} to float", .{args[0].typeName()}),
    }
}

fn nStr(ip: *Interp, args: []const Value, span: Span) Error!Value {
    if (args[0] == .object) {
        const o = args[0].object;
        if (o.class.findMethod("toString")) |m| {
            const r = try ip.callFunc(m, o, &.{}, span);
            if (r != .str) return ip.raise(span, "toString must return a string, got {s}", .{r.typeName()});
            return r;
        }
    }
    return .{ .str = value.toDisplayString(args[0]) };
}

fn nBool(ip: *Interp, args: []const Value, span: Span) Error!Value {
    _ = ip;
    _ = span;
    return .{ .bool_ = switch (args[0]) {
        .null_ => false,
        .bool_ => |b| b,
        .int => |i| i != 0,
        .float => |f| f != 0,
        .str => |s| s.len > 0,
        .array => |a| a.items.items.len > 0,
        .map => |m| m.m.count() > 0,
        else => true,
    } };
}

fn nIsInstance(ip: *Interp, args: []const Value, span: Span) Error!Value {
    if (args[1] != .class) return ip.raise(span, "isInstance needs a class as its second argument, got {s}", .{args[1].typeName()});
    if (args[0] != .object) return .{ .bool_ = false };
    return .{ .bool_ = args[0].object.class.isSubclassOf(args[1].class) };
}

// ------------------------------------------------------------- collections

fn nLen(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .int = @intCast(switch (args[0]) {
        .str => |s| s.len,
        .array => |a| a.items.items.len,
        .map => |m| m.m.count(),
        else => return ip.raise(span, "len() does not apply to {s}", .{args[0].typeName()}),
    }) };
}

fn nPush(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const a = try needArray(ip, args[0], span, "first argument");
    a.items.append(mem.gpa, args[1]) catch @panic("out of memory");
    return .null_;
}

fn nPop(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const a = try needArray(ip, args[0], span, "first argument");
    if (a.items.items.len == 0) return ip.raise(span, "pop() on an empty array", .{});
    return a.items.pop().?;
}

fn nKeys(ip: *Interp, args: []const Value, span: Span) Error!Value {
    if (args[0] != .map) return ip.raise(span, "keys() needs a map, got {s}", .{args[0].typeName()});
    const out = Value.newArray();
    for (args[0].map.m.keys()) |k| out.items.append(mem.gpa, .{ .str = k }) catch @panic("out of memory");
    return .{ .array = out };
}

fn nValues(ip: *Interp, args: []const Value, span: Span) Error!Value {
    if (args[0] != .map) return ip.raise(span, "values() needs a map, got {s}", .{args[0].typeName()});
    const out = Value.newArray();
    for (args[0].map.m.values()) |v| out.items.append(mem.gpa, v) catch @panic("out of memory");
    return .{ .array = out };
}

fn compare(ip: *Interp, a: Value, b: Value, cmp: ?Value, span: Span) Error!i64 {
    if (cmp) |f| {
        const r = try ip.callValue(f, &.{ a, b }, span);
        return switch (r) {
            .int => |i| i,
            .float => |x| if (x < 0) -1 else if (x > 0) @as(i64, 1) else 0,
            else => ip.raise(span, "sort comparison must return an int, got {s}", .{r.typeName()}),
        };
    }
    if (a == .str and b == .str) {
        return switch (std.mem.order(u8, a.str, b.str)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }
    const fa: ?f64 = switch (a) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
    const fb: ?f64 = switch (b) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
    if (a == .int and b == .int) return if (a.int < b.int) -1 else if (a.int > b.int) @as(i64, 1) else 0;
    if (fa != null and fb != null) return if (fa.? < fb.?) -1 else if (fa.? > fb.?) @as(i64, 1) else 0;
    return ip.raise(span, "cannot sort {s} and {s} together without a comparison function", .{ a.typeName(), b.typeName() });
}

fn mergeSort(ip: *Interp, items: []Value, tmp: []Value, cmp: ?Value, span: Span) Error!void {
    if (items.len < 2) return;
    const mid = items.len / 2;
    try mergeSort(ip, items[0..mid], tmp[0..mid], cmp, span);
    try mergeSort(ip, items[mid..], tmp[mid..], cmp, span);
    var i: usize = 0;
    var j: usize = mid;
    var k: usize = 0;
    while (i < mid and j < items.len) : (k += 1) {
        if ((try compare(ip, items[j], items[i], cmp, span)) < 0) {
            tmp[k] = items[j];
            j += 1;
        } else {
            tmp[k] = items[i];
            i += 1;
        }
    }
    while (i < mid) : ({ i += 1; k += 1; }) tmp[k] = items[i];
    while (j < items.len) : ({ j += 1; k += 1; }) tmp[k] = items[j];
    @memcpy(items, tmp[0..items.len]);
}

fn nSort(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const a = try needArray(ip, args[0], span, "first argument");
    const cmp: ?Value = if (args.len > 1 and args[1] != .null_) args[1] else null;
    const out = Value.newArray();
    out.items.appendSlice(mem.gpa, a.items.items) catch @panic("out of memory");
    const tmp = mem.gpa.alloc(Value, out.items.items.len) catch @panic("out of memory");
    try mergeSort(ip, out.items.items, tmp, cmp, span);
    return .{ .array = out };
}

fn nMap(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const a = try needArray(ip, args[0], span, "first argument");
    const out = Value.newArray();
    for (a.items.items) |item| out.items.append(mem.gpa, try ip.callValue(args[1], &.{item}, span)) catch @panic("out of memory");
    return .{ .array = out };
}

fn nFilter(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const a = try needArray(ip, args[0], span, "first argument");
    const out = Value.newArray();
    for (a.items.items) |item| {
        const keep = try ip.callValue(args[1], &.{item}, span);
        if (keep != .bool_) return ip.raise(span, "filter function must return a bool, got {s}", .{keep.typeName()});
        if (keep.bool_) out.items.append(mem.gpa, item) catch @panic("out of memory");
    }
    return .{ .array = out };
}

// ----------------------------------------------------------------- strings

fn nSplit(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const s = try needStr(ip, args[0], span, "first argument");
    const sep = try needStr(ip, args[1], span, "separator");
    const out = Value.newArray();
    if (sep.len == 0) {
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const e = @min(i + n, s.len);
            out.items.append(mem.gpa, .{ .str = s[i..e] }) catch @panic("out of memory");
            i = e;
        }
        return .{ .array = out };
    }
    var it = std.mem.splitSequence(u8, s, sep);
    while (it.next()) |piece| out.items.append(mem.gpa, .{ .str = piece }) catch @panic("out of memory");
    return .{ .array = out };
}

fn nJoin(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const a = try needArray(ip, args[0], span, "first argument");
    const sep = try needStr(ip, args[1], span, "separator");
    var buf: std.ArrayList(u8) = .empty;
    for (a.items.items, 0..) |item, i| {
        if (i > 0) buf.appendSlice(mem.gpa, sep) catch @panic("out of memory");
        value.display(&buf, item, false);
    }
    return .{ .str = buf.items };
}

fn nTrim(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .str = std.mem.trim(u8, try needStr(ip, args[0], span, "argument"), " \t\r\n") };
}

fn nStartsWith(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .bool_ = std.mem.startsWith(u8, try needStr(ip, args[0], span, "first argument"), try needStr(ip, args[1], span, "prefix")) };
}

fn nEndsWith(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .bool_ = std.mem.endsWith(u8, try needStr(ip, args[0], span, "first argument"), try needStr(ip, args[1], span, "suffix")) };
}

fn nContains(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .bool_ = std.mem.indexOf(u8, try needStr(ip, args[0], span, "first argument"), try needStr(ip, args[1], span, "substring")) != null };
}

fn nReplace(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const s = try needStr(ip, args[0], span, "first argument");
    const old = try needStr(ip, args[1], span, "old text");
    const new = try needStr(ip, args[2], span, "new text");
    if (old.len == 0) return ip.raise(span, "replace(): the text to replace must not be empty", .{});
    return .{ .str = std.mem.replaceOwned(u8, mem.gpa, s, old, new) catch @panic("out of memory") };
}

fn nUpper(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .str = std.ascii.allocUpperString(mem.gpa, try needStr(ip, args[0], span, "argument")) catch @panic("out of memory") };
}

fn nLower(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .str = std.ascii.allocLowerString(mem.gpa, try needStr(ip, args[0], span, "argument")) catch @panic("out of memory") };
}

// ------------------------------------------------------------------- files

fn nExists(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .bool_ = sys.kindOf(mem.gpa, try needStr(ip, args[0], span, "path")) != .none };
}

fn nIsFile(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .bool_ = sys.kindOf(mem.gpa, try needStr(ip, args[0], span, "path")) == .file };
}

fn nIsDir(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .bool_ = sys.kindOf(mem.gpa, try needStr(ip, args[0], span, "path")) == .dir };
}

fn nReadFile(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const p = try needStr(ip, args[0], span, "path");
    const data = sys.readFile(mem.gpa, p) catch return ip.raise(span, "cannot read {s}: {s}", .{ p, sys.errnoText() });
    return .{ .str = data };
}

fn nWriteFile(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const p = try needStr(ip, args[0], span, "path");
    const d = try needStr(ip, args[1], span, "contents");
    sys.writeFile(mem.gpa, p, d, false) catch return ip.raise(span, "cannot write {s}: {s}", .{ p, sys.errnoText() });
    return .null_;
}

fn nAppendFile(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const p = try needStr(ip, args[0], span, "path");
    const d = try needStr(ip, args[1], span, "contents");
    sys.writeFile(mem.gpa, p, d, true) catch return ip.raise(span, "cannot append to {s}: {s}", .{ p, sys.errnoText() });
    return .null_;
}

fn nBaseName(ip: *Interp, args: []const Value, span: Span) Error!Value {
    var p = try needStr(ip, args[0], span, "path");
    while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (std.mem.eql(u8, p, "/")) return .{ .str = "/" };
    const i = std.mem.lastIndexOfScalar(u8, p, '/');
    return .{ .str = if (i) |k| p[k + 1 ..] else p };
}

fn nDirName(ip: *Interp, args: []const Value, span: Span) Error!Value {
    var p = try needStr(ip, args[0], span, "path");
    while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return .{ .str = "." };
    if (i == 0) return .{ .str = "/" };
    return .{ .str = p[0..i] };
}

fn nGlob(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const pat = try needStr(ip, args[0], span, "pattern");
    const matches = glob.expand(pat) catch return ip.raise(span, "glob failed: {s}", .{sys.errnoText()});
    const out = Value.newArray();
    for (matches) |m| out.items.append(mem.gpa, .{ .str = m }) catch @panic("out of memory");
    return .{ .array = out };
}

// ------------------------------------------------------------------ system

fn nCwd(ip: *Interp, args: []const Value, span: Span) Error!Value {
    _ = args;
    return .{ .str = sys.getcwd(mem.gpa) catch return ip.raise(span, "cannot read the current directory: {s}", .{sys.errnoText()}) };
}

fn nHostName(ip: *Interp, args: []const Value, span: Span) Error!Value {
    _ = args;
    return .{ .str = sys.hostName(mem.gpa) catch return ip.raise(span, "cannot read the host name", .{}) };
}

fn nPid(ip: *Interp, args: []const Value, span: Span) Error!Value {
    _ = ip;
    _ = args;
    _ = span;
    return .{ .int = sys.getpid() };
}

fn nShortPath(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const p = try needStr(ip, args[0], span, "path");
    if (ip.env_map.get("HOME")) |h| {
        if (h == .str and h.str.len > 1 and std.mem.startsWith(u8, p, h.str) and (p.len == h.str.len or p[h.str.len] == '/')) {
            return .{ .str = mem.print("~{s}", .{p[h.str.len..]}) };
        }
    }
    return .{ .str = p };
}

fn nDate(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const fmt = if (args.len > 0) try needStr(ip, args[0], span, "format") else "%Y-%m-%d %H:%M:%S";
    const ts = sys.unixTime();
    const tz: ?[]const u8 = if (ip.env_map.get("TZ")) |t| (if (t == .str) t.str else null) else null;
    return .{ .str = time.strftime(fmt, time.localCivil(ts, tz), ts) };
}

fn nExit(ip: *Interp, args: []const Value, span: Span) Error!Value {
    var code: u8 = 0;
    if (args.len > 0) code = @truncate(@as(u64, @bitCast(try needInt(ip, args[0], span, "status"))));
    ip.exit_code = code;
    return error.Exit;
}

fn nError(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return ip.raise(span, "{s}", .{value.toDisplayString(args[0])});
}

// ------------------------------------------------- processes, time, signals

fn sigArg(ip: *Interp, v: Value, span: Span) Error!std.os.linux.SIG {
    return switch (v) {
        .int => |i| blk: {
            if (i <= 0 or i >= 32) return ip.raise(span, "signal number out of range: {d}", .{i});
            break :blk @enumFromInt(@as(u32, @intCast(i)));
        },
        .str => |s| signals.parse(s) orelse ip.raise(span, "unknown signal: {s}", .{s}),
        else => ip.raise(span, "a signal is a name or a number, got {s}", .{v.typeName()}),
    };
}

/// trap("INT", fn) runs fn between statements when the signal arrives;
/// trap("EXIT", fn) runs when the shell exits; trap(name) or trap(name, null) resets.
fn nTrap(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const name = try needStr(ip, args[0], span, "signal");
    const handler: Value = if (args.len > 1) args[1] else .null_;
    if (handler != .null_ and handler != .func and handler != .native and handler != .bound) {
        return ip.raise(span, "a trap handler must be a function or null, got {s}", .{handler.typeName()});
    }
    if (std.mem.eql(u8, name, "EXIT")) {
        ip.exit_trap = if (handler == .null_) null else handler;
        return .null_;
    }
    const sig = signals.parse(name) orelse return ip.raise(span, "unknown signal: {s}", .{name});
    if (sig == .KILL or sig == .STOP) return ip.raise(span, "{s} cannot be trapped", .{name});
    const n: u5 = @intCast(@intFromEnum(sig));
    if (handler == .null_) {
        _ = ip.traps.remove(n);
        signals.set(sig, if (ip.interactive and (sig == .INT or sig == .QUIT or sig == .TSTP)) .ignore else .default);
    } else {
        ip.traps.put(mem.gpa, n, handler) catch @panic("out of memory");
        signals.set(sig, .catch_);
    }
    return .null_;
}

/// expandPrompt(template): what PS1/PS2 would show for a template.
fn nExpandPrompt(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .str = prompts.render(ip, try needStr(ip, args[0], span, "template")) };
}

fn nKill(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const pid = try needInt(ip, args[0], span, "pid");
    const sig: std.os.linux.SIG = if (args.len > 1) try sigArg(ip, args[1], span) else .TERM;
    const rc = std.os.linux.kill(@intCast(pid), sig);
    const e = std.os.linux.errno(rc);
    if (e != .SUCCESS) {
        return ip.raise(span, "kill {d}: {s}", .{ pid, if (e == .SRCH) "no such process" else if (e == .PERM) "permission denied" else "failed" });
    }
    return .null_;
}

fn nSleep(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const secs: f64 = switch (args[0]) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => return ip.raise(span, "sleep() needs a number of seconds, got {s}", .{args[0].typeName()}),
    };
    if (secs < 0 or std.math.isNan(secs)) return ip.raise(span, "sleep() needs a non-negative number", .{});
    var req: std.os.linux.timespec = .{ .sec = @intFromFloat(@floor(secs)), .nsec = @intFromFloat((secs - @floor(secs)) * 1e9) };
    var rem: std.os.linux.timespec = undefined;
    // A trapped signal ends the sleep early so its handler runs promptly.
    _ = std.os.linux.nanosleep(&req, &rem);
    return .null_;
}

fn nowSeconds(clock: std.os.linux.clockid_t) f64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(clock, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

fn nNow(ip: *Interp, args: []const Value, span: Span) Error!Value {
    _ = ip;
    _ = args;
    _ = span;
    return .{ .float = nowSeconds(.REALTIME) };
}

/// time(fn): run fn() and return how many seconds it took.
fn nTime(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const start = nowSeconds(.MONOTONIC);
    _ = try ip.callValue(args[0], &.{}, span);
    return .{ .float = nowSeconds(.MONOTONIC) - start };
}

// ------------------------------------------------------------ line reading

fn splitLines(text: []const u8) Value {
    const out = Value.newArray();
    var rest = text;
    if (rest.len == 0) return .{ .array = out };
    if (rest[rest.len - 1] == '\n') rest = rest[0 .. rest.len - 1];
    var it = std.mem.splitScalar(u8, rest, '\n');
    while (it.next()) |l| {
        const line = if (l.len > 0 and l[l.len - 1] == '\r') l[0 .. l.len - 1] else l;
        out.items.append(mem.gpa, .{ .str = line }) catch @panic("out of memory");
    }
    return .{ .array = out };
}

/// readLines(path): the lines of a file ("-" or no argument: standard input).
fn nReadLines(ip: *Interp, args: []const Value, span: Span) Error!Value {
    if (args.len == 0 or (args[0] == .str and std.mem.eql(u8, args[0].str, "-"))) {
        const data = sys.readAll(mem.gpa, 0) catch return ip.raise(span, "cannot read standard input: {s}", .{sys.errnoText()});
        return splitLines(data);
    }
    const p = try needStr(ip, args[0], span, "path");
    const data = sys.readFile(mem.gpa, p) catch return ip.raise(span, "cannot read {s}: {s}", .{ p, sys.errnoText() });
    return splitLines(data);
}

fn nReadStdin(ip: *Interp, args: []const Value, span: Span) Error!Value {
    _ = args;
    return .{ .str = sys.readAll(mem.gpa, 0) catch return ip.raise(span, "cannot read standard input: {s}", .{sys.errnoText()}) };
}

// -------------------------------------------------------- quoting and JSON

/// shellQuote(s): s as one word that sh and dksh both read back unchanged.
pub fn shellQuoteText(s: []const u8) []const u8 {
    var plain = s.len > 0;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_@%+=:,./-", c) != null)) plain = false;
    }
    if (plain) return s;
    var out: std.ArrayList(u8) = .empty;
    out.append(mem.gpa, '\'') catch {};
    for (s) |c| {
        if (c == '\'') out.appendSlice(mem.gpa, "'\\''") catch {} else out.append(mem.gpa, c) catch {};
    }
    out.append(mem.gpa, '\'') catch {};
    return out.items;
}

fn nShellQuote(ip: *Interp, args: []const Value, span: Span) Error!Value {
    return .{ .str = shellQuoteText(try needStr(ip, args[0], span, "argument")) };
}

fn nJsonParse(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const text = try needStr(ip, args[0], span, "argument");
    var failure: json.Failure = undefined;
    return json.parse(text, &failure) orelse ip.raise(span, "invalid JSON at byte {d}: {s}", .{ failure.offset, failure.message });
}

/// jsonStringify(v, indent = 0): compact when indent is 0, else pretty-printed.
fn nJsonStringify(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const indent: usize = if (args.len > 1) blk: {
        const n = try needInt(ip, args[1], span, "indent");
        if (n < 0 or n > 16) return ip.raise(span, "indent must be between 0 and 16", .{});
        break :blk @intCast(n);
    } else 0;
    var out: std.ArrayList(u8) = .empty;
    if (json.stringify(&out, args[0], indent, 0)) |bad| {
        return ip.raise(span, "cannot convert {s} to JSON", .{bad});
    }
    return .{ .str = out.items };
}

// ------------------------------------------------------------------- regex

pub fn regexTest(re: *regex.Regex, s: []const u8) bool {
    return re.search(s, 0) != null;
}

fn nRegex(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const pat = try needStr(ip, args[0], span, "pattern");
    const flags = if (args.len > 1) try needStr(ip, args[1], span, "flags") else "";
    const re = regex.compile(pat, flags) catch return ip.raise(span, "invalid regex: {s}", .{regex.last_error});
    return .{ .regex = re };
}

fn matchMap(re: *regex.Regex, s: []const u8, caps: []const ?[2]usize) Value {
    const m = Value.newMap();
    for (caps, 0..) |c, i| {
        const key = mem.print("{d}", .{i});
        m.put(key, if (c) |r| .{ .str = s[r[0]..r[1]] } else .null_);
    }
    for (re.names) |g| {
        const c = caps[g.index];
        m.put(g.name, if (c) |r| .{ .str = s[r[0]..r[1]] } else .null_);
    }
    m.put("start", .{ .int = @intCast(caps[0].?[0]) });
    m.put("end", .{ .int = @intCast(caps[0].?[1]) });
    return .{ .map = m };
}

fn nextPos(s: []const u8, p: usize) usize {
    if (p >= s.len) return p + 1;
    const n = std.unicode.utf8ByteSequenceLength(s[p]) catch 1;
    return p + n;
}

fn rxTest(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const s = try needStr(ip, args[1], span, "argument");
    return .{ .bool_ = regexTest(args[0].regex, s) };
}

fn rxMatch(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const s = try needStr(ip, args[1], span, "argument");
    const re = args[0].regex;
    const caps = re.search(s, 0) orelse return .null_;
    return matchMap(re, s, caps);
}

fn rxMatchAll(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const s = try needStr(ip, args[1], span, "argument");
    const re = args[0].regex;
    const out = Value.newArray();
    var pos: usize = 0;
    while (pos <= s.len) {
        const caps = re.search(s, pos) orelse break;
        out.items.append(mem.gpa, matchMap(re, s, caps)) catch @panic("out of memory");
        const e = caps[0].?;
        pos = if (e[1] == e[0]) nextPos(s, e[1]) else e[1];
    }
    return .{ .array = out };
}

fn expandReplacement(re: *regex.Regex, s: []const u8, caps: []const ?[2]usize, repl: []const u8, out: *std.ArrayList(u8)) void {
    var i: usize = 0;
    while (i < repl.len) {
        const c = repl[i];
        if (c != '$' or i + 1 >= repl.len) {
            out.append(mem.gpa, c) catch {};
            i += 1;
            continue;
        }
        const n = repl[i + 1];
        if (n == '$') {
            out.append(mem.gpa, '$') catch {};
            i += 2;
        } else if (std.ascii.isDigit(n)) {
            var j = i + 1;
            var idx: usize = 0;
            while (j < repl.len and std.ascii.isDigit(repl[j])) : (j += 1) idx = idx * 10 + (repl[j] - '0');
            if (idx < caps.len) {
                if (caps[idx]) |r| out.appendSlice(mem.gpa, s[r[0]..r[1]]) catch {};
            }
            i = j;
        } else if (n == '{') {
            const close = std.mem.indexOfScalarPos(u8, repl, i + 2, '}') orelse {
                out.append(mem.gpa, '$') catch {};
                i += 1;
                continue;
            };
            const name = repl[i + 2 .. close];
            var idx: ?usize = std.fmt.parseInt(usize, name, 10) catch null;
            if (idx == null) for (re.names) |g| {
                if (std.mem.eql(u8, g.name, name)) idx = g.index;
            };
            if (idx) |k| if (k < caps.len) {
                if (caps[k]) |r| out.appendSlice(mem.gpa, s[r[0]..r[1]]) catch {};
            };
            i = close + 1;
        } else {
            out.append(mem.gpa, '$') catch {};
            i += 1;
        }
    }
}

fn rxReplace(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const s = try needStr(ip, args[1], span, "argument");
    const re = args[0].regex;
    const limit: i64 = if (args.len > 3) try needInt(ip, args[3], span, "count") else 0;
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    var last: usize = 0;
    var count: i64 = 0;
    while (pos <= s.len and (limit == 0 or count < limit)) {
        const caps = re.search(s, pos) orelse break;
        const e = caps[0].?;
        out.appendSlice(mem.gpa, s[last..e[0]]) catch @panic("out of memory");
        switch (args[2]) {
            .str => |r| expandReplacement(re, s, caps, r, &out),
            else => {
                const r = try ip.callValue(args[2], &.{matchMap(re, s, caps)}, span);
                if (r != .str) return ip.raise(span, "replacement function must return a string, got {s}", .{r.typeName()});
                out.appendSlice(mem.gpa, r.str) catch @panic("out of memory");
            },
        }
        last = e[1];
        count += 1;
        if (e[1] == e[0]) {
            const np = nextPos(s, e[1]);
            if (e[1] < s.len) out.appendSlice(mem.gpa, s[e[1..][0]..@min(np, s.len)]) catch @panic("out of memory");
            last = @min(np, s.len);
            pos = np;
        } else pos = e[1];
    }
    if (last < s.len) out.appendSlice(mem.gpa, s[last..]) catch @panic("out of memory");
    return .{ .str = out.items };
}

fn rxSplit(ip: *Interp, args: []const Value, span: Span) Error!Value {
    const s = try needStr(ip, args[1], span, "argument");
    const re = args[0].regex;
    const limit: i64 = if (args.len > 2) try needInt(ip, args[2], span, "limit") else 0;
    const out = Value.newArray();
    var pos: usize = 0;
    var last: usize = 0;
    while (pos <= s.len) {
        if (limit > 0 and out.items.items.len + 1 >= limit) break;
        const caps = re.search(s, pos) orelse break;
        const e = caps[0].?;
        if (e[1] == e[0]) {
            // An empty match splits between characters, never at the ends.
            if (e[0] == 0 or e[0] >= s.len) {
                pos = nextPos(s, e[0]);
                continue;
            }
        }
        out.items.append(mem.gpa, .{ .str = s[last..e[0]] }) catch @panic("out of memory");
        last = e[1];
        pos = if (e[1] == e[0]) nextPos(s, e[1]) else e[1];
    }
    out.items.append(mem.gpa, .{ .str = s[last..] }) catch @panic("out of memory");
    return .{ .array = out };
}

const regex_methods = [_]value.Native{
    native("test", 2, 2, rxTest),
    native("match", 2, 2, rxMatch),
    native("matchAll", 2, 2, rxMatchAll),
    native("replace", 3, 4, rxReplace),
    native("split", 2, 3, rxSplit),
};

pub fn findRegexMethod(name: []const u8) ?*const value.Native {
    for (&regex_methods) |*n| if (std.mem.eql(u8, n.name, name)) return n;
    return null;
}
