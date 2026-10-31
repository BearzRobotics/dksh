//! Runtime values (SPEC 5.3).

const std = @import("std");
const ast = @import("ast.zig");
const mem = @import("mem.zig");
const regex = @import("regex.zig");
const Interp = @import("interp.zig").Interp;

pub const Error = error{
    /// A dksh error is pending in `Interp.err`.
    Raise,
    Break,
    Continue,
    Return,
    /// `exit` was called; the status is in `Interp.exit_code`.
    Exit,
};

pub const Array = struct {
    items: std.ArrayList(Value) = .empty,
};

pub const Map = struct {
    m: std.StringArrayHashMapUnmanaged(Value) = .empty,

    pub fn get(self: *const Map, key: []const u8) ?Value {
        return self.m.get(key);
    }
    pub fn put(self: *Map, key: []const u8, v: Value) void {
        self.m.put(mem.gpa, key, v) catch @panic("out of memory");
    }
};

pub const Var = struct { value: Value, is_const: bool };

pub const Env = struct {
    vars: std.StringHashMapUnmanaged(Var) = .empty,
    parent: ?*Env = null,

    pub fn create(parent: ?*Env) *Env {
        const e = mem.gpa.create(Env) catch @panic("out of memory");
        e.* = .{ .parent = parent };
        return e;
    }

    pub fn declare(self: *Env, name: []const u8, v: Value, is_const: bool) void {
        self.vars.put(mem.gpa, name, .{ .value = v, .is_const = is_const }) catch @panic("out of memory");
    }

    pub fn lookup(self: *Env, name: []const u8) ?*Var {
        var e: ?*Env = self;
        while (e) |cur| : (e = cur.parent) {
            if (cur.vars.getPtr(name)) |v| return v;
        }
        return null;
    }
};

pub const Func = struct {
    decl: *ast.FnDecl,
    env: *Env,
    /// Class whose method this is (used to resolve `super`).
    owner: ?*Class = null,
    /// Receiver for bound methods.
    self_obj: ?*Object = null,
};

pub const NativeFn = *const fn (ip: *Interp, args: []const Value, span: ast.Span) Error!Value;

pub const Native = struct {
    name: []const u8,
    call: NativeFn,
    min_args: u8,
    max_args: u8,
};

/// A native method with its receiver already attached (`re.test`).
pub const Bound = struct { recv: Value, native: *const Native };

pub const Class = struct {
    name: []const u8,
    parent: ?*Class,
    fields: []const ast.FieldDecl,
    methods: std.StringHashMapUnmanaged(*Func) = .empty,
    env: *Env,

    pub fn findMethod(self: *Class, name: []const u8) ?*Func {
        var c: ?*Class = self;
        while (c) |cur| : (c = cur.parent) {
            if (cur.methods.get(name)) |m| return m;
        }
        return null;
    }

    pub fn isSubclassOf(self: *Class, other: *Class) bool {
        var c: ?*Class = self;
        while (c) |cur| : (c = cur.parent) {
            if (cur == other) return true;
        }
        return false;
    }
};

pub const Object = struct {
    class: *Class,
    fields: std.StringArrayHashMapUnmanaged(Value) = .empty,
};

pub const Value = union(enum) {
    null_,
    bool_: bool,
    int: i64,
    float: f64,
    str: []const u8,
    array: *Array,
    map: *Map,
    func: *Func,
    native: *const Native,
    bound: *Bound,
    regex: *regex.Regex,
    object: *Object,
    class: *Class,

    pub fn newStr(s: []const u8) Value {
        return .{ .str = mem.dupe(s) };
    }

    pub fn newArray() *Array {
        const a = mem.gpa.create(Array) catch @panic("out of memory");
        a.* = .{};
        return a;
    }

    pub fn newMap() *Map {
        const m = mem.gpa.create(Map) catch @panic("out of memory");
        m.* = .{};
        return m;
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .null_ => "null",
            .bool_ => "bool",
            .int => "int",
            .float => "float",
            .str => "string",
            .array => "array",
            .map => "map",
            .func, .native, .bound => "fn",
            .regex => "regex",
            .object => |o| o.class.name,
            .class => "class",
        };
    }
};

pub fn arrayOf(items: []const Value) Value {
    const a = Value.newArray();
    a.items.appendSlice(mem.gpa, items) catch @panic("out of memory");
    return .{ .array = a };
}

/// Shortest string that reads back as the same float (SPEC 7.3).
pub fn formatFloat(buf: *std.ArrayList(u8), f: f64) void {
    if (std.math.isNan(f)) {
        buf.appendSlice(mem.gpa, "nan") catch {};
        return;
    }
    if (std.math.isInf(f)) {
        buf.appendSlice(mem.gpa, if (f < 0) "-inf" else "inf") catch {};
        return;
    }
    const start = buf.items.len;
    buf.print(mem.gpa, "{d}", .{f}) catch {};
    if (std.mem.indexOfScalar(u8, buf.items[start..], '.') == null) buf.appendSlice(mem.gpa, ".0") catch {};
}

/// Text form used by interpolation and `str()`.
pub fn display(buf: *std.ArrayList(u8), v: Value, quote_strings: bool) void {
    switch (v) {
        .null_ => buf.appendSlice(mem.gpa, "null") catch {},
        .bool_ => |b| buf.appendSlice(mem.gpa, if (b) "true" else "false") catch {},
        .int => |i| buf.print(mem.gpa, "{d}", .{i}) catch {},
        .float => |f| formatFloat(buf, f),
        .str => |s| {
            if (quote_strings) {
                buf.append(mem.gpa, '"') catch {};
                buf.appendSlice(mem.gpa, s) catch {};
                buf.append(mem.gpa, '"') catch {};
            } else buf.appendSlice(mem.gpa, s) catch {};
        },
        .array => |a| {
            buf.append(mem.gpa, '[') catch {};
            for (a.items.items, 0..) |item, i| {
                if (i > 0) buf.appendSlice(mem.gpa, ", ") catch {};
                display(buf, item, true);
            }
            buf.append(mem.gpa, ']') catch {};
        },
        .map => |m| {
            buf.append(mem.gpa, '{') catch {};
            var i: usize = 0;
            var it = m.m.iterator();
            while (it.next()) |e| : (i += 1) {
                if (i > 0) buf.appendSlice(mem.gpa, ", ") catch {};
                buf.appendSlice(mem.gpa, e.key_ptr.*) catch {};
                buf.appendSlice(mem.gpa, ": ") catch {};
                display(buf, e.value_ptr.*, true);
            }
            buf.append(mem.gpa, '}') catch {};
        },
        .func => |f| buf.print(mem.gpa, "<fn {s}>", .{if (f.decl.name.len > 0) f.decl.name else "anonymous"}) catch {},
        .native => |n| buf.print(mem.gpa, "<builtin {s}>", .{n.name}) catch {},
        .bound => |b| buf.print(mem.gpa, "<method {s}>", .{b.native.name}) catch {},
        .regex => |r| buf.print(mem.gpa, "<regex {s}>", .{r.pattern}) catch {},
        .object => |o| buf.print(mem.gpa, "<{s} object>", .{o.class.name}) catch {},
        .class => |c| buf.print(mem.gpa, "<class {s}>", .{c.name}) catch {},
    }
}

pub fn toDisplayString(v: Value) []const u8 {
    if (v == .str) return v.str;
    var buf: std.ArrayList(u8) = .empty;
    display(&buf, v, false);
    return buf.items;
}

pub fn equal(a: Value, b: Value) bool {
    switch (a) {
        .null_ => return b == .null_,
        .bool_ => |x| return b == .bool_ and b.bool_ == x,
        .int => |x| return switch (b) {
            .int => |y| x == y,
            .float => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .float => |x| return switch (b) {
            .int => |y| x == @as(f64, @floatFromInt(y)),
            .float => |y| x == y,
            else => false,
        },
        .str => |x| return b == .str and std.mem.eql(u8, x, b.str),
        .array => |x| {
            if (b != .array) return false;
            if (x == b.array) return true;
            if (x.items.items.len != b.array.items.items.len) return false;
            for (x.items.items, b.array.items.items) |p, q| if (!equal(p, q)) return false;
            return true;
        },
        .map => |x| {
            if (b != .map) return false;
            if (x == b.map) return true;
            if (x.m.count() != b.map.m.count()) return false;
            var it = x.m.iterator();
            while (it.next()) |e| {
                const other = b.map.m.get(e.key_ptr.*) orelse return false;
                if (!equal(e.value_ptr.*, other)) return false;
            }
            return true;
        },
        .func => |x| return b == .func and b.func == x,
        .native => |x| return b == .native and b.native == x,
        .bound => |x| return b == .bound and b.bound == x,
        .regex => |x| return b == .regex and b.regex == x,
        .object => |x| return b == .object and b.object == x,
        .class => |x| return b == .class and b.class == x,
    }
}

test "float display is the shortest round-trip text and keeps .0" {
    var buf: std.ArrayList(u8) = .empty;
    inline for (.{ .{ 0.1, "0.1" }, .{ 3.0, "3.0" }, .{ 1.0 / 3.0, "0.3333333333333333" }, .{ -2.5, "-2.5" } }) |c| {
        buf.clearRetainingCapacity();
        formatFloat(&buf, c[0]);
        try std.testing.expectEqualStrings(c[1], buf.items);
    }
}

test "equality: numbers compare across int and float, containers structurally" {
    try std.testing.expect(equal(.{ .int = 1 }, .{ .float = 1.0 }));
    try std.testing.expect(!equal(.{ .int = 1 }, .{ .str = "1" }));
    const a = arrayOf(&.{ .{ .int = 1 }, .{ .str = "x" } });
    const b = arrayOf(&.{ .{ .int = 1 }, .{ .str = "x" } });
    try std.testing.expect(equal(a, b));
}
