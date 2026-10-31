//! Thin, libc-free wrappers over Linux system calls (SPEC 4.2).
//!
//! Everything returns Zig errors or plain values so the rest of dksh never
//! touches raw `usize` syscall results or errno decoding.

const std = @import("std");
const linux = std.os.linux;

pub const fd_t = linux.fd_t;
pub const pid_t = linux.pid_t;

pub const Error = error{SysError};

/// Last errno seen by a failing wrapper, for building messages.
pub var last_errno: linux.E = .SUCCESS;

fn check(rc: usize) Error!usize {
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        last_errno = e;
        return error.SysError;
    }
    return rc;
}

/// Human text for the errno stored by the last failing call.
pub fn errnoText() []const u8 {
    return switch (last_errno) {
        .NOENT => "No such file or directory",
        .ACCES => "Permission denied",
        .NOTDIR => "Not a directory",
        .ISDIR => "Is a directory",
        .EXIST => "File exists",
        .INVAL => "Invalid argument",
        .NOEXEC => "Exec format error",
        .NOMEM => "Out of memory",
        .PIPE => "Broken pipe",
        .MFILE => "Too many open files",
        .NOTEMPTY => "Directory not empty",
        else => "System error",
    };
}

/// Make a NUL-terminated copy of `s` in `gpa`.
pub fn dupeZ(gpa: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const out = try gpa.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out;
}

pub fn write(fd: fd_t, data: []const u8) void {
    var rest = data;
    while (rest.len > 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return;
        rest = rest[rc..];
    }
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        if (linux.errno(rc) == .INTR) continue;
        return check(rc);
    }
}

pub fn open(gpa: std.mem.Allocator, path: []const u8, flags: linux.O, mode: linux.mode_t) !fd_t {
    const z = try dupeZ(gpa, path);
    defer gpa.free(z);
    const rc = try check(linux.open(z.ptr, flags, mode));
    return @intCast(rc);
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn dup2(old: fd_t, new: fd_t) Error!void {
    _ = try check(linux.dup2(old, new));
}

pub fn dup(old: fd_t) Error!fd_t {
    return @intCast(try check(linux.dup(old)));
}

pub fn pipe() Error![2]fd_t {
    var fds: [2]fd_t = undefined;
    _ = try check(linux.pipe2(&fds, .{ .CLOEXEC = true }));
    return fds;
}

/// Clear close-on-exec on `fd` so a child keeps it.
pub fn setInheritable(fd: fd_t) void {
    _ = linux.fcntl(fd, linux.F.SETFD, 0);
}

pub fn fork() Error!pid_t {
    return @intCast(try check(linux.fork()));
}

pub fn exit(status: u8) noreturn {
    linux.exit_group(status);
}

pub fn getpid() pid_t {
    return linux.getpid();
}

pub fn setpgid(pid: pid_t, pgid: pid_t) void {
    _ = linux.setpgid(pid, pgid);
}

pub const WaitResult = struct { pid: pid_t, status: u32 };

/// Wait for `pid` (or any child with -1). Retries on EINTR.
pub fn waitpid(pid: pid_t, flags: u32) Error!WaitResult {
    while (true) {
        var st: i32 = 0;
        const rc = linux.waitpid(pid, &st, flags);
        if (linux.errno(rc) == .INTR) continue;
        const r = try check(rc);
        return .{ .pid = @intCast(r), .status = @bitCast(st) };
    }
}

/// Decode a wait status into a shell exit status (128+sig for signals).
pub fn exitStatus(status: u32) u8 {
    if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
    if (linux.W.IFSIGNALED(status)) return 128 +% @as(u8, @intCast(@intFromEnum(linux.W.TERMSIG(status))));
    if (linux.W.IFSTOPPED(status)) return 128 +% @as(u8, @intCast(@intFromEnum(linux.W.STOPSIG(status))));
    return 1;
}

/// execve; only returns on failure, with the errno stored.
pub fn execve(path: [:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) linux.E {
    return linux.errno(linux.execve(path.ptr, argv, envp));
}

pub fn chdir(gpa: std.mem.Allocator, path: []const u8) !void {
    const z = try dupeZ(gpa, path);
    defer gpa.free(z);
    _ = try check(linux.chdir(z.ptr));
}

pub fn getcwd(gpa: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = try check(linux.getcwd(&buf, buf.len));
    // The kernel returns the length including the NUL.
    return gpa.dupe(u8, buf[0 .. n - 1]);
}

pub const Kind = enum { none, file, dir, other };

pub fn kindOf(gpa: std.mem.Allocator, path: []const u8) Kind {
    const z = dupeZ(gpa, path) catch return .none;
    defer gpa.free(z);
    var sx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z.ptr, 0, .{ .TYPE = true }, &sx);
    if (linux.errno(rc) != .SUCCESS) return .none;
    return switch (sx.mode & linux.S.IFMT) {
        linux.S.IFDIR => .dir,
        linux.S.IFREG => .file,
        else => .other,
    };
}

/// True when `path` is a regular file with any execute bit and we may run it.
pub fn isExecutable(gpa: std.mem.Allocator, path: []const u8) bool {
    if (kindOf(gpa, path) != .file) return false;
    const z = dupeZ(gpa, path) catch return false;
    defer gpa.free(z);
    return linux.errno(linux.access(z.ptr, 1)) == .SUCCESS;
}

pub fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try open(gpa, path, .{ .CLOEXEC = true }, 0);
    defer close(fd);
    return readAll(gpa, fd);
}

pub fn readAll(gpa: std.mem.Allocator, fd: fd_t) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try read(fd, &buf);
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

pub fn writeFile(gpa: std.mem.Allocator, path: []const u8, data: []const u8, append: bool) !void {
    const fd = try open(gpa, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = !append, .APPEND = append, .CLOEXEC = true }, 0o666);
    defer close(fd);
    write(fd, data);
}

/// Names in directory `path` (no "." or ".."), unsorted.
pub fn listDir(gpa: std.mem.Allocator, path: []const u8) ![][]u8 {
    const fd = try open(gpa, path, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    defer close(fd);
    var names: std.ArrayList([]u8) = .empty;
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = try check(linux.getdents64(fd, &buf, buf.len));
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")])), 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                try names.append(gpa, try gpa.dupe(u8, name));
            }
            off += d.reclen;
        }
    }
    return names.toOwnedSlice(gpa);
}

pub fn hostName(gpa: std.mem.Allocator) ![]u8 {
    var u: linux.utsname = undefined;
    _ = try check(linux.uname(&u));
    return gpa.dupe(u8, std.mem.sliceTo(&u.nodename, 0));
}

pub fn getuid() u32 {
    return linux.getuid();
}

pub fn unixTime() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

pub fn isatty(fd: fd_t) bool {
    var t: linux.termios = undefined;
    return linux.errno(linux.tcgetattr(fd, &t)) == .SUCCESS;
}

/// Home directory of `name`, from /etc/passwd.
pub fn homeOf(name: []const u8) ?[]const u8 {
    const data = readFile(mem_gpa(), "/etc/passwd") catch return null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const n = f.next() orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        _ = f.next();
        _ = f.next();
        _ = f.next();
        _ = f.next();
        return f.next();
    }
    return null;
}

/// User name for `uid`, from /etc/passwd.
pub fn userNameOf(uid: u32) ?[]const u8 {
    const data = readFile(mem_gpa(), "/etc/passwd") catch return null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const n = f.next() orelse continue;
        _ = f.next();
        const id = f.next() orelse continue;
        if ((std.fmt.parseInt(u32, id, 10) catch continue) == uid) return n;
    }
    return null;
}

fn mem_gpa() std.mem.Allocator {
    return @import("mem.zig").gpa;
}
