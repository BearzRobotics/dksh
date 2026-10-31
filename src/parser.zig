//! Recursive-descent parser for both command mode and expression mode
//! (SPEC 5.1). The lexer is folded into the parser because the two modes
//! tokenize the same bytes differently and only the parser knows which applies.

const std = @import("std");
const ast = @import("ast.zig");
const mem = @import("mem.zig");
const source = @import("source.zig");
const Span = ast.Span;
const Expr = ast.Expr;
const Stmt = ast.Stmt;

pub const ParseError = error{
    /// The source is wrong; `diag` explains where.
    Parse,
    /// The source ended inside an open construct (used by the line editor to
    /// keep reading on the next line).
    Incomplete,
};

pub const Diag = struct { message: []const u8, span: Span };

/// Set whenever a ParseError is returned.
pub var diag: Diag = .{ .message = "", .span = .{} };

const keywords = [_][]const u8{
    "var", "const", "if", "while", "for", "fn", "class", "return", "break", "continue", "try", "import", "subshell",
};

fn oom() noreturn {
    @panic("out of memory");
}

/// Names already declared in the global scope by earlier input (interactive
/// lines and `source`), so a later line can assign to them.
pub var global_names: std.StringHashMapUnmanaged(void) = .empty;

pub const Parser = struct {
    src: []const u8,
    file: u16,
    pos: usize = 0,
    /// Open `(` `[` `{` in expression mode: newlines are insignificant there.
    nest: u32 = 0,
    scopes: std.ArrayList(std.StringHashMapUnmanaged(void)) = .empty,

    pub fn init(file: u16) Parser {
        var p: Parser = .{ .src = source.get(file).text, .file = file };
        p.pushScope();
        p.declare("env");
        p.declare("args");
        var it = global_names.keyIterator();
        while (it.next()) |k| p.declare(k.*);
        return p;
    }

    // ------------------------------------------------------------ scopes

    pub fn pushScope(p: *Parser) void {
        p.scopes.append(mem.gpa, .empty) catch oom();
    }
    fn popScope(p: *Parser) void {
        _ = p.scopes.pop();
    }
    pub fn declare(p: *Parser, name: []const u8) void {
        p.scopes.items[p.scopes.items.len - 1].put(mem.gpa, name, {}) catch oom();
    }
    fn isDeclared(p: *Parser, name: []const u8) bool {
        var i = p.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (p.scopes.items[i].contains(name)) return true;
        }
        return false;
    }

    // ------------------------------------------------------------ errors

    fn span(p: *Parser, start: usize) Span {
        return .{ .file = p.file, .start = @intCast(start), .end = @intCast(@max(p.pos, start)) };
    }

    fn fail(p: *Parser, where: usize, comptime fmt: []const u8, args: anytype) ParseError {
        const end = @min(p.src.len, where + 1);
        diag = .{ .message = mem.print(fmt, args), .span = .{ .file = p.file, .start = @intCast(where), .end = @intCast(@max(end, where)) } };
        if (where >= p.src.len) return error.Incomplete;
        return error.Parse;
    }

    // ----------------------------------------------------------- scanning

    /// Leave one level of expression nesting (saturating: errors may unwind early).
    fn dec(p: *Parser) void {
        if (p.nest > 0) p.nest -= 1;
    }

    fn eof(p: *Parser) bool {
        return p.pos >= p.src.len;
    }
    fn peekc(p: *Parser) u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else 0;
    }
    fn at(p: *Parser, off: usize) u8 {
        return if (p.pos + off < p.src.len) p.src[p.pos + off] else 0;
    }
    fn startsWith(p: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.pos..], s);
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }
    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Spaces, tabs, line continuations and comments; newlines only when
    /// `nest > 0`.
    fn skipWs(p: *Parser) void {
        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                p.pos += 1;
            } else if (c == '\\' and p.at(1) == '\n') {
                p.pos += 2;
            } else if (c == '#') {
                while (p.pos < p.src.len and p.src[p.pos] != '\n') p.pos += 1;
            } else if (c == '\n' and p.nest > 0) {
                p.pos += 1;
            } else break;
        }
    }

    /// Whitespace, newlines and `;` (statement separators).
    fn skipTerms(p: *Parser) void {
        while (true) {
            p.skipWs();
            if (p.pos < p.src.len and (p.src[p.pos] == '\n' or p.src[p.pos] == ';')) p.pos += 1 else break;
        }
    }

    fn skipNewlines(p: *Parser) void {
        while (true) {
            p.skipWs();
            if (p.pos < p.src.len and p.src[p.pos] == '\n') p.pos += 1 else break;
        }
    }

    fn expect(p: *Parser, c: u8) ParseError!void {
        p.skipWs();
        if (p.peekc() != c or p.eof()) {
            if (p.eof()) return p.fail(p.pos, "unexpected end of input, expected '{c}'", .{c});
            return p.fail(p.pos, "expected '{c}'", .{c});
        }
        p.pos += 1;
    }

    fn readIdent(p: *Parser) ?[]const u8 {
        if (!isIdentStart(p.peekc())) return null;
        const s = p.pos;
        while (p.pos < p.src.len and isIdentChar(p.src[p.pos])) p.pos += 1;
        return p.src[s..p.pos];
    }

    /// Peek an identifier without consuming it.
    fn peekIdent(p: *Parser) ?[]const u8 {
        const save = p.pos;
        defer p.pos = save;
        return p.readIdent();
    }

    fn isKeyword(name: []const u8) bool {
        for (keywords) |k| if (std.mem.eql(u8, k, name)) return true;
        return false;
    }

    fn newExpr(p: *Parser, start: usize, kind: Expr.Kind) *Expr {
        const e = mem.gpa.create(Expr) catch oom();
        e.* = .{ .span = p.span(start), .kind = kind };
        return e;
    }

    // --------------------------------------------------------- statements

    /// Parse a whole file.
    pub fn parseProgram(p: *Parser) ParseError![]const Stmt {
        var list: std.ArrayList(Stmt) = .empty;
        while (true) {
            p.skipTerms();
            if (p.eof()) break;
            if (p.peekc() == '}') return p.fail(p.pos, "unmatched '}}'", .{});
            const st = try p.parseStmt();
            list.append(mem.gpa, st) catch oom();
            if (!endsWithBlock(st)) try p.endStmt();
        }
        return list.items;
    }

    /// Statements that end in `}` need no separator before the next one.
    fn endsWithBlock(s: Stmt) bool {
        return switch (s.kind) {
            .if_, .while_, .for_in, .for_c, .fn_decl, .class_decl, .try_, .block, .subshell => true,
            else => false,
        };
    }

    fn endStmt(p: *Parser) ParseError!void {
        p.skipWs();
        if (p.eof()) return;
        switch (p.peekc()) {
            '\n', ';', '}' => return,
            else => return p.fail(p.pos, "unexpected '{c}', expected end of statement", .{p.peekc()}),
        }
    }

    fn parseBlock(p: *Parser) ParseError![]const Stmt {
        p.skipNewlines();
        const open = p.pos;
        try p.expect('{');
        p.pushScope();
        defer p.popScope();
        return p.parseBlockBody(open);
    }

    /// Report an unfinished construct at its opening token; the line editor
    /// still sees `Incomplete` and asks for another line.
    fn unclosed(p: *Parser, open: usize, what: []const u8) ParseError {
        diag = .{ .message = mem.print("unclosed {s}", .{what}), .span = .{ .file = p.file, .start = @intCast(open), .end = @intCast(open + 1) } };
        return error.Incomplete;
    }

    /// Statements up to and including the closing `}`.
    fn parseBlockBody(p: *Parser, open: usize) ParseError![]const Stmt {
        var list: std.ArrayList(Stmt) = .empty;
        while (true) {
            p.skipTerms();
            if (p.eof()) return p.unclosed(open, "'{'");
            if (p.peekc() == '}') {
                p.pos += 1;
                return list.items;
            }
            const st = try p.parseStmt();
            list.append(mem.gpa, st) catch oom();
            if (!endsWithBlock(st)) try p.endStmt();
        }
    }

    fn kwFollowedBy(p: *Parser, len: usize) u8 {
        return p.at(len);
    }

    fn parseStmt(p: *Parser) ParseError!Stmt {
        const start = p.pos;
        if (p.peekIdent()) |id| {
            const after = p.kwFollowedBy(id.len);
            const spaced = after == ' ' or after == '\t';
            if (std.mem.eql(u8, id, "var") and spaced) return p.parseVarDecl(false);
            if (std.mem.eql(u8, id, "const") and spaced) return p.parseVarDecl(true);
            if (std.mem.eql(u8, id, "if") and (spaced or after == '(')) return p.parseIf();
            if (std.mem.eql(u8, id, "while") and (spaced or after == '(')) return p.parseWhile();
            if (std.mem.eql(u8, id, "for") and (spaced or after == '(')) return p.parseFor();
            if (std.mem.eql(u8, id, "fn") and spaced) return p.parseFnStmt();
            if (std.mem.eql(u8, id, "class") and spaced) return p.parseClass();
            if (std.mem.eql(u8, id, "return") and (spaced or after == 0 or after == '\n' or after == ';' or after == '}')) return p.parseReturn();
            if (std.mem.eql(u8, id, "break") and !isIdentChar(after) and after != '-') {
                p.pos += id.len;
                return .{ .span = p.span(start), .kind = .break_ };
            }
            if (std.mem.eql(u8, id, "continue") and !isIdentChar(after) and after != '-') {
                p.pos += id.len;
                return .{ .span = p.span(start), .kind = .continue_ };
            }
            if (std.mem.eql(u8, id, "try") and (spaced or after == '{' or after == '\n')) return p.parseTry();
            if (std.mem.eql(u8, id, "import") and spaced) return p.parseImport();
            if (std.mem.eql(u8, id, "subshell") and (spaced or after == '{' or after == '\n')) {
                p.pos += id.len;
                const body = try p.parseBlock();
                return .{ .span = p.span(start), .kind = .{ .subshell = body } };
            }

            // A name immediately followed by '(' is a function call.
            if (after == '(') return p.parseExprStmt();

            const declared = p.isDeclared(id) or std.mem.eql(u8, id, "self") or std.mem.eql(u8, id, "super");
            if (declared) {
                // Assignment, member/index assignment or method call.
                const save = p.pos;
                p.pos += id.len;
                var q = p.pos;
                while (q < p.src.len and (p.src[q] == ' ' or p.src[q] == '\t')) q += 1;
                const c = if (q < p.src.len) p.src[q] else 0;
                p.pos = save;
                const c1 = if (q + 1 < p.src.len) p.src[q + 1] else 0;
                const is_assign = (c == '=' and c1 != '=' and c1 != '~') or
                    ((c == '+' or c == '-' or c == '*' or c == '/') and (c1 == '=' or (c1 == c and (c == '+' or c == '-'))));
                if (is_assign or ((c == '.' or c == '[') and q == p.pos + id.len)) return p.parseAssignOrCall();
            } else if (!isKeyword(id)) {
                // `x = 5` with x undeclared must not silently become a command.
                var q = p.pos + id.len;
                while (q < p.src.len and (p.src[q] == ' ' or p.src[q] == '\t')) q += 1;
                const c = if (q < p.src.len) p.src[q] else 0;
                const c1 = if (q + 1 < p.src.len) p.src[q + 1] else 0;
                const is_assign = (c == '=' and c1 != '=' and c1 != '~') or
                    ((c == '+' or c == '-' or c == '*' or c == '/') and c1 == '=');
                if (is_assign) {
                    if (c == '=') {
                        var e = q + 1;
                        while (e < p.src.len and p.src[e] != '\n' and p.src[e] != ';') e += 1;
                        const rhs = std.mem.trim(u8, p.src[q + 1 .. e], " \t");
                        return p.fail(start, "`{s}` is not declared; use `var {s} = {s}`", .{ id, id, rhs });
                    }
                    return p.fail(start, "`{s}` is not declared", .{id});
                }
            }
        }
        const cl = try p.parseCommandList(false);
        return .{ .span = cl.span, .kind = .{ .command = cl } };
    }

    fn parseVarDecl(p: *Parser, is_const: bool) ParseError!Stmt {
        const start = p.pos;
        p.pos += if (is_const) 5 else 3;
        p.skipWs();
        const name = p.readIdent() orelse return p.fail(p.pos, "expected a variable name", .{});
        try p.expectEquals();
        const init_expr = try p.parseExpr();
        p.declare(name);
        return .{ .span = p.span(start), .kind = .{ .var_decl = .{ .name = name, .is_const = is_const, .init = init_expr } } };
    }

    fn expectEquals(p: *Parser) ParseError!void {
        p.skipWs();
        if (p.peekc() != '=' or p.at(1) == '=') return p.fail(p.pos, "a declaration needs an initial value: expected '='", .{});
        p.pos += 1;
        p.skipWs();
        if (p.eof() or p.peekc() == '\n') return p.fail(p.pos, "expected an expression after '='", .{});
    }

    fn parseCond(p: *Parser) ParseError!ast.Cond {
        p.skipWs();
        if (p.peekc() == '(') {
            p.pos += 1;
            p.nest += 1;
            const e = try p.parseExpr();
            p.skipWs();
            p.dec();
            try p.expect(')');
            return .{ .expr = e };
        }
        return .{ .cmd = try p.parseCommandList(true) };
    }

    fn parseIf(p: *Parser) ParseError!Stmt {
        const start = p.pos;
        p.pos += 2;
        const cond = try p.parseCond();
        const then = try p.parseBlock();
        var else_: ?[]const Stmt = null;
        const save = p.pos;
        p.skipNewlines();
        if (p.peekIdent()) |id| {
            if (std.mem.eql(u8, id, "else")) {
                p.pos += 4;
                p.skipWs();
                if (p.peekIdent()) |nx| {
                    if (std.mem.eql(u8, nx, "if")) {
                        const inner = try p.parseIf();
                        const one = mem.gpa.alloc(Stmt, 1) catch oom();
                        one[0] = inner;
                        else_ = one;
                    }
                }
                if (else_ == null) else_ = try p.parseBlock();
            } else p.pos = save;
        } else p.pos = save;
        return .{ .span = p.span(start), .kind = .{ .if_ = .{ .cond = cond, .then = then, .else_ = else_ } } };
    }

    fn parseWhile(p: *Parser) ParseError!Stmt {
        const start = p.pos;
        p.pos += 5;
        const cond = try p.parseCond();
        const body = try p.parseBlock();
        return .{ .span = p.span(start), .kind = .{ .while_ = .{ .cond = cond, .body = body } } };
    }

    fn parseFor(p: *Parser) ParseError!Stmt {
        const start = p.pos;
        p.pos += 3;
        p.skipWs();
        try p.expect('(');
        p.pushScope();
        defer p.popScope();
        p.nest += 1;
        defer p.dec();
        p.skipWs();
        // for (name in expr)
        if (p.peekIdent()) |id| {
            const save = p.pos;
            p.pos += id.len;
            p.skipWs();
            if (p.peekIdent()) |kw| {
                if (std.mem.eql(u8, kw, "in") and !isKeyword(id)) {
                    p.pos += 2;
                    const iter = try p.parseExpr();
                    p.skipWs();
                    p.dec();
                    try p.expect(')');
                    p.nest += 1;
                    p.declare(id);
                    p.dec();
                    const body = try p.parseBlock();
                    p.nest += 1;
                    return .{ .span = p.span(start), .kind = .{ .for_in = .{ .name = id, .iter = iter, .body = body } } };
                }
            }
            p.pos = save;
        }
        var init_stmt: ?*const Stmt = null;
        p.skipWs();
        if (p.peekc() != ';') {
            const s = mem.gpa.create(Stmt) catch oom();
            s.* = try p.parseSimple();
            init_stmt = s;
        }
        try p.expect(';');
        p.skipWs();
        var cond: ?*Expr = null;
        if (p.peekc() != ';') cond = try p.parseExpr();
        try p.expect(';');
        p.skipWs();
        var step: ?*const Stmt = null;
        if (p.peekc() != ')') {
            const s = mem.gpa.create(Stmt) catch oom();
            s.* = try p.parseSimple();
            step = s;
        }
        p.skipWs();
        p.dec();
        try p.expect(')');
        p.nest += 1;
        p.dec();
        const body = try p.parseBlock();
        p.nest += 1;
        return .{ .span = p.span(start), .kind = .{ .for_c = .{ .init = init_stmt, .cond = cond, .step = step, .body = body } } };
    }

    /// A declaration or assignment inside a `for (...)` header.
    fn parseSimple(p: *Parser) ParseError!Stmt {
        if (p.peekIdent()) |id| {
            if (std.mem.eql(u8, id, "var")) return p.parseVarDecl(false);
            if (std.mem.eql(u8, id, "const")) return p.parseVarDecl(true);
        }
        return p.parseAssignOrCall();
    }

    fn parseParams(p: *Parser) ParseError![]const ast.Param {
        try p.expect('(');
        p.nest += 1;
        defer p.dec();
        var list: std.ArrayList(ast.Param) = .empty;
        p.skipWs();
        while (p.peekc() != ')') {
            p.skipWs();
            const name = p.readIdent() orelse return p.fail(p.pos, "expected a parameter name", .{});
            p.skipWs();
            var def: ?*Expr = null;
            if (p.peekc() == '=') {
                p.pos += 1;
                def = try p.parseExpr();
            }
            list.append(mem.gpa, .{ .name = name, .default = def }) catch oom();
            p.skipWs();
            if (p.peekc() == ',') {
                p.pos += 1;
                p.skipWs();
            } else break;
        }
        p.dec();
        try p.expect(')');
        p.nest += 1;
        return list.items;
    }

    fn parseFnRest(p: *Parser, start: usize, name: []const u8, is_method: bool) ParseError!*ast.FnDecl {
        p.pushScope();
        defer p.popScope();
        if (is_method) {
            p.declare("self");
            p.declare("super");
        }
        const params = try p.parseParams();
        for (params) |prm| p.declare(prm.name);
        const saved_nest = p.nest;
        p.nest = 0;
        defer p.nest = saved_nest;
        const body = try p.parseBlock();
        const d = mem.gpa.create(ast.FnDecl) catch oom();
        d.* = .{ .span = p.span(start), .name = name, .params = params, .body = body };
        return d;
    }

    fn parseFnStmt(p: *Parser) ParseError!Stmt {
        const start = p.pos;
        p.pos += 2;
        p.skipWs();
        const name = p.readIdent() orelse return p.fail(p.pos, "expected a function name", .{});
        p.declare(name);
        const d = try p.parseFnRest(start, name, false);
        return .{ .span = p.span(start), .kind = .{ .fn_decl = d } };
    }

    fn parseClass(p: *Parser) ParseError!Stmt {
        const start = p.pos;
        p.pos += 5;
        p.skipWs();
        const name = p.readIdent() orelse return p.fail(p.pos, "expected a class name", .{});
        p.declare(name);
        p.skipWs();
        var parent: ?[]const u8 = null;
        if (p.peekIdent()) |kw| {
            if (std.mem.eql(u8, kw, "extends")) {
                p.pos += 7;
                p.skipWs();
                parent = p.readIdent() orelse return p.fail(p.pos, "expected a parent class name", .{});
            }
        }
        p.skipNewlines();
        const open = p.pos;
        try p.expect('{');
        p.pushScope();
        defer p.popScope();
        var fields: std.ArrayList(ast.FieldDecl) = .empty;
        var methods: std.ArrayList(*ast.FnDecl) = .empty;
        while (true) {
            p.skipTerms();
            if (p.eof()) return p.unclosed(open, "'{'");
            if (p.peekc() == '}') {
                p.pos += 1;
                break;
            }
            const mstart = p.pos;
            const kw = p.readIdent() orelse return p.fail(p.pos, "expected `var` or `fn` in class body", .{});
            p.skipWs();
            if (std.mem.eql(u8, kw, "var")) {
                const fname = p.readIdent() orelse return p.fail(p.pos, "expected a field name", .{});
                try p.expectEquals();
                const init_expr = try p.parseExpr();
                fields.append(mem.gpa, .{ .name = fname, .init = init_expr, .span = p.span(mstart) }) catch oom();
            } else if (std.mem.eql(u8, kw, "fn")) {
                const mname = p.readIdent() orelse return p.fail(p.pos, "expected a method name", .{});
                methods.append(mem.gpa, try p.parseFnRest(mstart, mname, true)) catch oom();
            } else {
                p.pos = mstart;
                return p.fail(mstart, "expected `var` or `fn` in class body", .{});
            }
        }
        const d = mem.gpa.create(ast.ClassDecl) catch oom();
        d.* = .{ .span = p.span(start), .name = name, .parent = parent, .fields = fields.items, .methods = methods.items };
        return .{ .span = p.span(start), .kind = .{ .class_decl = d } };
    }

    fn parseReturn(p: *Parser) ParseError!Stmt {
        const start = p.pos;
        p.pos += 6;
        p.skipWs();
        var e: ?*Expr = null;
        const c = p.peekc();
        if (!(p.eof() or c == '\n' or c == ';' or c == '}')) e = try p.parseExpr();
        return .{ .span = p.span(start), .kind = .{ .return_ = e } };
    }

    fn parseTry(p: *Parser) ParseError!Stmt {
        const start = p.pos;
        p.pos += 3;
        const body = try p.parseBlock();
        var name: []const u8 = "";
        var handler: ?[]const Stmt = null;
        var finally_: ?[]const Stmt = null;

        var save = p.pos;
        p.skipNewlines();
        if (p.peekIdent()) |kw| {
            if (std.mem.eql(u8, kw, "catch")) {
                p.pos += 5;
                p.skipWs();
                try p.expect('(');
                p.skipWs();
                name = p.readIdent() orelse return p.fail(p.pos, "expected a name for the error", .{});
                try p.expect(')');
                p.pushScope();
                p.declare(name);
                defer p.popScope();
                handler = try p.parseBlock();
                save = p.pos;
                p.skipNewlines();
            }
        }
        if (p.peekIdent()) |kw| {
            if (std.mem.eql(u8, kw, "finally")) {
                p.pos += 7;
                finally_ = try p.parseBlock();
                save = p.pos;
            }
        }
        p.pos = save;
        if (handler == null and finally_ == null) return p.fail(save, "expected `catch` or `finally` after try block", .{});
        return .{ .span = p.span(start), .kind = .{ .try_ = .{ .body = body, .name = name, .handler = handler, .finally_ = finally_ } } };
    }

    fn parseImport(p: *Parser) ParseError!Stmt {
        const start = p.pos;
        p.pos += 6;
        p.skipWs();
        const q = p.peekc();
        if (q != '"' and q != '\'') return p.fail(p.pos, "expected a quoted path after `import`", .{});
        const e = try p.parseExpr();
        const path: []const u8 = switch (e.kind) {
            .str => |parts| blk: {
                if (parts.len == 1 and parts[0] == .lit) break :blk parts[0].lit;
                if (parts.len == 0) break :blk "";
                return p.fail(start, "import path must be a plain string", .{});
            },
            else => return p.fail(start, "import path must be a plain string", .{}),
        };
        p.skipWs();
        const kw = p.readIdent() orelse return p.fail(p.pos, "expected `as` after import path", .{});
        if (!std.mem.eql(u8, kw, "as")) return p.fail(p.pos - kw.len, "expected `as` after import path", .{});
        p.skipWs();
        const alias = p.readIdent() orelse return p.fail(p.pos, "expected a name after `as`", .{});
        p.declare(alias);
        return .{ .span = p.span(start), .kind = .{ .import = .{ .path = path, .alias = alias } } };
    }

    fn parseExprStmt(p: *Parser) ParseError!Stmt {
        return p.parseAssignOrCall();
    }

    /// Parse `lvalue op expr`, `lvalue++` or a call expression statement.
    fn parseAssignOrCall(p: *Parser) ParseError!Stmt {
        const start = p.pos;
        const target = try p.parsePostfix();
        p.skipWs();
        const c = p.peekc();
        const c1 = p.at(1);
        var op: ?ast.AssignOp = null;
        var oplen: usize = 0;
        if (c == '=' and c1 != '=') {
            op = .set;
            oplen = 1;
        } else if (c == '+' and c1 == '=') {
            op = .add;
            oplen = 2;
        } else if (c == '-' and c1 == '=') {
            op = .sub;
            oplen = 2;
        } else if (c == '*' and c1 == '=') {
            op = .mul;
            oplen = 2;
        } else if (c == '/' and c1 == '=') {
            op = .div;
            oplen = 2;
        } else if (c == '+' and c1 == '+') {
            op = .inc;
            oplen = 2;
        } else if (c == '-' and c1 == '-') {
            op = .dec;
            oplen = 2;
        }
        if (op) |o| {
            switch (target.kind) {
                .ident, .member, .index => {},
                else => return p.fail(start, "invalid assignment target", .{}),
            }
            p.pos += oplen;
            var value: ?*Expr = null;
            if (o != .inc and o != .dec) {
                p.skipWs();
                value = try p.parseExpr();
            }
            return .{ .span = p.span(start), .kind = .{ .assign = .{ .target = target, .op = o, .value = value } } };
        }
        switch (target.kind) {
            .call => {},
            else => return p.fail(start, "expression statement has no effect", .{}),
        }
        return .{ .span = p.span(start), .kind = .{ .expr = target } };
    }

    // ------------------------------------------------------------ commands

    fn atTerminator(p: *Parser) bool {
        if (p.eof()) return true;
        return switch (p.peekc()) {
            '\n', ';', '|', ')' => true,
            '&' => p.at(1) != '>', // `&>` is a redirection
            else => false,
        };
    }

    fn standaloneBrace(p: *Parser, c: u8) bool {
        if (p.peekc() != c) return false;
        const n = p.at(1);
        if (n == 0 or n == ' ' or n == '\t' or n == '\n' or n == ';' or n == '\r') return true;
        // A closing brace may be followed by what ends the enclosing expression,
        // as in `fn(s) { rm -f $f }` passed as an argument.
        return c == '}' and (n == ')' or n == ',' or n == ']' or n == '}');
    }

    /// `stop_brace`: a standalone `{` ends the command (it opens a block).
    fn parseCommandList(p: *Parser, stop_brace: bool) ParseError!*ast.CommandList {
        const start = p.pos;
        const first = try p.parsePipeline(stop_brace);
        var rest: std.ArrayList(ast.Chain) = .empty;
        var background = false;
        while (true) {
            p.skipWs();
            if (p.startsWith("&&") or p.startsWith("||")) {
                const is_and = p.peekc() == '&';
                p.pos += 2;
                p.skipNewlines();
                const pl = try p.parsePipeline(stop_brace);
                rest.append(mem.gpa, .{ .and_ = is_and, .p = pl }) catch oom();
            } else if (p.peekc() == '&' and p.at(1) != '>' and p.at(1) != '&') {
                p.pos += 1;
                background = true;
                break;
            } else break;
        }
        const cl = mem.gpa.create(ast.CommandList) catch oom();
        cl.* = .{ .span = p.span(start), .first = first, .rest = rest.items, .background = background };
        return cl;
    }

    fn parsePipeline(p: *Parser, stop_brace: bool) ParseError!ast.Pipeline {
        p.skipWs();
        const start = p.pos;
        var negate = false;
        if (p.peekc() == '!' and (p.at(1) == ' ' or p.at(1) == '\t')) {
            negate = true;
            p.pos += 1;
            p.skipWs();
        }
        var cmds: std.ArrayList(ast.Command) = .empty;
        while (true) {
            cmds.append(mem.gpa, try p.parseCommand(stop_brace)) catch oom();
            p.skipWs();
            if (p.peekc() == '|' and p.at(1) != '|') {
                p.pos += 1;
                p.skipNewlines();
            } else break;
        }
        return .{ .span = p.span(start), .cmds = cmds.items, .negate = negate };
    }

    fn parseCommand(p: *Parser, stop_brace: bool) ParseError!ast.Command {
        p.skipWs();
        const start = p.pos;
        var words: std.ArrayList(ast.Word) = .empty;
        var redirs: std.ArrayList(ast.Redirect) = .empty;
        while (true) {
            p.skipWs();
            if (p.atTerminator()) break;
            if (p.standaloneBrace('}')) break;
            if (stop_brace and p.standaloneBrace('{')) break;
            if (try p.tryRedirect(&redirs)) continue;
            words.append(mem.gpa, try p.parseWord()) catch oom();
        }
        if (words.items.len == 0 and redirs.items.len == 0) {
            if (p.eof()) return p.fail(p.pos, "unexpected end of input, expected a command", .{});
            return p.fail(p.pos, "expected a command", .{});
        }
        return .{ .span = p.span(start), .words = words.items, .redirs = redirs.items };
    }

    fn tryRedirect(p: *Parser, out: *std.ArrayList(ast.Redirect)) ParseError!bool {
        const start = p.pos;
        var kind: ast.RedirKind = undefined;
        var len: usize = 0;
        var needs_target = true;
        if (p.startsWith("2>&1")) {
            kind = .err_to_out;
            len = 4;
            needs_target = false;
        } else if (p.startsWith("2>>")) {
            kind = .err_append;
            len = 3;
        } else if (p.startsWith("2>")) {
            kind = .err;
            len = 2;
        } else if (p.startsWith("&>")) {
            kind = .both;
            len = 2;
        } else if (p.startsWith("1>>")) {
            kind = .append;
            len = 3;
        } else if (p.startsWith("1>")) {
            kind = .out;
            len = 2;
        } else if (p.startsWith(">>")) {
            kind = .append;
            len = 2;
        } else if (p.startsWith(">")) {
            kind = .out;
            len = 1;
        } else if (p.startsWith("<<<")) {
            kind = .here_string;
            len = 3;
        } else if (p.startsWith("<")) {
            kind = .in;
            len = 1;
        } else return false;
        p.pos += len;
        var target: ?ast.Word = null;
        if (needs_target) {
            p.skipWs();
            if (p.atTerminator()) return p.fail(p.pos, "expected a file name after the redirection", .{});
            target = try p.parseWord();
        }
        out.append(mem.gpa, .{ .kind = kind, .target = target, .span = p.span(start) }) catch oom();
        return true;
    }

    fn isWordEnd(c: u8) bool {
        return switch (c) {
            0, ' ', '\t', '\n', '\r', '|', '&', ';', '<', '>', ')' => true,
            else => false,
        };
    }

    fn parseWord(p: *Parser) ParseError!ast.Word {
        const start = p.pos;
        var parts: std.ArrayList(ast.WordPart) = .empty;
        var lit: std.ArrayList(u8) = .empty;

        // Flush accumulated unquoted text.
        const Flush = struct {
            fn run(l: *std.ArrayList(u8), ps: *std.ArrayList(ast.WordPart)) void {
                if (l.items.len > 0) {
                    ps.append(mem.gpa, .{ .text = .{ .s = l.items, .quoted = false } }) catch oom();
                    l.* = .empty;
                }
            }
        };

        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            if (isWordEnd(c)) break;
            switch (c) {
                '\\' => {
                    if (p.at(1) == '\n') {
                        p.pos += 2;
                        continue;
                    }
                    if (p.pos + 1 >= p.src.len) return p.fail(p.pos, "unexpected end of input after '\\'", .{});
                    Flush.run(&lit, &parts);
                    parts.append(mem.gpa, .{ .text = .{ .s = mem.dupe(p.src[p.pos + 1 .. p.pos + 2]), .quoted = true } }) catch oom();
                    p.pos += 2;
                },
                '\'' => {
                    Flush.run(&lit, &parts);
                    const s = p.pos + 1;
                    var e = s;
                    while (e < p.src.len and p.src[e] != '\'') e += 1;
                    if (e >= p.src.len) return p.fail(p.src.len, "unterminated single-quoted string", .{});
                    parts.append(mem.gpa, .{ .text = .{ .s = p.src[s..e], .quoted = true } }) catch oom();
                    p.pos = e + 1;
                },
                '"' => {
                    Flush.run(&lit, &parts);
                    p.pos += 1;
                    const sp = try p.parseDqParts('"', 0);
                    for (sp) |part| switch (part) {
                        .lit => |s| parts.append(mem.gpa, .{ .text = .{ .s = s, .quoted = true } }) catch oom(),
                        .expr => |e| parts.append(mem.gpa, .{ .expr = e }) catch oom(),
                    };
                    // `""` must still produce an (empty) argument.
                    if (sp.len == 0) parts.append(mem.gpa, .{ .text = .{ .s = "", .quoted = true } }) catch oom();
                },
                '$' => {
                    const n = p.at(1);
                    if (n == '(') {
                        Flush.run(&lit, &parts);
                        p.pos += 2;
                        const list = try p.parseSubCommand();
                        parts.append(mem.gpa, .{ .cmd_sub = .{ .list = list, .lines = false } }) catch oom();
                    } else if (n == '{') {
                        Flush.run(&lit, &parts);
                        p.pos += 2;
                        const e = try p.parseInterp();
                        parts.append(mem.gpa, .{ .expr = e }) catch oom();
                    } else if (isIdentStart(n)) {
                        Flush.run(&lit, &parts);
                        p.pos += 1;
                        const name = p.readIdent().?;
                        var fields: std.ArrayList([]const u8) = .empty;
                        // `$obj.field`: only a field when the value turns out to be a map or object.
                        while (p.peekc() == '.' and isIdentStart(p.at(1))) {
                            p.pos += 1;
                            fields.append(mem.gpa, p.readIdent().?) catch oom();
                        }
                        parts.append(mem.gpa, .{ .var_ = .{ .name = name, .fields = fields.items } }) catch oom();
                    } else {
                        lit.append(mem.gpa, '$') catch oom();
                        p.pos += 1;
                    }
                },
                '@' => {
                    const n = p.at(1);
                    if (n == '(' and p.pos == start) {
                        p.pos += 2;
                        const list = try p.parseSubCommand();
                        parts.append(mem.gpa, .{ .cmd_sub = .{ .list = list, .lines = true } }) catch oom();
                    } else if (isIdentStart(n) and p.pos == start) {
                        p.pos += 1;
                        const e_start = p.pos;
                        const name = p.readIdent().?;
                        var e = p.newExpr(e_start, .{ .ident = name });
                        while (p.peekc() == '.' and isIdentStart(p.at(1))) {
                            p.pos += 1;
                            const f = p.readIdent().?;
                            e = p.newExpr(e_start, .{ .member = .{ .obj = e, .name = f } });
                        }
                        parts.append(mem.gpa, .{ .splice = e }) catch oom();
                    } else {
                        lit.append(mem.gpa, '@') catch oom();
                        p.pos += 1;
                    }
                },
                '~' => {
                    if (p.pos == start) {
                        p.pos += 1;
                        const s = p.pos;
                        while (p.pos < p.src.len and (isIdentChar(p.src[p.pos]) or p.src[p.pos] == '-' or p.src[p.pos] == '.')) p.pos += 1;
                        parts.append(mem.gpa, .{ .tilde = p.src[s..p.pos] }) catch oom();
                    } else {
                        lit.append(mem.gpa, '~') catch oom();
                        p.pos += 1;
                    }
                },
                else => {
                    lit.append(mem.gpa, c) catch oom();
                    p.pos += 1;
                },
            }
        }
        Flush.run(&lit, &parts);
        return .{ .span = p.span(start), .parts = parts.items };
    }

    /// After `$(` or `@(`: a command list, then `)`.
    fn parseSubCommand(p: *Parser) ParseError!*ast.CommandList {
        p.skipNewlines();
        const list = try p.parseCommandList(false);
        p.skipNewlines();
        if (p.peekc() != ')') {
            if (p.eof()) return p.fail(p.pos, "unterminated `$(`: expected ')'", .{});
            return p.fail(p.pos, "expected ')' to end the command substitution", .{});
        }
        p.pos += 1;
        return list;
    }

    /// After `${`: an expression, then `}`.
    fn parseInterp(p: *Parser) ParseError!*Expr {
        p.nest += 1;
        defer p.dec();
        const e = try p.parseExpr();
        p.skipWs();
        if (p.peekc() != '}') {
            if (p.eof()) return p.fail(p.pos, "unterminated `${{`: expected '}}'", .{});
            return p.fail(p.pos, "expected '}}' to end the interpolation", .{});
        }
        p.pos += 1;
        return e;
    }

    /// Parse the inside of a double-quoted string up to the closing quote.
    /// `triple` is 3 for `"""` strings, in which case `indent` is stripped from
    /// every line start.
    fn parseDqParts(p: *Parser, quote: u8, indent: usize) ParseError![]const ast.StrPart {
        const triple = indent != std.math.maxInt(usize) and quote == '"' and false;
        _ = triple;
        return p.parseDqPartsEx(false, indent);
    }

    fn parseDqPartsEx(p: *Parser, triple: bool, indent: usize) ParseError![]const ast.StrPart {
        var parts: std.ArrayList(ast.StrPart) = .empty;
        var lit: std.ArrayList(u8) = .empty;
        const open = p.pos;
        var line_start = triple;
        while (true) {
            if (p.pos >= p.src.len) return p.fail(open, "unterminated string", .{});
            if (line_start) {
                var k: usize = 0;
                while (k < indent and p.pos < p.src.len and (p.src[p.pos] == ' ' or p.src[p.pos] == '\t')) : (k += 1) p.pos += 1;
                line_start = false;
                continue;
            }
            const c = p.src[p.pos];
            if (triple) {
                if (c == '"' and p.at(1) == '"' and p.at(2) == '"') {
                    p.pos += 3;
                    break;
                }
            } else if (c == '"') {
                p.pos += 1;
                break;
            }
            switch (c) {
                '\\' => {
                    const n = p.at(1);
                    p.pos += 2;
                    switch (n) {
                        'n' => lit.append(mem.gpa, '\n') catch oom(),
                        't' => lit.append(mem.gpa, '\t') catch oom(),
                        'r' => lit.append(mem.gpa, '\r') catch oom(),
                        '0' => lit.append(mem.gpa, 0) catch oom(),
                        '\\' => lit.append(mem.gpa, '\\') catch oom(),
                        '"' => lit.append(mem.gpa, '"') catch oom(),
                        '$' => lit.append(mem.gpa, '$') catch oom(),
                        'e' => lit.append(mem.gpa, 27) catch oom(),
                        'u' => {
                            if (p.peekc() != '{') return p.fail(p.pos - 2, "expected '{{' after \\u", .{});
                            p.pos += 1;
                            const s = p.pos;
                            while (p.pos < p.src.len and p.src[p.pos] != '}') p.pos += 1;
                            const cp = std.fmt.parseInt(u21, p.src[s..p.pos], 16) catch return p.fail(s, "invalid unicode escape", .{});
                            p.pos += 1;
                            var buf: [4]u8 = undefined;
                            const n8 = std.unicode.utf8Encode(cp, &buf) catch return p.fail(s, "invalid unicode code point", .{});
                            lit.appendSlice(mem.gpa, buf[0..n8]) catch oom();
                        },
                        '\n' => {},
                        else => return p.fail(p.pos - 2, "unknown escape '\\{c}'", .{n}),
                    }
                },
                '$' => {
                    const n = p.at(1);
                    if (n == '{') {
                        if (lit.items.len > 0) parts.append(mem.gpa, .{ .lit = lit.items }) catch oom();
                        lit = .empty;
                        p.pos += 2;
                        parts.append(mem.gpa, .{ .expr = try p.parseInterp() }) catch oom();
                    } else if (n == '(') {
                        if (lit.items.len > 0) parts.append(mem.gpa, .{ .lit = lit.items }) catch oom();
                        lit = .empty;
                        const s = p.pos;
                        p.pos += 2;
                        const list = try p.parseSubCommand();
                        parts.append(mem.gpa, .{ .expr = p.newExpr(s, .{ .cmd_sub = .{ .list = list, .lines = false } }) }) catch oom();
                    } else if (isIdentStart(n)) {
                        if (lit.items.len > 0) parts.append(mem.gpa, .{ .lit = lit.items }) catch oom();
                        lit = .empty;
                        const s = p.pos;
                        p.pos += 1;
                        const name = p.readIdent().?;
                        parts.append(mem.gpa, .{ .expr = p.newExpr(s, .{ .ident = name }) }) catch oom();
                    } else {
                        lit.append(mem.gpa, '$') catch oom();
                        p.pos += 1;
                    }
                },
                '\n' => {
                    lit.append(mem.gpa, '\n') catch oom();
                    p.pos += 1;
                    line_start = triple;
                },
                else => {
                    lit.append(mem.gpa, c) catch oom();
                    p.pos += 1;
                },
            }
        }
        if (lit.items.len > 0) parts.append(mem.gpa, .{ .lit = lit.items }) catch oom();
        return parts.items;
    }

    // --------------------------------------------------------- expressions

    pub fn parseExpr(p: *Parser) ParseError!*Expr {
        return p.parseTernary();
    }

    fn parseTernary(p: *Parser) ParseError!*Expr {
        const start = p.pos;
        const c = try p.parseBinary(0);
        p.skipWs();
        if (p.peekc() == '?') {
            p.pos += 1;
            const a = try p.parseTernary();
            p.skipWs();
            if (p.peekc() != ':') return p.fail(p.pos, "expected ':' in conditional expression", .{});
            p.pos += 1;
            const b = try p.parseTernary();
            return p.newExpr(start, .{ .ternary = .{ .c = c, .a = a, .b = b } });
        }
        return c;
    }

    const OpInfo = struct { op: ast.BinOp, len: usize, prec: u8 };

    fn peekBinOp(p: *Parser) ?OpInfo {
        p.skipWs();
        const c = p.peekc();
        const c1 = p.at(1);
        return switch (c) {
            '|' => if (c1 == '|') .{ .op = .or_, .len = 2, .prec = 1 } else null,
            '&' => if (c1 == '&') .{ .op = .and_, .len = 2, .prec = 2 } else null,
            '=' => if (c1 == '=') .{ .op = .eq, .len = 2, .prec = 3 } else if (c1 == '~') .{ .op = .match, .len = 2, .prec = 3 } else null,
            '!' => if (c1 == '=') .{ .op = .ne, .len = 2, .prec = 3 } else if (c1 == '~') .{ .op = .nomatch, .len = 2, .prec = 3 } else null,
            '<' => if (c1 == '=') .{ .op = .le, .len = 2, .prec = 4 } else .{ .op = .lt, .len = 1, .prec = 4 },
            '>' => if (c1 == '=') .{ .op = .ge, .len = 2, .prec = 4 } else .{ .op = .gt, .len = 1, .prec = 4 },
            '+' => if (c1 == '=' or c1 == '+') null else .{ .op = .add, .len = 1, .prec = 5 },
            '-' => if (c1 == '=' or c1 == '-') null else .{ .op = .sub, .len = 1, .prec = 5 },
            '*' => if (c1 == '=') null else .{ .op = .mul, .len = 1, .prec = 6 },
            '/' => if (c1 == '=') null else .{ .op = .div, .len = 1, .prec = 6 },
            '%' => .{ .op = .mod, .len = 1, .prec = 6 },
            'i' => if (c1 == 'n' and !isIdentChar(p.at(2))) .{ .op = .in, .len = 2, .prec = 4 } else null,
            else => null,
        };
    }

    fn parseBinary(p: *Parser, min_prec: u8) ParseError!*Expr {
        const start = p.pos;
        var lhs = try p.parseUnary();
        while (true) {
            const info = p.peekBinOp() orelse break;
            if (info.prec < min_prec or info.prec == 0) break;
            p.pos += info.len;
            p.skipWs();
            if (p.eof()) return p.fail(p.pos, "unexpected end of input after operator", .{});
            const rhs = try p.parseBinary(info.prec + 1);
            lhs = p.newExpr(start, .{ .binary = .{ .op = info.op, .l = lhs, .r = rhs } });
        }
        return lhs;
    }

    fn parseUnary(p: *Parser) ParseError!*Expr {
        p.skipWs();
        const start = p.pos;
        if (p.peekc() == '!' and p.at(1) != '=') {
            p.pos += 1;
            const e = try p.parseUnary();
            return p.newExpr(start, .{ .unary = .{ .op = .not, .e = e } });
        }
        if (p.peekc() == '-') {
            p.pos += 1;
            const e = try p.parseUnary();
            switch (e.kind) {
                .int => |v| return p.newExpr(start, .{ .int = -%v }),
                .float => |v| return p.newExpr(start, .{ .float = -v }),
                else => {},
            }
            return p.newExpr(start, .{ .unary = .{ .op = .neg, .e = e } });
        }
        return p.parsePostfix();
    }

    fn parsePostfix(p: *Parser) ParseError!*Expr {
        p.skipWs();
        const start = p.pos;
        var e = try p.parsePrimary();
        while (true) {
            const c = p.peekc();
            if (c == '(' ) {
                p.pos += 1;
                p.nest += 1;
                var args: std.ArrayList(*Expr) = .empty;
                p.skipWs();
                while (p.peekc() != ')') {
                    if (p.eof()) return p.fail(p.pos, "unexpected end of input in argument list", .{});
                    args.append(mem.gpa, try p.parseExpr()) catch oom();
                    p.skipWs();
                    if (p.peekc() == ',') {
                        p.pos += 1;
                        p.skipWs();
                    } else break;
                }
                p.dec();
                try p.expect(')');
                e = p.newExpr(start, .{ .call = .{ .callee = e, .args = args.items } });
            } else if (c == '[') {
                p.pos += 1;
                p.nest += 1;
                const idx = try p.parseExpr();
                p.dec();
                try p.expect(']');
                e = p.newExpr(start, .{ .index = .{ .obj = e, .idx = idx } });
            } else if (c == '.' and isIdentStart(p.at(1))) {
                p.pos += 1;
                const name = p.readIdent().?;
                e = p.newExpr(start, .{ .member = .{ .obj = e, .name = name } });
            } else break;
        }
        return e;
    }

    fn parsePrimary(p: *Parser) ParseError!*Expr {
        p.skipWs();
        const start = p.pos;
        if (p.eof()) return p.fail(p.pos, "unexpected end of input, expected an expression", .{});
        const c = p.peekc();
        if (std.ascii.isDigit(c)) return p.parseNumber();
        switch (c) {
            '"' => {
                if (p.startsWith("\"\"\"")) return p.parseTripleString();
                p.pos += 1;
                const parts = try p.parseDqPartsEx(false, 0);
                return p.newExpr(start, .{ .str = parts });
            },
            '\'' => {
                p.pos += 1;
                const s = p.pos;
                while (p.pos < p.src.len and p.src[p.pos] != '\'') p.pos += 1;
                if (p.pos >= p.src.len) return p.fail(start, "unterminated single-quoted string", .{});
                const text = p.src[s..p.pos];
                p.pos += 1;
                const parts = mem.gpa.alloc(ast.StrPart, 1) catch oom();
                parts[0] = .{ .lit = text };
                return p.newExpr(start, .{ .str = parts });
            },
            '(' => {
                p.pos += 1;
                p.nest += 1;
                const e = try p.parseExpr();
                p.skipWs();
                p.dec();
                try p.expect(')');
                return e;
            },
            '[' => {
                p.pos += 1;
                p.nest += 1;
                var items: std.ArrayList(*Expr) = .empty;
                p.skipWs();
                while (p.peekc() != ']') {
                    if (p.eof()) return p.fail(p.pos, "unexpected end of input in array literal", .{});
                    items.append(mem.gpa, try p.parseExpr()) catch oom();
                    p.skipWs();
                    if (p.peekc() == ',') {
                        p.pos += 1;
                        p.skipWs();
                    } else break;
                }
                p.dec();
                try p.expect(']');
                return p.newExpr(start, .{ .array = items.items });
            },
            '{' => return p.parseMapLiteral(),
            '$' => {
                if (p.at(1) == '(') {
                    p.pos += 2;
                    const list = try p.parseSubCommand();
                    return p.newExpr(start, .{ .cmd_sub = .{ .list = list, .lines = false } });
                }
                return p.fail(p.pos, "unexpected '$' in expression", .{});
            },
            '@' => {
                if (p.at(1) == '(') {
                    p.pos += 2;
                    const list = try p.parseSubCommand();
                    return p.newExpr(start, .{ .cmd_sub = .{ .list = list, .lines = true } });
                }
                return p.fail(p.pos, "unexpected '@' in expression", .{});
            },
            else => {},
        }
        if (isIdentStart(c)) {
            const id = p.readIdent().?;
            if (std.mem.eql(u8, id, "true")) return p.newExpr(start, .{ .bool_ = true });
            if (std.mem.eql(u8, id, "false")) return p.newExpr(start, .{ .bool_ = false });
            if (std.mem.eql(u8, id, "null")) return p.newExpr(start, .{ .null_ = {} });
            if (std.mem.eql(u8, id, "fn") and p.peekc() == '(') {
                const d = try p.parseFnRest(start, "", false);
                return p.newExpr(start, .{ .fn_ = d });
            }
            if (std.mem.eql(u8, id, "status") and p.peekc() == '(') {
                p.pos += 1;
                const list = try p.parseSubCommand();
                return p.newExpr(start, .{ .status = list });
            }
            if (isKeyword(id)) {
                p.pos = start;
                return p.fail(start, "unexpected keyword `{s}` in expression", .{id});
            }
            return p.newExpr(start, .{ .ident = id });
        }
        return p.fail(p.pos, "unexpected '{c}', expected an expression", .{c});
    }

    fn parseMapLiteral(p: *Parser) ParseError!*Expr {
        const start = p.pos;
        p.pos += 1;
        p.nest += 1;
        var entries: std.ArrayList(ast.MapEntry) = .empty;
        p.skipWs();
        while (p.peekc() != '}') {
            if (p.eof()) return p.fail(p.pos, "unexpected end of input in map literal", .{});
            p.skipWs();
            const kstart = p.pos;
            var key: *Expr = undefined;
            if (isIdentStart(p.peekc())) {
                const id = p.readIdent().?;
                const parts = mem.gpa.alloc(ast.StrPart, 1) catch oom();
                parts[0] = .{ .lit = id };
                key = p.newExpr(kstart, .{ .str = parts });
            } else key = try p.parseExpr();
            p.skipWs();
            if (p.peekc() != ':') return p.fail(p.pos, "expected ':' after map key", .{});
            p.pos += 1;
            const value = try p.parseExpr();
            entries.append(mem.gpa, .{ .key = key, .value = value }) catch oom();
            p.skipWs();
            if (p.peekc() == ',') {
                p.pos += 1;
                p.skipWs();
            } else break;
        }
        p.dec();
        try p.expect('}');
        return p.newExpr(start, .{ .map = entries.items });
    }

    fn parseTripleString(p: *Parser) ParseError!*Expr {
        const start = p.pos;
        p.pos += 3;
        // A newline right after the opening quotes is not part of the string.
        if (p.peekc() == '\n') p.pos += 1 else if (p.peekc() == '\r' and p.at(1) == '\n') p.pos += 2;
        // Common leading whitespace of the non-blank lines.
        var indent: usize = std.math.maxInt(usize);
        var i = p.pos;
        while (i < p.src.len) {
            var j = i;
            while (j < p.src.len and (p.src[j] == ' ' or p.src[j] == '\t')) j += 1;
            const blank_end = j >= p.src.len or p.src[j] == '\n';
            const closes = j + 2 < p.src.len + 0 and std.mem.startsWith(u8, p.src[j..], "\"\"\"");
            if (closes) {
                // The closing line, if only whitespace precedes it, counts too.
                if (j - i < indent) indent = j - i;
                break;
            }
            if (!blank_end and j - i < indent) indent = j - i;
            while (j < p.src.len and p.src[j] != '\n') {
                if (std.mem.startsWith(u8, p.src[j..], "\"\"\"")) break;
                j += 1;
            }
            if (j < p.src.len and p.src[j] != '\n') break; // closing quotes mid-line
            i = j + 1;
        }
        if (indent == std.math.maxInt(usize)) indent = 0;
        var parts_list = try p.parseDqPartsEx(true, indent);
        // Drop the whitespace-only last line (the indentation before `"""`).
        if (parts_list.len > 0) {
            const last = &parts_list[parts_list.len - 1];
            _ = last;
        }
        const parts_mut = mem.gpa.dupe(ast.StrPart, parts_list) catch oom();
        if (parts_mut.len > 0 and parts_mut[parts_mut.len - 1] == .lit) {
            const s = parts_mut[parts_mut.len - 1].lit;
            const nl = std.mem.lastIndexOfScalar(u8, s, '\n');
            const tail = if (nl) |k| s[k + 1 ..] else s;
            if (nl != null and std.mem.trim(u8, tail, " \t").len == 0) {
                parts_mut[parts_mut.len - 1] = .{ .lit = s[0 .. nl.? ] };
            }
        }
        parts_list = parts_mut;
        return p.newExpr(start, .{ .str = parts_list });
    }

    fn parseNumber(p: *Parser) ParseError!*Expr {
        const start = p.pos;
        if (p.peekc() == '0' and (p.at(1) == 'x' or p.at(1) == 'o' or p.at(1) == 'b')) {
            const base: u8 = switch (p.at(1)) {
                'x' => 16,
                'o' => 8,
                else => 2,
            };
            p.pos += 2;
            const s = p.pos;
            while (p.pos < p.src.len and (std.ascii.isAlphanumeric(p.src[p.pos]) or p.src[p.pos] == '_')) p.pos += 1;
            const txt = std.mem.replaceOwned(u8, mem.gpa, p.src[s..p.pos], "_", "") catch oom();
            const v = std.fmt.parseInt(i64, txt, base) catch return p.fail(start, "invalid or out-of-range integer literal", .{});
            return p.newExpr(start, .{ .int = v });
        }
        var is_float = false;
        while (p.pos < p.src.len and (std.ascii.isDigit(p.src[p.pos]) or p.src[p.pos] == '_')) p.pos += 1;
        if (p.peekc() == '.' and std.ascii.isDigit(p.at(1))) {
            is_float = true;
            p.pos += 1;
            while (p.pos < p.src.len and (std.ascii.isDigit(p.src[p.pos]) or p.src[p.pos] == '_')) p.pos += 1;
        }
        if ((p.peekc() == 'e' or p.peekc() == 'E') and (std.ascii.isDigit(p.at(1)) or ((p.at(1) == '-' or p.at(1) == '+') and std.ascii.isDigit(p.at(2))))) {
            is_float = true;
            p.pos += 2;
            while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
        }
        const txt = std.mem.replaceOwned(u8, mem.gpa, p.src[start..p.pos], "_", "") catch oom();
        if (is_float) {
            const v = std.fmt.parseFloat(f64, txt) catch return p.fail(start, "invalid float literal", .{});
            return p.newExpr(start, .{ .float = v });
        }
        const v = std.fmt.parseInt(i64, txt, 10) catch return p.fail(start, "integer literal out of range", .{});
        return p.newExpr(start, .{ .int = v });
    }
};

/// Parse `text` as a whole program registered under `name`.
pub fn parseSource(name: []const u8, text: []const u8) ParseError!struct { stmts: []const Stmt, file: u16 } {
    const file = source.add(name, text);
    // A NUL is indistinguishable from end of input inside the scanner.
    if (std.mem.indexOfScalar(u8, text, 0)) |at| {
        diag = .{ .message = "source contains a NUL byte", .span = .{ .file = file, .start = @intCast(at), .end = @intCast(at + 1) } };
        return error.Parse;
    }
    var p = Parser.init(file);
    const stmts = try p.parseProgram();
    return .{ .stmts = stmts, .file = file };
}

// ------------------------------------------------------------------- tests

fn parseOk(text: []const u8) ![]const Stmt {
    const r = try parseSource("<test>", text);
    return r.stmts;
}

test "parser: classifies statements by how they start (SPEC 5.1)" {
    const stmts = try parseOk("var x = 1\nx = 2\nx += 3\nx++\nprint(x)\nls -la > out.txt\nif (x > 1) { }\n");
    try std.testing.expectEqual(@as(usize, 7), stmts.len);
    try std.testing.expect(stmts[0].kind == .var_decl);
    try std.testing.expect(stmts[1].kind == .assign);
    try std.testing.expect(stmts[2].kind.assign.op == .add);
    try std.testing.expect(stmts[3].kind.assign.op == .inc);
    try std.testing.expect(stmts[4].kind == .expr);
    try std.testing.expect(stmts[5].kind == .command);
    try std.testing.expect(stmts[6].kind == .if_);
}

test "parser: undeclared assignment is an error, not a command" {
    try std.testing.expectError(error.Parse, parseOk("x = 5"));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "var x = 5") != null);
}

test "parser: operator precedence" {
    const stmts = try parseOk("var r = 1 + 2 * 3 == 7 && true");
    const e = stmts[0].kind.var_decl.init;
    try std.testing.expect(e.kind.binary.op == .and_);
    const eq = e.kind.binary.l;
    try std.testing.expect(eq.kind.binary.op == .eq);
    try std.testing.expect(eq.kind.binary.l.kind.binary.op == .add);
}

test "parser: command words keep quoting, splices and globs apart" {
    const stmts = try parseOk("var l = []\necho \"a $l\" '$x' @l *.txt\n");
    const cmd = stmts[1].kind.command.first.cmds[0];
    try std.testing.expectEqual(@as(usize, 5), cmd.words.len);
    try std.testing.expect(cmd.words[3].parts[0] == .splice);
    try std.testing.expect(cmd.words[4].parts[0].text.quoted == false);
}

test "parser: incomplete input is distinguished from bad input" {
    try std.testing.expectError(error.Incomplete, parseOk("if (true) {\n"));
    try std.testing.expectError(error.Incomplete, parseOk("var s = \"abc"));
    try std.testing.expectError(error.Parse, parseOk("var x = )"));
    try std.testing.expectError(error.Parse, parseOk("echo \"a\x00b\""));
}

test "parser: blocks need no terminator before the next statement" {
    const stmts = try parseOk("if (true) { } print(1)");
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
}

test "parser: triple-quoted strings drop common indentation" {
    const stmts = try parseOk("var s = \"\"\"\n    a\n      b\n    \"\"\"");
    const parts = stmts[0].kind.var_decl.init.kind.str;
    try std.testing.expectEqualStrings("a\n  b", parts[0].lit);
}

test "parser: spans point at the construct" {
    const stmts = try parseOk("var a = 1\nprint(a + 2)\n");
    const sp = stmts[1].span;
    try std.testing.expectEqual(@as(u32, 10), sp.start);
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const n = smith.slice(&buf);
    // The parser must return a result for any input; it must not crash or hang.
    _ = parseSource("<fuzz>", mem.dupe(buf[0..n])) catch {};
}

test "parser: fuzz (never crashes or hangs)" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        "if (x) {", "echo $(", "\"\"\"abc", "fn f(a, b = ", "class A extends {", "a | | b", "echo > ", "for (;;) {}",
        "var x = {a: [1, {b: $(echo hi)}]}", "echo \"${", "@(", "try { } catch (", "import \"a\" as",
    } });
}
