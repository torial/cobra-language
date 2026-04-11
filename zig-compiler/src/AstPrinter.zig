//! AstPrinter: pretty-print an `Ast.Module` to any `std.io.AnyWriter`.
//!
//! ## Output format
//!
//! The printer emits an indented S-expression style listing that mirrors the
//! AST structure directly.  It is intended for debugging, snapshot tests, and
//! the `zig build grammar` equivalent for the AST.
//!
//! Example output:
//!
//! ```
//! (module
//!   (use "System.Collections")
//!   (class Foo
//!     (implements Bar Baz)
//!     (method greet (params (param name:String)) (return String)
//!       (return (call sayHello (args (ident name)))))))
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const AstPrinter = @import("AstPrinter.zig");
//!
//! const stdout = std.io.getStdOut().writer();
//! try AstPrinter.print(module, stdout.any());
//! ```

const std = @import("std");
const Ast = @import("Ast.zig");

// ── Public entry point ────────────────────────────────────────────────────────

/// Write a human-readable S-expression listing of `module` to `writer`.
pub fn print(module: Ast.Module, writer: std.io.AnyWriter) anyerror!void {
    var p = Printer{ .writer = writer, .indent = 0 };
    try p.printModule(module);
}

// ── Printer context ───────────────────────────────────────────────────────────

const Printer = struct {
    writer: std.io.AnyWriter,
    indent: u32,

    // ── Indent helpers ────────────────────────────────────────────────────────

    fn ind(p: *Printer) anyerror!void {
        var i: u32 = 0;
        while (i < p.indent) : (i += 1)
            try p.writer.writeAll("  ");
    }

    fn push(p: *Printer) void { p.indent += 1; }
    fn pop(p: *Printer)  void { p.indent -= 1; }

    fn nl(p: *Printer) anyerror!void { try p.writer.writeByte('\n'); }

    fn w(p: *Printer, comptime fmt: []const u8, args: anytype) anyerror!void {
        try p.writer.print(fmt, args);
    }

    // ── Module ────────────────────────────────────────────────────────────────

    fn printModule(p: *Printer, module: Ast.Module) anyerror!void {
        try p.w("(module", .{});
        if (module.file.len > 0)
            try p.w(" \"{s}\"", .{module.file});
        p.push();
        for (module.decls) |d| {
            try p.nl();
            try p.ind();
            try p.printDecl(d);
        }
        p.pop();
        try p.w(")\n", .{});
    }

    // ── Declarations ──────────────────────────────────────────────────────────

    fn printDecl(p: *Printer, d: Ast.Decl) anyerror!void {
        switch (d) {
            .use       => |n| try p.printUse(n.*),
            .namespace => |n| try p.printNamespace(n.*),
            .class     => |n| try p.printClass(n.*),
            .interface => |n| try p.printInterface(n.*),
            .struct_   => |n| try p.printStruct(n.*),
            .mixin     => |n| try p.printMixin(n.*),
            .enum_     => |n| try p.printEnum(n.*),
            .extend    => |n| try p.printExtend(n.*),
            .union_    => |n| try p.w("(union {s})", .{n.name}),
            .method    => |n| try p.printMethod(n.*),
            .property  => |n| try p.printProperty(n.*),
            .var_      => |n| try p.printVar(n.*),
            .init      => |n| try p.printInit(n.*),
        }
    }

    fn printUse(p: *Printer, d: Ast.DeclUse) anyerror!void {
        try p.w("(use \"{s}\")", .{d.path});
    }

    fn printNamespace(p: *Printer, d: Ast.DeclNamespace) anyerror!void {
        try p.w("(namespace {s}", .{d.name});
        p.push();
        for (d.decls) |decl| {
            try p.nl();
            try p.ind();
            try p.printDecl(decl);
        }
        p.pop();
        try p.w(")", .{});
    }

    fn printMods(p: *Printer, m: Ast.Modifiers) anyerror!void {
        if (m.public)    try p.w(" public",    .{});
        if (m.private)   try p.w(" private",   .{});
        if (m.protected) try p.w(" protected", .{});
        if (m.internal)  try p.w(" internal",  .{});
        if (m.abstract)  try p.w(" abstract",  .{});
        if (m.shared)    try p.w(" shared",    .{});
        if (m.readonly)  try p.w(" readonly",  .{});
        if (m.extern_)   try p.w(" extern",    .{});
    }

    fn printTypeList(p: *Printer, label: []const u8, types: []const Ast.TypeRef) anyerror!void {
        if (types.len == 0) return;
        try p.w("({s}", .{label});
        for (types) |t| { try p.w(" ", .{}); try p.printTypeRef(t); }
        try p.w(")", .{});
    }

    fn printClass(p: *Printer, d: Ast.DeclClass) anyerror!void {
        try p.w("(class {s}", .{d.name});
        try p.printMods(d.mods);
        if (d.implements.len > 0) {
            try p.w(" ", .{});
            try p.printTypeList("implements", d.implements);
        }
        if (d.adds.len > 0) {
            try p.w(" ", .{});
            try p.printTypeList("adds", d.adds);
        }
        try p.printMembers(d.members);
        try p.w(")", .{});
    }

    fn printInterface(p: *Printer, d: Ast.DeclInterface) anyerror!void {
        try p.w("(interface {s}", .{d.name});
        try p.printMods(d.mods);
        if (d.implements.len > 0) {
            try p.w(" ", .{});
            try p.printTypeList("implements", d.implements);
        }
        try p.printMembers(d.members);
        try p.w(")", .{});
    }

    fn printStruct(p: *Printer, d: Ast.DeclStruct) anyerror!void {
        try p.w("(struct {s}", .{d.name});
        try p.printMods(d.mods);
        if (d.implements.len > 0) {
            try p.w(" ", .{});
            try p.printTypeList("implements", d.implements);
        }
        try p.printMembers(d.members);
        try p.w(")", .{});
    }

    fn printMixin(p: *Printer, d: Ast.DeclMixin) anyerror!void {
        try p.w("(mixin {s}", .{d.name});
        try p.printMods(d.mods);
        try p.printMembers(d.members);
        try p.w(")", .{});
    }

    fn printEnum(p: *Printer, d: Ast.DeclEnum) anyerror!void {
        try p.w("(enum {s}", .{d.name});
        try p.printMods(d.mods);
        if (d.base) |base| { try p.w(" (base ", .{}); try p.printTypeRef(base); try p.w(")", .{}); }
        p.push();
        for (d.members) |m| {
            try p.nl(); try p.ind();
            try p.w("(member {s}", .{m.name});
            if (m.value) |v| { try p.w(" ", .{}); try p.printExpr(v.*); }
            try p.w(")", .{});
        }
        p.pop();
        try p.w(")", .{});
    }

    fn printExtend(p: *Printer, d: Ast.DeclExtend) anyerror!void {
        try p.w("(extend ", .{});
        try p.printTypeRef(d.target);
        try p.printMembers(d.members);
        try p.w(")", .{});
    }

    fn printMembers(p: *Printer, members: []const Ast.Decl) anyerror!void {
        p.push();
        for (members) |m| {
            try p.nl(); try p.ind();
            try p.printDecl(m);
        }
        p.pop();
    }

    fn printMethod(p: *Printer, d: Ast.DeclMethod) anyerror!void {
        try p.w("(method {s}", .{d.name});
        try p.printMods(d.mods);
        if (d.is_test) try p.w(" test", .{});
        if (d.params.len > 0) {
            try p.w(" (params", .{});
            for (d.params) |param| { try p.w(" ", .{}); try p.printParam(param); }
            try p.w(")", .{});
        }
        if (d.return_type) |rt| {
            try p.w(" (return ", .{});
            try p.printTypeRef(rt);
            try p.w(")", .{});
        }
        if (d.require.len > 0) try p.printContractExprs("require", d.require);
        if (d.ensure.len > 0)  try p.printContractExprs("ensure",  d.ensure);
        if (d.body) |body| try p.printBody(body);
        try p.w(")", .{});
    }

    fn printProperty(p: *Printer, d: Ast.DeclProperty) anyerror!void {
        try p.w("(property {s}", .{d.name});
        try p.printMods(d.mods);
        if (d.type_) |t| { try p.w(" (type ", .{}); try p.printTypeRef(t); try p.w(")", .{}); }
        if (d.getter) |g| {
            try p.w(" (get", .{});
            try p.printBody(g);
            try p.w(")", .{});
        }
        if (d.setter) |s| {
            try p.w(" (set", .{});
            try p.printBody(s);
            try p.w(")", .{});
        }
        try p.w(")", .{});
    }

    fn printVar(p: *Printer, d: Ast.DeclVar) anyerror!void {
        const kw = if (d.is_const) "const" else "var";
        try p.w("({s} {s}", .{ kw, d.name });
        try p.printMods(d.mods);
        if (d.type_) |t| { try p.w(" (type ", .{}); try p.printTypeRef(t); try p.w(")", .{}); }
        if (d.init) |e| { try p.w(" ", .{}); try p.printExpr(e.*); }
        try p.w(")", .{});
    }

    fn printInit(p: *Printer, d: Ast.DeclInit) anyerror!void {
        try p.w("(init", .{});
        try p.printMods(d.mods);
        if (d.params.len > 0) {
            try p.w(" (params", .{});
            for (d.params) |param| { try p.w(" ", .{}); try p.printParam(param); }
            try p.w(")", .{});
        }
        if (d.require.len > 0) try p.printContractExprs("require", d.require);
        if (d.ensure.len > 0)  try p.printContractExprs("ensure",  d.ensure);
        if (d.body) |body| try p.printBody(body);
        try p.w(")", .{});
    }

    fn printContractExprs(p: *Printer, label: []const u8, exprs: []const *Ast.Expr) anyerror!void {
        try p.w(" ({s}", .{label});
        for (exprs) |e| { try p.w(" ", .{}); try p.printExpr(e.*); }
        try p.w(")", .{});
    }

    fn printBody(p: *Printer, stmts: []const Ast.Stmt) anyerror!void {
        p.push();
        for (stmts) |s| {
            try p.nl(); try p.ind();
            try p.printStmt(s);
        }
        p.pop();
    }

    // ── Parameters ────────────────────────────────────────────────────────────

    fn printParam(p: *Printer, param: Ast.Param) anyerror!void {
        const prefix: []const u8 = switch (param.mode) {
            .normal => "",
            .vari   => "vari:",
        };
        try p.w("(param {s}{s}", .{ prefix, param.name });
        if (param.type_) |t| { try p.w(" ", .{}); try p.printTypeRef(t); }
        if (param.default) |d| { try p.w(" =", .{}); try p.printExpr(d.*); }
        try p.w(")", .{});
    }

    // ── Type references ───────────────────────────────────────────────────────

    fn printTypeRef(p: *Printer, t: Ast.TypeRef) anyerror!void {
        switch (t) {
            .named       => |n| try p.w("{s}", .{n.name}),
            .nilable     => |inner| { try p.printTypeRef(inner.*); try p.w("?", .{}); },
            .stream      => |inner| { try p.printTypeRef(inner.*); try p.w("*", .{}); },
            .error_union => |inner| { try p.w("!", .{}); try p.printTypeRef(inner.*); },
            .generic     => |g| {
                try p.w("{s}<of", .{g.name});
                for (g.args) |arg| { try p.w(" ", .{}); try p.printTypeRef(arg); }
                try p.w(">", .{});
            },
            .void_  => try p.w("void", .{}),
            .same   => try p.w("same", .{}),
            .tuple  => |tup| {
                try p.w("(tuple", .{});
                for (tup.elems) |el| { try p.w(" ", .{}); try p.printTypeRef(el); }
                try p.w(")", .{});
            },
        }
    }

    // ── Statements ────────────────────────────────────────────────────────────

    fn printStmt(p: *Printer, s: Ast.Stmt) anyerror!void {
        switch (s) {
            .if_      => |n| try p.printIf(n.*),
            .while_   => |n| try p.printWhile(n.*),
            .for_in   => |n| try p.printForIn(n.*),
            .for_num  => |n| try p.printForNum(n.*),
            .branch   => |n| try p.printBranch(n.*),
            .return_  => |n| try p.printReturn(n.*),
            .assert   => |n| try p.printAssert(n.*),
            .print    => |n| try p.printPrint(n.*),
            .yield    => |n| { try p.w("(yield ", .{}); try p.printExpr(n.value.*); try p.w(")", .{}); },
            .assign   => |n| try p.printAssign(n.*),
            .var_     => |n| try p.printVar(n.*),
            .expr     => |e| { try p.w("(expr ", .{}); try p.printExpr(e.*); try p.w(")", .{}); },
            .contract => |n| try p.printContractStmt(n.*),
            .defer_   => |n| try p.printDefer(n.*),
            .with     => |n| { try p.w("(with ", .{}); try p.printExpr(n.target.*); try p.w(")", .{}); },
            .var_except    => |n| { try p.w("(var-except {s})", .{n.name}); },
            .assign_except => |_| { try p.w("(assign-except)", .{}); },
            .raise         => |_| { try p.w("(raise)", .{}); },
            .try_catch     => |_| { try p.w("(try-catch)", .{}); },
            .guard       => |_| { try p.w("(guard)", .{}); },
            .destruct    => |_| { try p.w("(destruct)", .{}); },
            .arena_scope => |_| { try p.w("(arena)", .{}); },
            .pass     => try p.w("(pass)", .{}),
            .break_   => try p.w("(break)", .{}),
            .continue_=> try p.w("(continue)", .{}),
        }
    }

    fn printIf(p: *Printer, s: Ast.StmtIf) anyerror!void {
        try p.w("(if ", .{});
        try p.printExpr(s.cond.*);
        try p.printBody(s.then_body);
        for (s.else_ifs) |ei| {
            try p.nl(); try p.ind();
            try p.w("(elif ", .{});
            try p.printExpr(ei.cond.*);
            try p.printBody(ei.body);
            try p.w(")", .{});
        }
        if (s.else_body) |eb| {
            try p.nl(); try p.ind();
            try p.w("(else", .{});
            try p.printBody(eb);
            try p.w(")", .{});
        }
        try p.w(")", .{});
    }

    fn printWhile(p: *Printer, s: Ast.StmtWhile) anyerror!void {
        try p.w("(while ", .{});
        try p.printExpr(s.cond.*);
        if (s.post_body) |post| {
            try p.w(" (post", .{});
            try p.printBody(post);
            try p.w(")", .{});
        }
        try p.printBody(s.body);
        try p.w(")", .{});
    }

    fn printForIn(p: *Printer, s: Ast.StmtForIn) anyerror!void {
        try p.w("(for-in (vars", .{});
        for (s.vars) |v| try p.w(" {s}", .{v});
        try p.w(") ", .{});
        try p.printExpr(s.iter.*);
        if (s.where) |cond| { try p.w(" (where ", .{}); try p.printExpr(cond.*); try p.w(")", .{}); }
        try p.printBody(s.body);
        try p.w(")", .{});
    }

    fn printForNum(p: *Printer, s: Ast.StmtForNum) anyerror!void {
        try p.w("(for-num {s} ", .{s.var_});
        try p.printExpr(s.start.*);
        try p.w(" ", .{});
        try p.printExpr(s.stop.*);
        if (s.step) |step| { try p.w(" ", .{}); try p.printExpr(step.*); }
        try p.printBody(s.body);
        try p.w(")", .{});
    }

    fn printBranch(p: *Printer, s: Ast.StmtBranch) anyerror!void {
        try p.w("(branch ", .{});
        try p.printExpr(s.expr.*);
        p.push();
        for (s.on) |arm| {
            try p.nl(); try p.ind();
            try p.w("(on", .{});
            for (arm.values) |v| { try p.w(" ", .{}); try p.printExpr(v.*); }
            if (arm.binding) |b| try p.w(" as {s}", .{b});
            if (arm.guard)   |g| { try p.w(" if ", .{}); try p.printExpr(g.*); }
            try p.printBody(arm.body);
            try p.w(")", .{});
        }
        if (s.else_) |eb| {
            try p.nl(); try p.ind();
            try p.w("(else", .{});
            try p.printBody(eb);
            try p.w(")", .{});
        }
        p.pop();
        try p.w(")", .{});
    }

    fn printReturn(p: *Printer, s: Ast.StmtReturn) anyerror!void {
        if (s.value) |v| {
            try p.w("(return ", .{});
            try p.printExpr(v.*);
            try p.w(")", .{});
        } else {
            try p.w("(return)", .{});
        }
    }

    fn printAssert(p: *Printer, s: Ast.StmtAssert) anyerror!void {
        try p.w("(assert ", .{});
        try p.printExpr(s.cond.*);
        if (s.message) |m| { try p.w(" ", .{}); try p.printExpr(m.*); }
        try p.w(")", .{});
    }

    fn printPrint(p: *Printer, s: Ast.StmtPrint) anyerror!void {
        try p.w("(print", .{});
        for (s.args) |a| { try p.w(" ", .{}); try p.printExpr(a.*); }
        try p.w(")", .{});
    }

    fn printAssign(p: *Printer, s: Ast.StmtAssign) anyerror!void {
        const op: []const u8 = switch (s.op) {
            .assign          => "=",
            .plus_eq         => "+=",
            .minus_eq        => "-=",
            .star_eq         => "*=",
            .slash_eq        => "/=",
            .slashslash_eq   => "//=",
            .percent_eq      => "%=",
            .starstar_eq     => "**=",
            .ampersand_eq    => "&=",
            .vertical_bar_eq => "|=",
            .caret_eq        => "^=",
            .double_lt_eq    => "<<=",
            .double_gt_eq    => ">>=",
            .question_eq     => "?=",
        };
        try p.w("(assign {s} ", .{op});
        try p.printExpr(s.target.*);
        try p.w(" ", .{});
        try p.printExpr(s.value.*);
        try p.w(")", .{});
    }

    fn printContractStmt(p: *Printer, s: Ast.StmtContract) anyerror!void {
        const label: []const u8 = switch (s.kind) {
            .require   => "require",
            .ensure    => "ensure",
            .invariant => "invariant",
        };
        try p.w("({s}", .{label});
        for (s.exprs) |e| { try p.w(" ", .{}); try p.printExpr(e.*); }
        try p.w(")", .{});
    }

    fn printDefer(p: *Printer, s: Ast.StmtDefer) anyerror!void {
        const kw = if (s.is_err) "errdefer" else "defer";
        try p.w("({s} ", .{kw});
        try p.printStmt(s.body);
        try p.w(")", .{});
    }

    // ── Expressions ───────────────────────────────────────────────────────────

    fn printExpr(p: *Printer, e: Ast.Expr) anyerror!void {
        switch (e) {
            .int_lit    => |n| try p.w("{s}", .{n.text}),
            .float_lit  => |n| try p.w("{s}", .{n.text}),
            .bool_lit   => |n| try p.w("{s}", .{if (n.value) "true" else "false"}),
            .char_lit   => |n| try p.w("(char {s})", .{n.text}),
            .string_lit => |n| try p.printStringLit(n),
            .string_interp => |n| try p.printStringInterp(n),
            .nil        => try p.w("nil", .{}),
            .this       => try p.w("this", .{}),
            .ident      => |n| try p.w("{s}", .{n.name}),
            .member     => |n| { try p.printExpr(n.object.*); try p.w(".{s}", .{n.member}); },
            .call       => |n| try p.printCall(n.*),
            .index      => |n| { try p.w("(index ", .{}); try p.printExpr(n.object.*); try p.w(" ", .{}); try p.printExpr(n.index.*); try p.w(")", .{}); },
            .slice      => |n| try p.printSlice(n.*),
            .binary     => |n| try p.printBinary(n.*),
            .unary      => |n| try p.printUnary(n.*),
            .cast       => |n| { try p.w("(to ", .{}); try p.printExpr(n.expr.*); try p.w(" ", .{}); try p.printTypeRef(n.target); try p.w(")", .{}); },
            .to_nilable => |n| { try p.w("(to? ", .{}); try p.printExpr(n.expr.*); try p.w(")", .{}); },
            .to_non_nil => |n| { try p.w("(to! ", .{}); try p.printExpr(n.expr.*); try p.w(")", .{}); },
            .is_nil     => |n| { try p.w("(nil? ", .{}); try p.printExpr(n.expr.*); try p.w(")", .{}); },
            .orelse_    => |n| { try p.w("(orelse ", .{}); try p.printExpr(n.expr.*); try p.w(" ", .{}); try p.printExpr(n.fallback.*); try p.w(")", .{}); },
            .catch_     => |n| try p.printCatch(n.*),
            .if_expr    => |n| { try p.w("(if-expr ", .{}); try p.printExpr(n.cond.*); try p.w(" ", .{}); try p.printExpr(n.then_expr.*); try p.w(" ", .{}); try p.printExpr(n.else_expr.*); try p.w(")", .{}); },
            .lambda     => |n| try p.printLambda(n.*),
            .list_lit   => |n| try p.printListLit(n.*),
            .dict_lit   => |n| try p.printDictLit(n.*),
            .array_lit  => |n| try p.printArrayLit(n.*),
            .all_any    => |n| try p.printAllAny(n.*),
            .old        => |n| { try p.w("(old ", .{}); try p.printExpr(n.expr.*); try p.w(")", .{}); },
            .zig_lit     => |n| try p.w("(zig {s})", .{n.text}),
            .try_        => |n| { try p.w("(try ", .{}); try p.printExpr(n.expr.*); try p.w(")", .{}); },
            .tuple_lit   => |n| { try p.w("(tuple", .{}); for (n.elems) |el| { try p.w(" ", .{}); try p.printExpr(el.*); } try p.w(")", .{}); },
            .type_check  => |n| { try p.w("(is ", .{}); try p.printExpr(n.expr.*); try p.w(" {s})", .{n.type_name}); },
        }
    }

    fn printStringLit(p: *Printer, n: Ast.ExprStringLit) anyerror!void {
        const prefix: []const u8 = switch (n.kind) {
            .plain  => "",
            .raw    => "r",
            .nosub  => "ns",
            .zig    => "zig",
        };
        try p.w("(str {s}{s})", .{ prefix, n.text });
    }

    fn printStringInterp(p: *Printer, n: Ast.ExprStringInterp) anyerror!void {
        try p.w("(interp", .{});
        for (n.parts) |part| {
            switch (part) {
                .literal => |s| try p.w(" \"{s}\"", .{s}),
                .expr    => |e| { try p.w(" (expr ", .{}); try p.printExpr(e.*); try p.w(")", .{}); },
                .format  => |s| try p.w(" (fmt \"{s}\")", .{s}),
            }
        }
        try p.w(")", .{});
    }

    fn printCall(p: *Printer, n: Ast.ExprCall) anyerror!void {
        try p.w("(call ", .{});
        try p.printExpr(n.callee.*);
        if (n.type_args.len > 0) {
            try p.w(" <of", .{});
            for (n.type_args) |ta| { try p.w(" ", .{}); try p.printTypeRef(ta); }
            try p.w(">", .{});
        }
        if (n.args.len > 0) {
            try p.w(" (args", .{});
            for (n.args) |arg| {
                if (arg.name) |name| {
                    try p.w(" {s}:", .{name});
                    try p.printExpr(arg.value.*);
                } else {
                    try p.w(" ", .{});
                    try p.printExpr(arg.value.*);
                }
            }
            try p.w(")", .{});
        }
        try p.w(")", .{});
    }

    fn printSlice(p: *Printer, n: Ast.ExprSlice) anyerror!void {
        try p.w("(slice ", .{});
        try p.printExpr(n.object.*);
        if (n.start) |s| { try p.w(" ", .{}); try p.printExpr(s.*); } else try p.w(" _", .{});
        if (n.stop)  |s| { try p.w(" ", .{}); try p.printExpr(s.*); } else try p.w(" _", .{});
        try p.w(")", .{});
    }

    fn printBinary(p: *Printer, n: Ast.ExprBinary) anyerror!void {
        const op: []const u8 = switch (n.op) {
            .add    => "+",
            .sub    => "-",
            .mul    => "*",
            .div    => "/",
            .int_div=> "//",
            .mod    => "%",
            .pow    => "**",
            .bit_and=> "&",
            .bit_or => "|",
            .bit_xor=> "^",
            .shl    => "<<",
            .shr    => ">>",
            .eq     => "==",
            .ne     => "<>",
            .lt     => "<",
            .le     => "<=",
            .gt     => ">",
            .ge     => ">=",
            .and_   => "and",
            .or_    => "or",
            .in_    => "in",
            .dotdot => "..",
        };
        try p.w("({s} ", .{op});
        try p.printExpr(n.left.*);
        try p.w(" ", .{});
        try p.printExpr(n.right.*);
        try p.w(")", .{});
    }

    fn printUnary(p: *Printer, n: Ast.ExprUnary) anyerror!void {
        const op: []const u8 = switch (n.op) {
            .neg     => "-",
            .not_    => "not",
            .bit_not => "~",
            .old     => "old",
        };
        try p.w("({s} ", .{op});
        try p.printExpr(n.operand.*);
        try p.w(")", .{});
    }

    fn printCatch(p: *Printer, n: Ast.ExprCatch) anyerror!void {
        try p.w("(catch ", .{});
        try p.printExpr(n.expr.*);
        if (n.err_var) |ev| try p.w(" |{s}|", .{ev});
        try p.w(" ", .{});
        try p.printExpr(n.fallback.*);
        try p.w(")", .{});
    }

    fn printLambda(p: *Printer, n: Ast.ExprLambda) anyerror!void {
        try p.w("(lambda", .{});
        if (n.params.len > 0) {
            try p.w(" (params", .{});
            for (n.params) |param| { try p.w(" ", .{}); try p.printParam(param); }
            try p.w(")", .{});
        }
        if (n.return_type) |rt| { try p.w(" (return ", .{}); try p.printTypeRef(rt); try p.w(")", .{}); }
        switch (n.body) {
            .expr  => |e| { try p.w(" ", .{}); try p.printExpr(e.*); },
            .stmts => |ss| try p.printBody(ss),
        }
        try p.w(")", .{});
    }

    fn printListLit(p: *Printer, n: Ast.ExprListLit) anyerror!void {
        try p.w("(list", .{});
        if (n.elem_type) |t| { try p.w("<of ", .{}); try p.printTypeRef(t); try p.w(">", .{}); }
        for (n.elems) |e| { try p.w(" ", .{}); try p.printExpr(e.*); }
        try p.w(")", .{});
    }

    fn printDictLit(p: *Printer, n: Ast.ExprDictLit) anyerror!void {
        try p.w("(dict", .{});
        for (n.entries) |e| {
            try p.w(" (", .{});
            try p.printExpr(e.key.*);
            try p.w(" ", .{});
            try p.printExpr(e.value.*);
            try p.w(")", .{});
        }
        try p.w(")", .{});
    }

    fn printArrayLit(p: *Printer, n: Ast.ExprArrayLit) anyerror!void {
        try p.w("(array", .{});
        for (n.elems) |e| { try p.w(" ", .{}); try p.printExpr(e.*); }
        try p.w(")", .{});
    }

    fn printAllAny(p: *Printer, n: Ast.ExprAllAny) anyerror!void {
        const kw = if (n.kind == .all) "all" else "any";
        try p.w("({s} {s} ", .{ kw, n.var_ });
        try p.printExpr(n.iter.*);
        try p.w(" ", .{});
        try p.printExpr(n.cond.*);
        try p.w(")", .{});
    }
};

