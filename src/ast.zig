//! Syntax tree. Every node carries a `Span` so errors can point at source.

const std = @import("std");

/// Byte range inside one loaded source file (`file` indexes `source.files`).
pub const Span = struct {
    file: u16 = 0,
    start: u32 = 0,
    end: u32 = 0,

    pub fn join(a: Span, b: Span) Span {
        return .{ .file = a.file, .start = a.start, .end = @max(a.end, b.end) };
    }
};

// ---------------------------------------------------------------- expressions

pub const BinOp = enum { add, sub, mul, div, mod, lt, le, gt, ge, eq, ne, match, nomatch, in, and_, or_ };
pub const UnOp = enum { not, neg };

pub const StrPart = union(enum) {
    lit: []const u8,
    expr: *Expr,
};

pub const MapEntry = struct { key: *Expr, value: *Expr };

pub const Expr = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        null_,
        bool_: bool,
        int: i64,
        float: f64,
        str: []const StrPart,
        ident: []const u8,
        array: []const *Expr,
        map: []const MapEntry,
        unary: struct { op: UnOp, e: *Expr },
        binary: struct { op: BinOp, l: *Expr, r: *Expr },
        ternary: struct { c: *Expr, a: *Expr, b: *Expr },
        call: struct { callee: *Expr, args: []const *Expr },
        index: struct { obj: *Expr, idx: *Expr },
        member: struct { obj: *Expr, name: []const u8 },
        fn_: *FnDecl,
        /// `$(cmd)` (lines=false) or `@(cmd)` (lines=true).
        cmd_sub: struct { list: *CommandList, lines: bool },
        /// `status(cmd)`.
        status: *CommandList,
    };
};

// ------------------------------------------------------------------- commands

pub const WordPart = union(enum) {
    /// Literal text. `quoted` text is never globbed.
    text: struct { s: []const u8, quoted: bool },
    /// `$name` or `$name.field...` in command mode.
    var_: struct { name: []const u8, fields: []const []const u8 },
    /// `${expr}` / interpolation inside quotes.
    expr: *Expr,
    /// `$(cmd)` or `@(cmd)` (lines splice into several arguments).
    cmd_sub: struct { list: *CommandList, lines: bool },
    /// `@name` splice of an array.
    splice: *Expr,
    /// `~` or `~user`.
    tilde: []const u8,
};

pub const Word = struct {
    span: Span,
    parts: []const WordPart,
};

pub const RedirKind = enum { out, append, in, err, err_append, both, err_to_out, here_string };

pub const Redirect = struct {
    kind: RedirKind,
    target: ?Word,
    span: Span,
};

pub const Command = struct {
    span: Span,
    words: []const Word,
    redirs: []const Redirect,
};

pub const Pipeline = struct {
    span: Span,
    cmds: []const Command,
};

pub const Chain = struct { and_: bool, p: Pipeline };

pub const CommandList = struct {
    span: Span,
    first: Pipeline,
    rest: []const Chain,
    background: bool,
};

// ----------------------------------------------------------------- statements

pub const Param = struct { name: []const u8, default: ?*Expr };

pub const FnDecl = struct {
    span: Span,
    name: []const u8,
    params: []const Param,
    body: []const Stmt,
};

pub const FieldDecl = struct { name: []const u8, init: *Expr, span: Span };

pub const ClassDecl = struct {
    span: Span,
    name: []const u8,
    parent: ?[]const u8,
    fields: []const FieldDecl,
    methods: []const *FnDecl,
};

pub const Cond = union(enum) {
    expr: *Expr,
    cmd: *CommandList,
};

pub const AssignOp = enum { set, add, sub, mul, div, inc, dec };

pub const Stmt = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        var_decl: struct { name: []const u8, is_const: bool, init: *Expr },
        assign: struct { target: *Expr, op: AssignOp, value: ?*Expr },
        if_: struct { cond: Cond, then: []const Stmt, else_: ?[]const Stmt },
        while_: struct { cond: Cond, body: []const Stmt },
        for_in: struct { name: []const u8, iter: *Expr, body: []const Stmt },
        for_c: struct { init: ?*const Stmt, cond: ?*Expr, step: ?*const Stmt, body: []const Stmt },
        fn_decl: *FnDecl,
        class_decl: *ClassDecl,
        return_: ?*Expr,
        break_,
        continue_,
        try_: struct { body: []const Stmt, name: []const u8, handler: ?[]const Stmt, finally_: ?[]const Stmt },
        subshell: []const Stmt,
        import: struct { path: []const u8, alias: []const u8 },
        expr: *Expr,
        command: *CommandList,
        block: []const Stmt,
    };
};
