//! dksh entry point and run modes (SPEC 4.1).

const std = @import("std");
const mem = @import("mem.zig");
const sys = @import("sys.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const interp = @import("interp.zig");
const Interp = interp.Interp;

const version = @import("build_options").version;

const usage =
    \\usage: dksh [options] [script.dksh args...]
    \\       dksh [options] -c 'source' [args...]
    \\
    \\options (short flags may be combined, e.g. -nx):
    \\  -c source     run the string
    \\  -l            login shell: read the login profile (also when argv[0] starts with '-')
    \\  -i            interactive even if standard input is not a terminal
    \\  -n            parse and resolve only; report errors and warnings, run nothing
    \\  -x            trace: print each command, expanded, to stderr as '+ cmd' before it runs
    \\  -e / +e       failed commands stop the script (the default) / do not
    \\  --dump-ast    parse and resolve, then print the syntax tree instead of running
    \\  --tree        like --dump-ast, but drawn as an ASCII tree
    \\  -v, --version print the version and exit
    \\  -h, --help    print this help and exit
    \\
;

pub fn main(init: std.process.Init.Minimal) u8 {
    @import("gc.zig").init(@frameAddress());
    const argv = init.args.vector;
    const env_block = init.environ.block.slice;
    const environ: []const [*:0]const u8 = @ptrCast(env_block);
    // Testing aid: collect every N allocations to expose missing GC roots.
    for (environ) |e| {
        const s = std.mem.span(e);
        if (std.mem.startsWith(u8, s, "DKSH_GC_STRESS=")) {
            @import("gc.zig").stress = std.fmt.parseInt(usize, s["DKSH_GC_STRESS=".len..], 10) catch 0;
        }
    }

    var login = argv.len > 0 and std.mem.span(argv[0])[0] == '-';
    var check_only = false;
    var dump_ast = false;
    var draw_tree = false;
    var trace = false;
    var errexit = true;
    var force_interactive = false;
    var command: ?[]const u8 = null;
    var script: ?[]const u8 = null;
    var rest: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    var options_done = false;
    while (i < argv.len) : (i += 1) {
        const a: []const u8 = std.mem.span(argv[i]);
        if (script != null or command != null) {
            rest.append(mem.gpa, a) catch return 1;
        } else if (!options_done and std.mem.eql(u8, a, "--")) {
            options_done = true;
        } else if (!options_done and std.mem.eql(u8, a, "--help")) {
            sys.write(1, usage);
            return 0;
        } else if (!options_done and std.mem.eql(u8, a, "--version")) {
            sys.write(1, mem.print("dksh {s} (Unicode {s})\n", .{ version, @import("unicode_tables").version }));
            return 0;
        } else if (!options_done and std.mem.eql(u8, a, "--dump-ast")) {
            dump_ast = true;
        } else if (!options_done and std.mem.eql(u8, a, "--tree")) {
            draw_tree = true;
        } else if (!options_done and a.len > 1 and (a[0] == '-' or a[0] == '+') and a[1] != '-') {
            // Clustered short flags: -nx, -xc 'cmd', +e.
            const on = a[0] == '-';
            for (a[1..]) |f| switch (f) {
                'l' => login = on,
                'n' => check_only = on,
                'x' => trace = on,
                'e' => errexit = on,
                'i' => force_interactive = on,
                'v' => {
                    sys.write(1, mem.print("dksh {s} (Unicode {s})\n", .{ version, @import("unicode_tables").version }));
                    return 0;
                },
                'h' => {
                    sys.write(1, usage);
                    return 0;
                },
                'c' => {
                    if (!on) {
                        sys.write(2, "dksh: +c is not an option\n");
                        return 2;
                    }
                    i += 1;
                    if (i >= argv.len) {
                        sys.write(2, "dksh: -c needs an argument\n");
                        return 2;
                    }
                    command = std.mem.span(argv[i]);
                },
                else => {
                    sys.write(2, mem.print("dksh: unknown option {s}{c}\n{s}", .{ a[0..1], f, usage }));
                    return 2;
                },
            };
        } else if (!options_done and a.len > 1 and a[0] == '-') {
            sys.write(2, mem.print("dksh: unknown option {s}\n{s}", .{ a, usage }));
            return 2;
        } else script = a;
    }

    @import("jobs.zig").restoreSigpipe();
    const ip = Interp.init(rest.items, environ);
    ip.trace = trace;
    ip.errexit = errexit;
    // Login profile first, so every mode sees the environment it sets up. Not
    // for checks (-n, --tree), which must not execute anything.
    if (login and !check_only and !dump_ast and !draw_tree) {
        @import("repl.zig").sourceProfiles(ip);
    }

    if (command) |src| {
        const st = runText(ip, "-c", src, check_only, dump_ast, draw_tree);
        ip.runExitTrap();
        return st;
    }
    if (script) |path| {
        const text = sys.readFile(mem.gpa, path) catch {
            sys.write(2, mem.print("dksh: cannot read {s}: {s}\n", .{ path, sys.errnoText() }));
            return 127;
        };
        if (foreignShebang(ip, path, text, rest.items, check_only or dump_ast or draw_tree)) |st| return st;
        const st = runText(ip, path, text, check_only, dump_ast, draw_tree);
        ip.runExitTrap();
        return st;
    }
    const st = @import("repl.zig").run(ip, login, force_interactive);
    ip.runExitTrap();
    return st;
}

/// A script whose first line is `#!interp [arg]` for something other than dksh
/// belongs to that interpreter (SPEC 1.1: dksh never tries to run sh or bash
/// syntax). Returns the exit status if the script was handed off or refused,
/// null if it is a dksh script.
fn foreignShebang(ip: *Interp, path: []const u8, text: []const u8, rest: []const []const u8, only_check: bool) ?u8 {
    if (!std.mem.startsWith(u8, text, "#!")) return null;
    const eol = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = std.mem.trim(u8, text[2..eol], " \t\r");
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const interp_path = it.next() orelse return null;
    // Linux passes everything after the interpreter as one argument.
    const opt_arg = std.mem.trim(u8, line[@min(line.len, interp_path.len)..], " \t");
    var name = std.fs.path.basename(interp_path);
    if (std.mem.eql(u8, name, "env")) {
        var env_it = std.mem.tokenizeAny(u8, opt_arg, " \t");
        while (env_it.next()) |tok| {
            if (tok[0] == '-' or std.mem.indexOfScalar(u8, tok, '=') != null) continue;
            name = std.fs.path.basename(tok);
            break;
        }
    }
    if (std.mem.eql(u8, name, "dksh")) return null;

    if (only_check) {
        sys.write(2, mem.print("dksh: {s} is a {s} script, not a dksh script; not checked\n", .{ path, name }));
        return 2;
    }
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    const add = struct {
        fn f(list: *std.ArrayList(?[*:0]const u8), s: []const u8) void {
            const z = sys.dupeZ(mem.gpa, s) catch return;
            list.append(mem.gpa, z.ptr) catch {};
        }
    }.f;
    add(&argv, interp_path);
    if (opt_arg.len > 0) add(&argv, opt_arg);
    add(&argv, path);
    for (rest) |a| add(&argv, a);
    argv.append(mem.gpa, null) catch return 1;
    const z = sys.dupeZ(mem.gpa, interp_path) catch return 1;
    const e = sys.execve(z, @ptrCast(argv.items.ptr), @import("builtins.zig").envBlock(ip));
    sys.write(2, mem.print("dksh: cannot run {s} for {s}: {s}\n", .{ interp_path, path, @tagName(e) }));
    return if (e == .NOENT) 127 else 126;
}

fn runText(ip: *Interp, name: []const u8, text: []const u8, check_only: bool, dump_ast: bool, draw_tree: bool) u8 {
    if (check_only or dump_ast or draw_tree) {
        resolver.warn_shadow = true;
        const prog = parser.parseSource(name, text) catch |e| {
            interp.reportParse(e);
            return 2;
        };
        var bad = false;
        for (resolver.resolve(prog.stmts)) |d| {
            sys.write(2, source.render(if (d.warning) "warning" else "error", d.message, d.span));
            if (!d.warning) bad = true;
        }
        if (dump_ast and !bad) sys.write(1, @import("dump.zig").program(prog.stmts));
        if (draw_tree and !bad) sys.write(1, @import("tree.zig").program(prog.stmts));
        return if (bad) 2 else 0;
    }
    return ip.runSource(name, text, ip.globals);
}
