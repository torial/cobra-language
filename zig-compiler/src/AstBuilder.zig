//! AstBuilder: concrete parse tree (CST) → abstract syntax tree (AST).
//!
//! ## Overview
//!
//! The Earley parser produces a `ParseTree` whose nodes mirror the grammar rules
//! exactly.  `AstBuilder` walks that tree and produces an `Ast.Module`, which is
//! a cleaner, semantics-oriented representation that later compiler phases consume.
//!
//! ## Allocation
//!
//! Every AST node is allocated into a caller-supplied arena.  Pass an
//! `ArenaAllocator` and call `build`; the arena owns everything.
//!
//! ## Usage
//!
//! ```zig
//! var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//! defer arena.deinit();
//!
//! var result = try Parser.parse(tokens, gpa);
//! defer result.deinit();
//!
//! const module = try AstBuilder.build(&result.ok, arena.allocator());
//! ```
//!
//! ## Unimplemented paths
//!
//! Less-common constructs (aspect/weave declarations, string interpolation,
//! at-directives) are marked with `@panic("TODO: …")`.  The core language
//! (classes, methods, statements, all expressions) is fully implemented.

const std    = @import("std");
const Ast    = @import("Ast.zig");
const Parser = @import("Parser.zig");
const TokMod = @import("Token.zig");
const Token     = TokMod.Token;
const TokenKind = TokMod.TokenKind;
const G         = @import("ZebraGrammar.zig");
const NT        = G.NT;
const earley    = @import("earley");

const Allocator = std.mem.Allocator;
const TN        = earley.TreeNode(TokenKind);

// ── Public entry point ────────────────────────────────────────────────────────

/// Build an AST module from a successful parse.  `arena` owns all nodes.
pub fn build(result: *Parser.ParseSuccess, arena: Allocator) anyerror!Ast.Module {
    const b = Builder{ .tokens = result.tokens, .arena = arena };
    return b.buildModule(result.tree.root);
}

// ── Builder context ───────────────────────────────────────────────────────────

const Builder = struct {
    tokens: []const Token,
    arena:  Allocator,

    // ── Module ───────────────────────────────────────────────────────────────

    fn buildModule(b: Builder, root: TN) anyerror!Ast.Module {
        // Program → TopDeclList eof
        const tdl_node = ch(root)[0];
        var decls = std.ArrayList(Ast.Decl){};
        try b.collectTopDecls(tdl_node, &decls);
        return .{
            .file  = "",
            .decls = try decls.toOwnedSlice(b.arena),
        };
    }

    // ── TopDeclList (left-recursive) ──────────────────────────────────────────

    fn collectTopDecls(b: Builder, node: TN, out: *std.ArrayList(Ast.Decl)) !void {
        switch (node) {
            .epsilon => return,
            .inner   => |inner| {
                const kids = inner.children;
                if (kids.len == 0) return;
                if (kids.len == 1) {
                    // TopDeclList → TopDecl
                    try out.append(b.arena, try b.buildTopDecl(kids[0]));
                } else {
                    try b.collectTopDecls(kids[0], out);
                    // TopDeclList → TopDeclList eol  (blank line — skip)
                    if (kids[1] == .leaf) return;
                    // TopDeclList → TopDeclList TopDecl
                    try out.append(b.arena, try b.buildTopDecl(kids[1]));
                }
            },
            .leaf => unreachable,
        }
    }

    fn buildTopDecl(b: Builder, node: TN) anyerror!Ast.Decl {
        const decl_node = singleChild(node);
        return switch (ntOf(decl_node)) {
            .UseDecl       => .{ .use       = try b.box(Ast.DeclUse,       try b.buildUseDecl(decl_node)) },
            .NamespaceDecl => .{ .namespace = try b.box(Ast.DeclNamespace, try b.buildNamespaceDecl(decl_node)) },
            .ClassDecl     => .{ .class     = try b.box(Ast.DeclClass,     try b.buildClassDecl(decl_node)) },
            .InterfaceDecl => .{ .interface = try b.box(Ast.DeclInterface, try b.buildInterfaceDecl(decl_node)) },
            .StructDecl    => .{ .struct_   = try b.box(Ast.DeclStruct,    try b.buildStructDecl(decl_node)) },
            .MixinDecl     => .{ .mixin     = try b.box(Ast.DeclMixin,     try b.buildMixinDecl(decl_node)) },
            .EnumDecl      => .{ .enum_     = try b.box(Ast.DeclEnum,      try b.buildEnumDecl(decl_node)) },
            .ExtendDecl    => .{ .extend    = try b.box(Ast.DeclExtend,    try b.buildExtendDecl(decl_node)) },
            .DeclUnion     => .{ .union_    = try b.box(Ast.DeclUnion,      try b.buildDeclUnion(decl_node)) },
            .AspectDecl    => @panic("TODO: AspectDecl"),
            .WeaveDecl     => @panic("TODO: WeaveDecl"),
            .AtDirective   => @panic("TODO: top-level AtDirective"),
            else => std.debug.panic("buildTopDecl: unexpected NT {s}", .{@tagName(ntOf(decl_node))}),
        };
    }

    // ── Use directive ─────────────────────────────────────────────────────────

    fn buildUseDecl(b: Builder, node: TN) anyerror!Ast.DeclUse {
        // use UsePath eol
        const kids = ch(node);
        return .{
            .span = spanOf(node, b.tokens),
            .path = spanText(kids[1], b.tokens),
        };
    }

    // ── Namespace ─────────────────────────────────────────────────────────────

    fn buildNamespaceDecl(b: Builder, node: TN) anyerror!Ast.DeclNamespace {
        // kw_namespace UsePath eol indent TopDeclList dedent
        const kids = ch(node);
        var decls = std.ArrayList(Ast.Decl){};
        try b.collectTopDecls(kids[4], &decls);
        return .{
            .span  = spanOf(node, b.tokens),
            .name  = spanText(kids[1], b.tokens),
            .decls = try decls.toOwnedSlice(b.arena),
        };
    }

    // ── Modifiers ─────────────────────────────────────────────────────────────

    fn buildModList(b: Builder, node: TN) Ast.Modifiers {
        _ = b;
        var m = Ast.Modifiers{};
        collectMods(node, &m);
        return m;
    }

    fn collectMods(node: TN, m: *Ast.Modifiers) void {
        switch (node) {
            .epsilon => return,
            .inner   => |inner| {
                const kids = inner.children;
                if (kids.len < 2) return;
                // ModList → ModList keyword
                collectMods(kids[0], m);
                switch (kids[1].leaf.token) {
                    .kw_public    => m.public    = true,
                    .kw_private   => m.private   = true,
                    .kw_protected => m.protected = true,
                    .kw_internal  => m.internal  = true,
                    .kw_abstract  => m.abstract  = true,
                    .kw_shared    => m.shared    = true,
                    .kw_readonly  => m.readonly  = true,
                    .kw_extern    => m.extern_   = true,
                    else => {},
                }
            },
            .leaf => {},
        }
    }

    // ── Class declaration ─────────────────────────────────────────────────────
    //
    // ModList kw_class id ClassHeader IsClauseOpt HasOpt WeavesOpt eol
    // indent MemberDeclList dedent
    // idx: 0         1        2  3           4            5      6         7
    //      8      9              10

    fn buildClassDecl(b: Builder, node: TN) anyerror!Ast.DeclClass {
        const kids = ch(node);
        var implements = std.ArrayList(Ast.TypeRef){};
        var adds       = std.ArrayList(Ast.TypeRef){};
        try b.collectClassHeader(kids[3], &implements, &adds);
        return .{
            .span       = spanOf(node, b.tokens),
            .mods       = b.buildModList(kids[0]),
            .name       = leafText(kids[2], b.tokens),
            .implements = try implements.toOwnedSlice(b.arena),
            .adds       = try adds.toOwnedSlice(b.arena),
            .invariants = &.{},
            .members    = try b.buildMemberDeclList(kids[9]),
        };
    }

    fn collectClassHeader(b: Builder, node: TN, impls: *std.ArrayList(Ast.TypeRef), adds: *std.ArrayList(Ast.TypeRef)) anyerror!void {
        // ClassHeader → ImplementsClauseOpt AddsClauseOpt  (both opts can be ε)
        switch (node) {
            .epsilon => return,
            .inner   => |inner| {
                if (inner.children.len < 2) return;
                try b.collectOptTypeList(inner.children[0], impls);
                try b.collectOptTypeList(inner.children[1], adds);
            },
            .leaf => {},
        }
    }

    fn collectOptTypeList(b: Builder, node: TN, out: *std.ArrayList(Ast.TypeRef)) !void {
        switch (node) {
            .epsilon => return,
            .inner   => |inner| {
                // ε → 0 children; present → kw_implements/kw_adds TypeRefListNE
                if (inner.children.len < 2) return;
                try b.collectTypeRefListNE(inner.children[1], out);
            },
            .leaf => {},
        }
    }

    fn collectTypeRefListNE(b: Builder, node: TN, out: *std.ArrayList(Ast.TypeRef)) !void {
        // TypeRef | TypeRefListNE , TypeRef
        const kids = ch(node);
        if (kids.len == 1) {
            try out.append(b.arena,try b.buildTypeRef(kids[0]));
        } else { // 3: list , TypeRef
            try b.collectTypeRefListNE(kids[0], out);
            try out.append(b.arena,try b.buildTypeRef(kids[2]));
        }
    }

    // ── Interface declaration ─────────────────────────────────────────────────
    //
    // ModList kw_interface id InterfaceHeader IsClauseOpt HasOpt WeavesOpt eol
    // indent MemberDeclList dedent
    // MemberDeclList is at index 9.

    fn buildInterfaceDecl(b: Builder, node: TN) anyerror!Ast.DeclInterface {
        const kids = ch(node);
        var implements = std.ArrayList(Ast.TypeRef){};
        switch (kids[3]) {
            .inner => |inner| {
                if (inner.children.len >= 2)
                    try b.collectTypeRefListNE(inner.children[1], &implements);
            },
            else => {},
        }
        return .{
            .span       = spanOf(node, b.tokens),
            .mods       = b.buildModList(kids[0]),
            .name       = leafText(kids[2], b.tokens),
            .implements = try implements.toOwnedSlice(b.arena),
            .members    = try b.buildMemberDeclList(kids[9]),
        };
    }

    // ── Struct declaration ────────────────────────────────────────────────────
    //
    // ModList kw_struct id StructHeader IsClauseOpt HasOpt WeavesOpt eol
    // indent MemberDeclList dedent
    // MemberDeclList is at index 9.

    fn buildStructDecl(b: Builder, node: TN) anyerror!Ast.DeclStruct {
        const kids = ch(node);
        var implements = std.ArrayList(Ast.TypeRef){};
        switch (kids[3]) {
            .inner => |inner| {
                if (inner.children.len >= 2)
                    try b.collectTypeRefListNE(inner.children[1], &implements);
            },
            else => {},
        }
        return .{
            .span       = spanOf(node, b.tokens),
            .mods       = b.buildModList(kids[0]),
            .name       = leafText(kids[2], b.tokens),
            .implements = try implements.toOwnedSlice(b.arena),
            .invariants = &.{},
            .members    = try b.buildMemberDeclList(kids[9]),
        };
    }

    // ── Mixin declaration ─────────────────────────────────────────────────────
    //
    // ModList kw_mixin id IsClauseOpt HasOpt WeavesOpt eol
    // indent MemberDeclList dedent
    // MemberDeclList is at index 8.

    fn buildMixinDecl(b: Builder, node: TN) anyerror!Ast.DeclMixin {
        const kids = ch(node);
        return .{
            .span    = spanOf(node, b.tokens),
            .mods    = b.buildModList(kids[0]),
            .name    = leafText(kids[2], b.tokens),
            .members = try b.buildMemberDeclList(kids[8]),
        };
    }

    // ── Enum declaration ──────────────────────────────────────────────────────
    //
    // ModList kw_enum id eol indent EnumMemberList dedent
    // EnumMemberList is at index 5.

    fn buildEnumDecl(b: Builder, node: TN) anyerror!Ast.DeclEnum {
        const kids = ch(node);
        var members = std.ArrayList(Ast.EnumMember){};
        try b.collectEnumMembers(kids[5], &members);
        return .{
            .span    = spanOf(node, b.tokens),
            .mods    = b.buildModList(kids[0]),
            .name    = leafText(kids[2], b.tokens),
            .base    = null,
            .members = try members.toOwnedSlice(b.arena),
        };
    }

    fn collectEnumMembers(b: Builder, node: TN, out: *std.ArrayList(Ast.EnumMember)) !void {
        // EnumMember | EnumMemberList EnumMember
        const kids = ch(node);
        if (kids.len == 1) {
            try out.append(b.arena,try b.buildEnumMember(kids[0]));
        } else {
            try b.collectEnumMembers(kids[0], out);
            try out.append(b.arena,try b.buildEnumMember(kids[1]));
        }
    }

    fn buildEnumMember(b: Builder, node: TN) anyerror!Ast.EnumMember {
        // Plain:   id eol            (2 children, kids[0] is id leaf)
        // Valued:  id = Expr eol     (4 children, kids[1] is assign leaf)
        // Payload: open_call ParamList rparen eol  (4 children, kids[0] is open_call leaf)
        const kids = ch(node);
        const name_raw = leafText(kids[0], b.tokens);
        // open_call token text is already just the identifier (no `(` in text).
        const name = name_raw;
        const value: ?*Ast.Expr = if (kids.len == 4 and isLeafKind(kids[1], .assign))
            try b.box(Ast.Expr, try b.buildExpr(kids[2]))
        else
            null;
        return .{
            .span  = spanOf(node, b.tokens),
            .name  = name,
            .value = value,
        };
    }

    // ── Extend declaration ────────────────────────────────────────────────────
    //
    // ModList kw_extend TypeRef IsClauseOpt HasOpt WeavesOpt eol
    // indent MemberDeclList dedent
    // MemberDeclList is at index 8.

    fn buildExtendDecl(b: Builder, node: TN) anyerror!Ast.DeclExtend {
        const kids = ch(node);
        return .{
            .span    = spanOf(node, b.tokens),
            .target  = try b.buildTypeRef(kids[2]),
            .members = try b.buildMemberDeclList(kids[8]),
        };
    }

    // ── Member declaration list ───────────────────────────────────────────────

    fn buildMemberDeclList(b: Builder, node: TN) anyerror![]const Ast.Decl {
        var out = std.ArrayList(Ast.Decl){};
        try b.collectMemberDecls(node, &out);
        return out.toOwnedSlice(b.arena);
    }

    fn collectMemberDecls(b: Builder, node: TN, out: *std.ArrayList(Ast.Decl)) anyerror!void {
        switch (node) {
            .epsilon => return,
            .inner   => |inner| {
                const kids = inner.children;
                if (kids.len == 0) return;
                if (kids.len == 1) {
                    if (kids[0] == .epsilon) return;
                    return;
                }
                try b.collectMemberDecls(kids[0], out);
                // MemberDeclList → MemberDeclList eol  (blank line — skip)
                if (kids[1] == .leaf) return;
                // MemberDeclList → MemberDeclList MemberDecl
                const inner_decl = singleChild(kids[1]);
                switch (ntOf(inner_decl)) {
                    // SharedGroupDecl expands to multiple members — handle inline.
                    .SharedGroupDecl => try b.collectSharedGroupDecl(inner_decl, out),
                    // These carry no code-gen payload; skip silently.
                    .TestMemberDecl,
                    .InvariantDecl,
                    .AtDirective,
                    .AspectDecl      => {},
                    else             => try out.append(b.arena, try b.buildMemberDecl(kids[1])),
                }
            },
            .leaf => {},
        }
    }

    /// `shared` block: build all inner members and mark each as `shared`.
    fn collectSharedGroupDecl(b: Builder, node: TN, out: *std.ArrayList(Ast.Decl)) !void {
        // SharedGroupDecl → kw_shared eol indent MemberDeclList dedent
        const kids = ch(node);
        const start = out.items.len;
        try b.collectMemberDecls(kids[3], out);
        for (out.items[start..]) |*d| setShared(d);
    }

    fn buildMemberDecl(b: Builder, node: TN) anyerror!Ast.Decl {
        const inner_node = singleChild(node);
        return switch (ntOf(inner_node)) {
            .MethodDecl    => .{ .method   = try b.box(Ast.DeclMethod,   try b.buildMethodDecl(inner_node)) },
            .VarMemberDecl => .{ .var_     = try b.box(Ast.DeclVar,      try b.buildVarMemberDecl(inner_node)) },
            .InitDecl      => .{ .init     = try b.box(Ast.DeclInit,     try b.buildInitDecl(inner_node)) },
            .PropDecl      => .{ .property = try b.box(Ast.DeclProperty, try b.buildPropDecl(inner_node)) },
            .ProDecl       => .{ .property = try b.box(Ast.DeclProperty, try b.buildProDecl(inner_node)) },
            .SharedGroupDecl,
            .TestMemberDecl,
            .InvariantDecl,
            .AtDirective,
            .AspectDecl      => unreachable, // filtered out in collectMemberDecls
            else => std.debug.panic("buildMemberDecl: unexpected NT {s}", .{@tagName(ntOf(inner_node))}),
        };
    }

    // ── Method declaration ────────────────────────────────────────────────────
    //
    // With params: ModList kw_def open_call ParamList rparen ReturnAnnotOpt IsClauseOpt HasOpt WeavesOpt eol [Block|ContractBlock]
    //  idx:        0       1      2         3         4       5              6           7      8         9   10?
    //
    // No-arg:      ModList kw_def id ReturnAnnotOpt IsClauseOpt HasOpt WeavesOpt eol [Block|ContractBlock]
    //  idx:        0       1      2  3              4           5      6         7   8?

    fn buildMethodDecl(b: Builder, node: TN) anyerror!Ast.DeclMethod {
        const kids = ch(node);
        const mods = b.buildModList(kids[0]);
        const has_params = isLeafKind(kids[2], .open_call);

        // open_call text already excludes the `(` (the tokenizer strips it)
        const name = leafText(kids[2], b.tokens);

        var params:     []const Ast.Param = &.{};
        var return_idx: usize = 0;

        if (has_params) {
            params      = try b.buildParamList(kids[3]);
            return_idx  = 5; // after rparen
        } else {
            return_idx  = 3;
        }

        const ret   = try b.buildReturnAnnotOpt(kids[return_idx]);
        const last  = kids[kids.len - 1];

        var body:     ?[]const Ast.Stmt = null;
        var require_: []const *Ast.Expr = &.{};
        var ensure_:  []const *Ast.Expr = &.{};
        var throws    = false;

        // Scan remaining optional clauses: ThrowsOpt, IsClauseOpt, HasOpt, WeavesOpt, Block/ContractBlock
        for (kids[return_idx + 1..]) |kid| {
            if (kid != .inner) continue;
            switch (ntOf(kid)) {
                .ThrowsOpt     => throws = ch(kid).len > 0,
                .Block         => body = try b.buildBlock(kid),
                .ContractBlock => {
                    const cb = try b.buildContractBlock(kid);
                    require_ = cb.require;
                    ensure_  = cb.ensure;
                    body     = cb.body;
                },
                else => {},
            }
        }
        _ = last; // no longer used directly

        return .{
            .span        = spanOf(node, b.tokens),
            .mods        = mods,
            .name        = name,
            .type_params = &.{},
            .params      = params,
            .return_type = ret,
            .require     = require_,
            .ensure      = ensure_,
            .body        = body,
            .is_test     = false,
            .throws      = throws,
        };
    }

    // ── Property declarations (get / set) ─────────────────────────────────────

    fn buildPropDecl(b: Builder, node: TN) anyerror!Ast.DeclProperty {
        const kids = ch(node);
        const mods = b.buildModList(kids[0]);
        const kw   = kids[1].leaf.token;
        // open_call text already excludes `(`
        const name = leafText(kids[2], b.tokens);

        var getter: ?[]const Ast.Stmt = null;
        var setter: ?[]const Ast.Stmt = null;
        var type_:  ?Ast.TypeRef      = null;

        for (kids[3..]) |kid| {
            if (kid != .inner) continue;
            switch (ntOf(kid)) {
                .ReturnAnnotOpt => type_ = try b.buildReturnAnnotOpt(kid),
                .Block => {
                    const stmts = try b.buildBlock(kid);
                    if (kw == .kw_get) getter = stmts else setter = stmts;
                },
                else => {},
            }
        }

        return .{
            .span   = spanOf(node, b.tokens),
            .mods   = mods,
            .name   = name,
            .type_  = type_,
            .getter = getter,
            .setter = setter,
        };
    }

    fn buildProDecl(b: Builder, node: TN) anyerror!Ast.DeclProperty {
        const kids = ch(node);
        const mods = b.buildModList(kids[0]);
        const name = leafText(kids[2], b.tokens);
        var type_:  ?Ast.TypeRef      = null;
        var getter: ?[]const Ast.Stmt = null;
        var setter: ?[]const Ast.Stmt = null;

        for (kids[3..]) |kid| {
            if (kid != .inner) continue;
            switch (ntOf(kid)) {
                .ReturnAnnotOpt => type_ = try b.buildReturnAnnotOpt(kid),
                .PropBodyOpt    => {
                    const pk = ch(kid);
                    // PropBodyOpt → ε  |  indent PropBodyListNE dedent
                    if (pk.len >= 3) try b.collectPropBody(pk[1], &getter, &setter);
                },
                else => {},
            }
        }

        return .{
            .span   = spanOf(node, b.tokens),
            .mods   = mods,
            .name   = name,
            .type_  = type_,
            .getter = getter,
            .setter = setter,
        };
    }

    fn collectPropBody(b: Builder, node: TN, getter: *?[]const Ast.Stmt, setter: *?[]const Ast.Stmt) anyerror!void {
        // PropBodyListNE → PropBodyItem | PropBodyListNE PropBodyItem
        const kids = ch(node);
        if (kids.len == 1) {
            try b.applyPropBodyItem(kids[0], getter, setter);
        } else {
            try b.collectPropBody(kids[0], getter, setter);
            try b.applyPropBodyItem(kids[1], getter, setter);
        }
    }

    fn applyPropBodyItem(b: Builder, node: TN, getter: *?[]const Ast.Stmt, setter: *?[]const Ast.Stmt) anyerror!void {
        // PropBodyItem → kw_get eol Block | kw_set eol Block
        const kids = ch(node);
        const stmts = try b.buildBlock(kids[2]);
        if (isLeafKind(kids[0], .kw_get)) getter.* = stmts else setter.* = stmts;
    }

    // ── Var member ────────────────────────────────────────────────────────────
    //
    // ModList kw_var   id VarTypeOpt VarInitOpt eol
    // ModList kw_const id VarTypeOpt = Expr eol

    fn buildVarMemberDecl(b: Builder, node: TN) anyerror!Ast.DeclVar {
        // kids: ModList  kw_var/kw_const  id  VarTypeOpt  VarInitOpt/assign Expr  eol
        const kids  = ch(node);
        const mods  = b.buildModList(kids[0]);
        const is_const = isLeafKind(kids[1], .kw_const);
        const name  = leafText(kids[2], b.tokens);
        var type_:  ?Ast.TypeRef = null;
        var init_:  ?*Ast.Expr  = null;

        for (kids[3..]) |kid| {
            if (kid != .inner) continue;
            switch (ntOf(kid)) {
                .VarTypeOpt => type_ = try b.buildReturnAnnotOpt(kid),
                .VarInitOpt => {
                    const vk = ch(kid);
                    if (vk.len >= 2) init_ = try b.box(Ast.Expr, try b.buildExpr(vk[1]));
                },
                .Expr => init_ = try b.box(Ast.Expr, try b.buildExpr(kid)),
                else => {},
            }
        }

        return .{
            .span     = spanOf(node, b.tokens),
            .mods     = mods,
            .name     = name,
            .type_    = type_,
            .init     = init_,
            .is_const = is_const,
        };
    }

    // ── Constructor ───────────────────────────────────────────────────────────
    //
    // ModList kw_cue open_call ParamList rparen eol [Block]

    fn buildInitDecl(b: Builder, node: TN) anyerror!Ast.DeclInit {
        const kids   = ch(node);
        const params = try b.buildParamList(kids[3]);
        // Optional body is the last child if it is a Block
        const body: ?[]const Ast.Stmt = if (kids.len > 6 and kids[6] == .inner and ntOf(kids[6]) == .Block)
            try b.buildBlock(kids[6])
        else
            null;
        return .{
            .span    = spanOf(node, b.tokens),
            .mods    = b.buildModList(kids[0]),
            .params  = params,
            .require = &.{},
            .ensure  = &.{},
            .body    = body,
        };
    }

    // ── Contract block ────────────────────────────────────────────────────────
    //
    // indent ContractClauseListNE dedent

    const ContractResult = struct {
        require: []const *Ast.Expr,
        ensure:  []const *Ast.Expr,
        body:    ?[]const Ast.Stmt,
    };

    fn buildContractBlock(b: Builder, node: TN) anyerror!ContractResult {
        const clause_list = ch(node)[1];
        var require = std.ArrayList(*Ast.Expr){};
        var ensure  = std.ArrayList(*Ast.Expr){};
        var body:   ?[]const Ast.Stmt = null;

        var clauses = std.ArrayList(TN){};
        defer clauses.deinit(b.arena);
        try b.flattenContractClauses(clause_list, &clauses);

        for (clauses.items) |clause| {
            const ck = ch(clause);
            const kw = ck[0].leaf.token;
            const block_stmts = try b.buildBlock(ck[2]);
            switch (kw) {
                .kw_require => {
                    for (block_stmts) |stmt| {
                        if (stmt == .expr) try require.append(b.arena,stmt.expr);
                    }
                },
                .kw_ensure => {
                    for (block_stmts) |stmt| {
                        if (stmt == .expr) try ensure.append(b.arena,stmt.expr);
                    }
                },
                .kw_body => body = block_stmts,
                else => {},
            }
        }

        return .{
            .require = try require.toOwnedSlice(b.arena),
            .ensure  = try ensure.toOwnedSlice(b.arena),
            .body    = body,
        };
    }

    fn flattenContractClauses(b: Builder, node: TN, out: *std.ArrayList(TN)) !void {
        const kids = ch(node);
        if (kids.len == 1) {
            try out.append(b.arena,kids[0]);
        } else {
            try b.flattenContractClauses(kids[0], out);
            try out.append(b.arena,kids[1]);
        }
    }

    // ── Parameters ────────────────────────────────────────────────────────────

    fn buildParamList(b: Builder, node: TN) anyerror![]const Ast.Param {
        switch (node) {
            .epsilon => return &.{},
            .inner   => |inner| {
                if (inner.children.len == 0) return &.{};
                var out = std.ArrayList(Ast.Param){};
                try b.flattenParamListNE(inner.children[0], &out);
                return out.toOwnedSlice(b.arena);
            },
            .leaf => return &.{},
        }
    }

    fn flattenParamListNE(b: Builder, node: TN, out: *std.ArrayList(Ast.Param)) !void {
        // Param | ParamListNE , Param
        const kids = ch(node);
        if (kids.len == 1) {
            try out.append(b.arena,try b.buildParam(kids[0]));
        } else {
            try b.flattenParamListNE(kids[0], out);
            try out.append(b.arena,try b.buildParam(kids[2]));
        }
    }

    fn buildParam(b: Builder, node: TN) anyerror!Ast.Param {
        // ParamModeOpt id [as TypeRef] [= Expr]
        const kids = ch(node);
        const mode: Ast.ParamMode = blk: {
            switch (kids[0]) {
                .epsilon => break :blk .normal,
                .inner   => |inner| {
                    if (inner.children.len == 0) break :blk .normal;
                    break :blk switch (inner.children[0].leaf.token) {
                        .kw_vari => .vari,
                        else     => .normal,
                    };
                },
                .leaf => break :blk .normal,
            }
        };

        const name = leafText(kids[1], b.tokens);
        var type_:   ?Ast.TypeRef = null;
        var default: ?*Ast.Expr  = null;
        var idx: usize = 2;

        if (idx < kids.len and isLeafKind(kids[idx], .kw_as)) {
            idx += 1;
            type_ = try b.buildTypeRef(kids[idx]);
            idx  += 1;
        }
        if (idx < kids.len and isLeafKind(kids[idx], .assign)) {
            idx    += 1;
            default = try b.box(Ast.Expr, try b.buildExpr(kids[idx]));
        }

        return .{
            .span    = spanOf(node, b.tokens),
            .mode    = mode,
            .name    = name,
            .type_   = type_,
            .default = default,
        };
    }

    // ── Return annotation / var type ──────────────────────────────────────────
    //
    // ReturnAnnotOpt / VarTypeOpt → ε | kw_as TypeRef

    fn buildReturnAnnotOpt(b: Builder, node: TN) anyerror!?Ast.TypeRef {
        switch (node) {
            .epsilon => return null,
            .inner   => |inner| {
                if (inner.children.len < 2) return null;
                return try b.buildTypeRef(inner.children[1]);
            },
            .leaf => return null,
        }
    }

    // ── Type references ───────────────────────────────────────────────────────

    fn buildTypeRef(b: Builder, node: TN) anyerror!Ast.TypeRef {
        const kids = ch(node);
        return switch (kids.len) {
            1 => blk: {
                const kid = kids[0];
                if (kid == .leaf) {
                    const tok  = kid.leaf.token;
                    const text = leafText(kid, b.tokens);
                    break :blk switch (tok) {
                        .id         => .{ .named = .{ .span = leafSpan(kid, b.tokens), .name = text } },
                        .kw_int     => .{ .named = .{ .span = leafSpan(kid, b.tokens), .name = "int" } },
                        .kw_uint    => .{ .named = .{ .span = leafSpan(kid, b.tokens), .name = "uint" } },
                        .kw_float   => .{ .named = .{ .span = leafSpan(kid, b.tokens), .name = "float" } },
                        .kw_bool    => .{ .named = .{ .span = leafSpan(kid, b.tokens), .name = "bool" } },
                        .kw_char    => .{ .named = .{ .span = leafSpan(kid, b.tokens), .name = "char" } },
                        .kw_same    => .same,
                        .int_size, .uint_size, .float_size
                                    => .{ .named = .{ .span = leafSpan(kid, b.tokens), .name = text } },
                        else => std.debug.panic("buildTypeRef leaf: unexpected token {s}", .{@tagName(tok)}),
                    };
                }
                // Single inner child wrapping a TypeRef
                break :blk try b.buildTypeRef(kid);
            },
            2 => blk: {
                if (isLeafKind(kids[0], .bang)) {
                    // !T — error union
                    const inner = try b.box(Ast.TypeRef, try b.buildTypeRef(kids[1]));
                    break :blk .{ .error_union = inner };
                }
                if (isLeafKind(kids[1], .question)) {
                    // T? — nilable
                    const inner = try b.box(Ast.TypeRef, try b.buildTypeRef(kids[0]));
                    break :blk .{ .nilable = inner };
                }
                if (isLeafKind(kids[1], .star)) {
                    // T* — stream
                    const inner = try b.box(Ast.TypeRef, try b.buildTypeRef(kids[0]));
                    break :blk .{ .stream = inner };
                }
                std.debug.panic("buildTypeRef 2-child: unhandled", .{});
            },
            3 => blk: {
                if (isLeafKind(kids[0], .open_call)) {
                    // open_call TypeRefListNE rparen — generic type e.g. List(int)
                    const name = leafText(kids[0], b.tokens);
                    const args = try b.buildTypeRefListNE(kids[1]);
                    break :blk .{ .generic = .{
                        .span = spanOf(node, b.tokens),
                        .name = name,
                        .args = args,
                    }};
                }
                // TypeRef . id — qualified name; return the full span text
                const full = spanText(node, b.tokens);
                break :blk .{ .named = .{ .span = spanOf(node, b.tokens), .name = full } };
            },
            4 => blk: {
                // kw_int/kw_uint/kw_float + lparen + integer_lit + rparen
                // e.g. int(5), uint(32), float(16)
                // Normalise to the "intN"/"uintN"/"floatN" named form so the
                // rest of the pipeline (Resolver, TypeChecker, CodeGen) is uniform.
                const kw_tok    = kids[0].leaf.token;
                const bits_text = leafText(kids[2], b.tokens);
                const prefix: []const u8 = switch (kw_tok) {
                    .kw_int   => "int",
                    .kw_uint  => "uint",
                    .kw_float => "float",
                    else => std.debug.panic("buildTypeRef 4-child: unexpected token {s}", .{@tagName(kw_tok)}),
                };
                const full_name = try std.fmt.allocPrint(b.arena, "{s}{s}", .{ prefix, bits_text });
                break :blk .{ .named = .{ .span = spanOf(node, b.tokens), .name = full_name } };
            },
            else => std.debug.panic("buildTypeRef: child count {}", .{kids.len}),
        };
    }

    fn buildTypeRefListNE(b: Builder, node: TN) anyerror![]const Ast.TypeRef {
        var out = std.ArrayList(Ast.TypeRef){};
        try b.collectTypeRefs(node, &out);
        return out.toOwnedSlice(b.arena);
    }

    fn collectTypeRefs(b: Builder, node: TN, out: *std.ArrayList(Ast.TypeRef)) anyerror!void {
        const kids = ch(node);
        if (kids.len == 1) {
            try out.append(b.arena, try b.buildTypeRef(kids[0]));
        } else {
            // TypeRefListNE comma TypeRef
            try b.collectTypeRefs(kids[0], out);
            try out.append(b.arena, try b.buildTypeRef(kids[2]));
        }
    }

    // ── Block and statements ──────────────────────────────────────────────────

    fn buildBlock(b: Builder, node: TN) anyerror![]const Ast.Stmt {
        // Block → indent StmtList dedent
        return b.buildStmtList(ch(node)[1]);
    }

    fn buildStmtList(b: Builder, node: TN) anyerror![]const Ast.Stmt {
        var out = std.ArrayList(Ast.Stmt){};
        try b.collectStmts(node, &out);
        return out.toOwnedSlice(b.arena);
    }

    fn collectStmts(b: Builder, node: TN, out: *std.ArrayList(Ast.Stmt)) !void {
        const kids = ch(node);
        if (kids.len == 1) {
            // StmtList → Stmt
            try out.append(b.arena, try b.buildStmt(kids[0]));
        } else {
            try b.collectStmts(kids[0], out);
            // StmtList → StmtList eol  (blank line — skip)
            if (kids[1] == .leaf) return;
            // StmtList → StmtList Stmt
            try out.append(b.arena, try b.buildStmt(kids[1]));
        }
    }

    fn buildStmt(b: Builder, node: TN) anyerror!Ast.Stmt {
        // Stmt → StmtXxx  (single-child dispatch node)
        const inner = singleChild(node);
        const s     = spanOf(inner, b.tokens);
        const kids  = ch(inner);

        return switch (ntOf(inner)) {
            .StmtReturn => blk: {
                const val: ?*Ast.Expr = if (kids.len > 2)
                    try b.box(Ast.Expr, try b.buildExpr(kids[1]))
                else
                    null;
                break :blk .{ .return_ = try b.box(Ast.StmtReturn, .{ .span = s, .value = val }) };
            },
            .StmtPrint    => .{ .print = try b.box(Ast.StmtPrint, .{
                .span = s,
                .args = try b.buildExprListPtrs(kids[1]),
            }) },
            .StmtPass     => .{ .pass      = s },
            .StmtBreak    => .{ .break_    = s },
            .StmtContinue => .{ .continue_ = s },
            .StmtYield    => .{ .yield = try b.box(Ast.StmtYield, .{
                .span  = s,
                .value = try b.box(Ast.Expr, try b.buildExpr(kids[1])),
            }) },
            .StmtAssert => .{ .assert = try b.box(Ast.StmtAssert, .{
                .span    = s,
                .cond    = try b.box(Ast.Expr, try b.buildExpr(kids[1])),
                .message = if (kids.len == 5) try b.box(Ast.Expr, try b.buildExpr(kids[3])) else null,
            }) },
            .StmtIf       => .{ .if_    = try b.box(Ast.StmtIf,    try b.buildStmtIf(inner)) },
            .StmtWhile    => .{ .while_ = try b.box(Ast.StmtWhile, try b.buildStmtWhile(inner)) },
            .StmtPostWhile => .{ .while_ = try b.box(Ast.StmtWhile, try b.buildStmtPostWhile(inner)) },
            .StmtForIn    => .{ .for_in  = try b.box(Ast.StmtForIn,  try b.buildStmtForIn(inner)) },
            .StmtForNum   => .{ .for_num = try b.box(Ast.StmtForNum, try b.buildStmtForNum(inner)) },
            .StmtBranch   => .{ .branch  = try b.box(Ast.StmtBranch, try b.buildStmtBranch(inner)) },
            .StmtLocalVar       => try b.buildStmtLocalVarDispatch(inner),
            .StmtLocalVarLambda => try b.buildStmtLocalVarLambda(inner),
            .StmtAssign   => try b.buildStmtAssignDispatch(inner),
            .StmtExpr     => .{ .expr    = try b.box(Ast.Expr,       try b.buildExpr(kids[0])) },
            .StmtDefer    => .{ .defer_    = try b.box(Ast.StmtDefer,    try b.buildStmtDefer(inner)) },
            .StmtWith     => .{ .with      = try b.box(Ast.StmtWith,     try b.buildStmtWith(inner)) },
            .StmtRaise    => .{ .raise     = try b.box(Ast.StmtRaise,    try b.buildStmtRaise(inner)) },
            .StmtTryCatch => .{ .try_catch = try b.box(Ast.StmtTryCatch, try b.buildStmtTryCatch(inner)) },
            .StmtExpect   => @panic("TODO: StmtExpect"),
            .StmtLock     => @panic("TODO: StmtLock"),
            else => std.debug.panic("buildStmt: unexpected NT {s}", .{@tagName(ntOf(inner))}),
        };
    }

    // ── Individual statement builders ─────────────────────────────────────────

    fn buildStmtIf(b: Builder, node: TN) anyerror!Ast.StmtIf {
        // kw_if Expr eol Block IfTail
        const kids = ch(node);
        var else_ifs  = std.ArrayList(Ast.ElseIf){};
        var else_body: ?[]const Ast.Stmt = null;
        try b.collectIfTail(kids[4], &else_ifs, &else_body);
        return .{
            .span      = spanOf(node, b.tokens),
            .cond      = try b.box(Ast.Expr, try b.buildExpr(kids[1])),
            .then_body = try b.buildBlock(kids[3]),
            .else_ifs  = try else_ifs.toOwnedSlice(b.arena),
            .else_body = else_body,
        };
    }

    fn collectIfTail(b: Builder, node: TN, else_ifs: *std.ArrayList(Ast.ElseIf), else_body: *?[]const Ast.Stmt) !void {
        // IfTail → ε | ElseIfClause IfTail | ElseClauseOpt
        switch (node) {
            .epsilon => return,
            .inner   => |inner| {
                const kids = inner.children;
                if (kids.len == 0) return;
                if (kids[0] != .inner) return;
                switch (ntOf(kids[0])) {
                    .ElseIfClause => {
                        const ek = ch(kids[0]);
                        try else_ifs.append(b.arena,.{
                            .span = spanOf(kids[0], b.tokens),
                            .cond = try b.box(Ast.Expr, try b.buildExpr(ek[2])),
                            .body = try b.buildBlock(ek[4]),
                        });
                        try b.collectIfTail(kids[1], else_ifs, else_body);
                    },
                    .ElseClauseOpt => {
                        const ek = ch(kids[0]);
                        if (ek.len >= 3) else_body.* = try b.buildBlock(ek[2]);
                    },
                    else => {},
                }
            },
            .leaf => {},
        }
    }

    fn buildStmtWhile(b: Builder, node: TN) anyerror!Ast.StmtWhile {
        // kw_while Expr eol Block [kw_post eol Block]
        const kids = ch(node);
        return .{
            .span      = spanOf(node, b.tokens),
            .cond      = try b.box(Ast.Expr, try b.buildExpr(kids[1])),
            .body      = try b.buildBlock(kids[3]),
            .post_body = if (kids.len > 4) try b.buildBlock(kids[6]) else null,
        };
    }

    fn buildStmtPostWhile(b: Builder, node: TN) anyerror!Ast.StmtWhile {
        // kw_post kw_while Expr eol Block
        const kids = ch(node);
        return .{
            .span      = spanOf(node, b.tokens),
            .cond      = try b.box(Ast.Expr, try b.buildExpr(kids[2])),
            .body      = try b.buildBlock(kids[4]),
            .post_body = null,
        };
    }

    fn buildStmtForIn(b: Builder, node: TN) anyerror!Ast.StmtForIn {
        // kw_for ForVarList kw_in Expr eol Block
        const kids = ch(node);
        var vars = std.ArrayList([]const u8){};
        try b.collectForVarList(kids[1], &vars);
        return .{
            .span  = spanOf(node, b.tokens),
            .vars  = try vars.toOwnedSlice(b.arena),
            .iter  = try b.box(Ast.Expr, try b.buildExpr(kids[3])),
            .where = null,
            .body  = try b.buildBlock(kids[5]),
        };
    }

    fn collectForVarList(b: Builder, node: TN, out: *std.ArrayList([]const u8)) !void {
        // id | ForVarList , id
        const kids = ch(node);
        if (kids.len == 1) {
            try out.append(b.arena,leafText(kids[0], b.tokens));
        } else {
            try b.collectForVarList(kids[0], out);
            try out.append(b.arena,leafText(kids[2], b.tokens));
        }
    }

    fn buildStmtForNum(b: Builder, node: TN) anyerror!Ast.StmtForNum {
        // kw_for id kw_in Expr : Expr eol Block
        // kw_for id kw_in Expr : Expr : Expr eol Block
        const kids = ch(node);
        const has_step = kids.len > 8;
        return .{
            .span  = spanOf(node, b.tokens),
            .var_  = leafText(kids[1], b.tokens),
            .start = try b.box(Ast.Expr, try b.buildExpr(kids[3])),
            .stop  = try b.box(Ast.Expr, try b.buildExpr(kids[5])),
            .step  = if (has_step) try b.box(Ast.Expr, try b.buildExpr(kids[7])) else null,
            .body  = try b.buildBlock(kids[kids.len - 1]),
        };
    }

    fn buildStmtBranch(b: Builder, node: TN) anyerror!Ast.StmtBranch {
        // kw_branch Expr eol indent BranchOnList BranchElseOpt dedent
        const kids = ch(node);
        var ons = std.ArrayList(Ast.BranchOn){};
        try b.collectBranchOnList(kids[4], &ons);
        var else_: ?[]const Ast.Stmt = null;
        try b.collectBranchElse(kids[5], &else_);
        return .{
            .span  = spanOf(node, b.tokens),
            .expr  = try b.box(Ast.Expr, try b.buildExpr(kids[1])),
            .on    = try ons.toOwnedSlice(b.arena),
            .else_ = else_,
        };
    }

    fn collectBranchOnList(b: Builder, node: TN, out: *std.ArrayList(Ast.BranchOn)) !void {
        const kids = ch(node);
        if (kids.len == 1) {
            try out.append(b.arena,try b.buildBranchOnClause(kids[0]));
        } else {
            try b.collectBranchOnList(kids[0], out);
            try out.append(b.arena,try b.buildBranchOnClause(kids[1]));
        }
    }

    fn buildBranchOnClause(b: Builder, node: TN) anyerror!Ast.BranchOn {
        // on ExprListNE eol Block       — value list form
        // on ExprListNE , Stmt          — inline form
        // on Expr as id eol Block       — union binding form (kids.len == 6)
        const kids = ch(node);

        // Detect union binding form: kids[2] is kw_as
        if (kids.len == 6 and isLeafKind(kids[2], .kw_as)) {
            const expr    = try b.box(Ast.Expr, try b.buildExpr(kids[1]));
            const binding = leafText(kids[3], b.tokens);
            const body    = try b.buildBlock(kids[5]);
            return .{
                .span    = spanOf(node, b.tokens),
                .values  = try b.arena.dupe(*Ast.Expr, &.{expr}),
                .body    = body,
                .binding = binding,
            };
        }

        const values = try b.buildExprListNE(kids[1]);
        const body: []const Ast.Stmt = if (isLeafKind(kids[2], .eol))
            try b.buildBlock(kids[3])
        else blk: {
            var tmp = try b.arena.alloc(Ast.Stmt, 1);
            tmp[0] = try b.buildStmt(kids[3]);
            break :blk tmp;
        };
        return .{
            .span   = spanOf(node, b.tokens),
            .values = values,
            .body   = body,
        };
    }

    fn collectBranchElse(b: Builder, node: TN, out: *?[]const Ast.Stmt) anyerror!void {
        // BranchElseOpt → ε | kw_else eol Block | kw_else , Stmt
        switch (node) {
            .epsilon => return,
            .inner   => |inner| {
                const kids = inner.children;
                if (kids.len < 2) return;
                out.* = if (isLeafKind(kids[1], .eol))
                    try b.buildBlock(kids[2])
                else blk: {
                    var tmp = try b.arena.alloc(Ast.Stmt, 1);
                    tmp[0] = try b.buildStmt(kids[2]);
                    break :blk tmp;
                };
            },
            else => {},
        }
    }

    fn buildStmtLocalVar(b: Builder, node: TN) anyerror!Ast.DeclVar {
        // kw_var id VarTypeOpt VarInitOpt eol
        // kw_const id VarTypeOpt = Expr eol
        const kids     = ch(node);
        const is_const = isLeafKind(kids[0], .kw_const);
        const name     = leafText(kids[1], b.tokens);
        var type_:  ?Ast.TypeRef = null;
        var init_:  ?*Ast.Expr  = null;

        var idx: usize = 2;
        // VarTypeOpt is inner if non-empty, or epsilon/inner-with-0-kids if empty.
        // Only consume it if it actually has the `as` keyword (i.e., non-empty).
        if (idx < kids.len) {
            const vto = kids[idx];
            const is_type_opt = (vto == .inner and ntOf(vto) == .VarTypeOpt) or vto == .epsilon;
            if (is_type_opt) {
                type_ = try b.buildReturnAnnotOpt(vto);
                idx  += 1;
            }
        }
        if (idx < kids.len) {
            if (kids[idx] == .inner and ntOf(kids[idx]) == .VarInitOpt) {
                const vk = ch(kids[idx]);
                if (vk.len >= 2) init_ = try b.box(Ast.Expr, try b.buildExpr(vk[1]));
            } else if (isLeafKind(kids[idx], .assign)) {
                init_ = try b.box(Ast.Expr, try b.buildExpr(kids[idx + 1]));
            }
        }

        return .{
            .span     = spanOf(node, b.tokens),
            .mods     = Ast.Modifiers{},
            .name     = name,
            .type_    = type_,
            .init     = init_,
            .is_const = is_const,
        };
    }

    fn buildStmtAssign(b: Builder, node: TN) anyerror!Ast.StmtAssign {
        // Expr AssignOp Expr eol
        const kids = ch(node);
        return .{
            .span   = spanOf(node, b.tokens),
            .target = try b.box(Ast.Expr, try b.buildExpr(kids[0])),
            .op     = buildAssignOp(kids[1]),
            .value  = try b.box(Ast.Expr, try b.buildExpr(kids[2])),
        };
    }

    fn buildAssignOp(node: TN) Ast.AssignOp {
        const leaf = if (node == .inner) node.inner.children[0] else node;
        return switch (leaf.leaf.token) {
            .assign              => .assign,
            .plus_equals         => .plus_eq,
            .minus_equals        => .minus_eq,
            .star_equals         => .star_eq,
            .slash_equals        => .slash_eq,
            .slashslash_equals   => .slashslash_eq,
            .percent_equals      => .percent_eq,
            .starstar_equals     => .starstar_eq,
            .ampersand_equals    => .ampersand_eq,
            .vertical_bar_equals => .vertical_bar_eq,
            .caret_equals        => .caret_eq,
            .double_lt_equals    => .double_lt_eq,
            .double_gt_equals    => .double_gt_eq,
            .question_equals     => .question_eq,
            else => .assign,
        };
    }

    fn buildStmtDefer(b: Builder, node: TN) anyerror!Ast.StmtDefer {
        // kw_defer Stmt  |  kw_errdefer Stmt
        const kids = ch(node);
        return .{
            .span   = spanOf(node, b.tokens),
            .is_err = isLeafKind(kids[0], .kw_errdefer),
            .body   = try b.buildStmt(kids[1]),
        };
    }

    fn buildStmtWith(b: Builder, node: TN) anyerror!Ast.StmtWith {
        // kw_with Expr eol Block
        const kids       = ch(node);
        const block_kids = ch(kids[3]); // Block → indent StmtList dedent
        const span       = spanOf(node, b.tokens);
        const target_expr = try b.box(Ast.Expr, try b.buildExpr(kids[1]));
        const raw_body    = try b.buildStmtList(block_kids[1]);

        // Desugar bare-name assignments: `x = val` → `target.x = val`
        var body = std.ArrayList(Ast.Stmt){};
        for (raw_body) |stmt| {
            if (stmt == .assign) {
                const sa = stmt.assign;
                if (sa.target.* == .ident) {
                    const member_name = sa.target.ident.name;
                    const new_target = try b.box(Ast.Expr, .{ .member = try b.box(Ast.ExprMember, .{
                        .span   = sa.target.ident.span,
                        .object = target_expr,
                        .member = member_name,
                    }) });
                    const new_assign = try b.box(Ast.StmtAssign, .{
                        .span   = sa.span,
                        .target = new_target,
                        .op     = sa.op,
                        .value  = sa.value,
                    });
                    try body.append(b.arena, .{ .assign = new_assign });
                    continue;
                }
            }
            try body.append(b.arena, stmt);
        }

        return .{
            .span   = span,
            .target = target_expr,
            .body   = try body.toOwnedSlice(b.arena),
        };
    }

    fn buildStmtRaise(b: Builder, node: TN) anyerror!Ast.StmtRaise {
        // raise eol  |  raise Expr eol  |  raise Expr , Expr eol
        const kids = ch(node);
        const span = spanOf(node, b.tokens);
        return switch (kids.len) {
            2 => .{ .span = span, .message = null, .details = null },       // raise eol
            3 => .{ .span = span,                                            // raise Expr eol
                .message = try b.box(Ast.Expr, try b.buildExpr(kids[1])),
                .details = null,
            },
            5 => .{ .span = span,                                            // raise Expr , Expr eol
                .message = try b.box(Ast.Expr, try b.buildExpr(kids[1])),
                .details = try b.box(Ast.Expr, try b.buildExpr(kids[3])),
            },
            else => std.debug.panic("buildStmtRaise: unexpected child count {d}", .{kids.len}),
        };
    }

    fn buildStmtTryCatch(b: Builder, node: TN) anyerror!Ast.StmtTryCatch {
        // kw_try eol Block CatchClauseList
        const kids = ch(node);
        var clauses = std.ArrayList(Ast.CatchClause){};
        try b.collectCatchClauses(kids[3], &clauses);
        return .{
            .span    = spanOf(node, b.tokens),
            .body    = try b.buildBlock(kids[2]),
            .clauses = try clauses.toOwnedSlice(b.arena),
        };
    }

    fn collectCatchClauses(b: Builder, node: TN, out: *std.ArrayList(Ast.CatchClause)) !void {
        // CatchClauseList → CatchClause | CatchClauseList CatchClause
        const kids = ch(node);
        if (kids.len == 1) {
            try out.append(b.arena, try b.buildCatchClause(kids[0]));
        } else {
            try b.collectCatchClauses(kids[0], out);
            try out.append(b.arena, try b.buildCatchClause(kids[1]));
        }
    }

    fn buildCatchClause(b: Builder, node: TN) anyerror!Ast.CatchClause {
        // catch eol Block                                — catch-all
        // catch | id | eol Block                        — untyped binding
        // catch | id as TypeRef | eol Block             — typed binding
        const kids    = ch(node);
        const span    = spanOf(node, b.tokens);
        const n_kids  = kids.len;
        return switch (n_kids) {
            3 => .{ .span = span, .binding = null,             .type_ = null,  .body = try b.buildBlock(kids[2]) },
            6 => .{ .span = span, .binding = leafText(kids[2], b.tokens), .type_ = null,  .body = try b.buildBlock(kids[5]) },
            8 => .{ .span = span,
                .binding = leafText(kids[2], b.tokens),
                .type_   = try b.buildTypeRef(kids[4]),
                .body    = try b.buildBlock(kids[7]),
            },
            else => std.debug.panic("buildCatchClause: unexpected child count {d}", .{n_kids}),
        };
    }

    fn buildDeclUnion(b: Builder, node: TN) anyerror!Ast.DeclUnion {
        // ModList kw_union id eol indent UnionVariantList dedent
        const kids = ch(node);
        var variants = std.ArrayList(Ast.UnionVariant){};
        try b.collectUnionVariants(kids[5], &variants);
        return .{
            .span     = spanOf(node, b.tokens),
            .mods     = b.buildModList(kids[0]),
            .name     = leafText(kids[2], b.tokens),
            .variants = try variants.toOwnedSlice(b.arena),
        };
    }

    fn collectUnionVariants(b: Builder, node: TN, out: *std.ArrayList(Ast.UnionVariant)) !void {
        // UnionVariantList → UnionVariant | UnionVariantList UnionVariant | UnionVariantList eol
        const kids = ch(node);
        if (kids.len == 1) {
            try out.append(b.arena, try b.buildUnionVariant(kids[0]));
        } else {
            try b.collectUnionVariants(kids[0], out);
            // kids[1] may be a blank-line eol token — skip leaves
            if (kids[1] == .inner) try out.append(b.arena, try b.buildUnionVariant(kids[1]));
        }
    }

    fn buildUnionVariant(b: Builder, node: TN) anyerror!Ast.UnionVariant {
        // id eol  |  id as TypeRef eol
        const kids = ch(node);
        return .{
            .span    = spanOf(node, b.tokens),
            .name    = leafText(kids[0], b.tokens),
            .payload = if (kids.len == 4) try b.buildTypeRef(kids[2]) else null,
        };
    }

    /// Dispatch `StmtLocalVar` nodes — handles normal var, statement-body lambda,
    /// and `except` struct-update forms based on the children pattern.
    fn buildStmtLocalVarDispatch(b: Builder, node: TN) anyerror!Ast.Stmt {
        const kids = ch(node);
        const s    = spanOf(node, b.tokens);

        // Detect `kw_except` at the end before `eol`:
        //   kw_var id VarTypeOpt assign Expr kw_except eol indent ExceptFieldList dedent
        // kids: [kw_var, id, VarTypeOpt, assign, Expr, kw_except, eol, indent, ExceptFieldList, dedent]
        // The kw_except appears after the base expression.
        for (kids, 0..) |kid, i| {
            if (isLeafKind(kid, .kw_except)) {
                // kids before except: [kw_var, id, VarTypeOpt, assign, ...Expr at i-1]
                const name     = leafText(kids[1], b.tokens);
                const type_ref = try b.buildReturnAnnotOpt(kids[2]);
                const base     = try b.box(Ast.Expr, try b.buildExpr(kids[i - 1]));
                // kids after: eol, indent, ExceptFieldList, dedent
                const fields   = try b.buildExceptFieldList(kids[i + 3]);
                return .{ .var_except = try b.box(Ast.StmtVarExcept, .{
                    .span     = s,
                    .name     = name,
                    .type_ref = type_ref,
                    .base     = base,
                    .fields   = fields,
                }) };
            }
        }

        // Normal var declaration (and except form, already handled above)
        return .{ .var_ = try b.box(Ast.DeclVar, try b.buildStmtLocalVar(node)) };
    }

    /// Build a statement-body lambda var declaration.
    /// NT: StmtLocalVarLambda
    ///   kw_var/kw_const  id  VarTypeOpt  assign  kw_def  lparen  ParamList  rparen
    ///   ReturnAnnotOpt  eol  indent  CaptureOpt  StmtList  dedent
    fn buildStmtLocalVarLambda(b: Builder, node: TN) anyerror!Ast.Stmt {
        const kids = ch(node);
        const s    = spanOf(node, b.tokens);
        const is_const = isLeafKind(kids[0], .kw_const);
        const name     = leafText(kids[1], b.tokens);
        const type_ref = try b.buildReturnAnnotOpt(kids[2]);
        // kids[3] = assign, kids[4] = kw_def, kids[5] = lparen
        const params   = try b.buildParamList(kids[6]);
        // kids[7] = rparen
        const ret_type = try b.buildReturnAnnotOpt(kids[8]);
        // kids[9] = eol, kids[10] = indent
        const capture  = try b.buildCaptureOpt(kids[11]);
        const stmts    = try b.buildStmtList(kids[12]);
        // kids[13] = dedent
        const lambda   = try b.box(Ast.ExprLambda, .{
            .span        = s,
            .params      = params,
            .return_type = ret_type,
            .body        = .{ .stmts = stmts },
            .capture     = capture,
        });
        return .{ .var_ = try b.box(Ast.DeclVar, .{
            .span     = s,
            .mods     = Ast.Modifiers{},
            .name     = name,
            .type_    = type_ref,
            .init     = try b.box(Ast.Expr, .{ .lambda = lambda }),
            .is_const = is_const,
        }) };
    }

    /// Dispatch `StmtAssign` — handles normal assignment and `except` form.
    fn buildStmtAssignDispatch(b: Builder, node: TN) anyerror!Ast.Stmt {
        const kids = ch(node);
        const s    = spanOf(node, b.tokens);

        // Detect `except` form:
        //   Expr AssignOp Expr kw_except eol indent ExceptFieldList dedent
        for (kids, 0..) |kid, i| {
            if (isLeafKind(kid, .kw_except)) {
                const target = try b.box(Ast.Expr, try b.buildExpr(kids[0]));
                const op     = buildAssignOp(kids[1]);
                const base   = try b.box(Ast.Expr, try b.buildExpr(kids[2]));
                const fields = try b.buildExceptFieldList(kids[i + 3]);
                return .{ .assign_except = try b.box(Ast.StmtAssignExcept, .{
                    .span   = s,
                    .target = target,
                    .op     = op,
                    .base   = base,
                    .fields = fields,
                }) };
            }
        }

        return .{ .assign = try b.box(Ast.StmtAssign, try b.buildStmtAssign(node)) };
    }

    fn buildExceptFieldList(b: Builder, node: TN) anyerror![]const Ast.ExceptField {
        var out = std.ArrayList(Ast.ExceptField){};
        try b.collectExceptFields(node, &out);
        return out.toOwnedSlice(b.arena);
    }

    fn collectExceptFields(b: Builder, node: TN, out: *std.ArrayList(Ast.ExceptField)) anyerror!void {
        switch (node) {
            .epsilon => return,
            .inner   => |inner| {
                const kids = inner.children;
                if (kids.len == 0) return;
                if (ntOf(node) == .ExceptFieldList) {
                    if (kids.len == 1) {
                        try out.append(b.arena, try b.buildExceptField(kids[0]));
                    } else {
                        // ExceptFieldList ExceptField
                        try b.collectExceptFields(kids[0], out);
                        try out.append(b.arena, try b.buildExceptField(kids[1]));
                    }
                }
            },
            .leaf => return,
        }
    }

    fn buildExceptField(b: Builder, node: TN) anyerror!Ast.ExceptField {
        // id assign Expr eol
        const kids = ch(node);
        return .{
            .span  = spanOf(node, b.tokens),
            .name  = leafText(kids[0], b.tokens),
            .value = try b.box(Ast.Expr, try b.buildExpr(kids[2])),
        };
    }

    fn buildCaptureOpt(b: Builder, node: TN) anyerror![]const *Ast.DeclVar {
        // CaptureOpt → ε | CaptureBlock
        switch (node) {
            .epsilon => return &.{},
            .inner   => |inner| {
                if (inner.children.len == 0) return &.{};
                // CaptureBlock → kw_capture eol indent CaptureVarList dedent
                const cap_block = if (ntOf(node) == .CaptureBlock) node else inner.children[0];
                const cap_kids  = ch(cap_block);
                return b.buildCaptureVarList(cap_kids[3]);
            },
            .leaf => return &.{},
        }
    }

    fn buildCaptureVarList(b: Builder, node: TN) anyerror![]const *Ast.DeclVar {
        var out = std.ArrayList(*Ast.DeclVar){};
        try b.collectCaptureVars(node, &out);
        return out.toOwnedSlice(b.arena);
    }

    fn collectCaptureVars(b: Builder, node: TN, out: *std.ArrayList(*Ast.DeclVar)) anyerror!void {
        switch (node) {
            .epsilon => return,
            .inner   => |inner| {
                const kids = inner.children;
                if (kids.len == 0) return;
                if (ntOf(node) == .CaptureVarList) {
                    if (kids.len == 1) {
                        try out.append(b.arena, try b.box(Ast.DeclVar, try b.buildCaptureVar(kids[0])));
                    } else {
                        try b.collectCaptureVars(kids[0], out);
                        try out.append(b.arena, try b.box(Ast.DeclVar, try b.buildCaptureVar(kids[1])));
                    }
                }
            },
            .leaf => return,
        }
    }

    fn buildCaptureVar(b: Builder, node: TN) anyerror!Ast.DeclVar {
        // var id VarTypeOpt VarInitOpt eol  |  const id VarTypeOpt = Expr eol
        const kids     = ch(node);
        const is_const = isLeafKind(kids[0], .kw_const);
        const name     = leafText(kids[1], b.tokens);
        var type_:  ?Ast.TypeRef = null;
        var init_:  ?*Ast.Expr  = null;

        var idx: usize = 2;
        if (idx < kids.len and kids[idx] == .inner and ntOf(kids[idx]) == .VarTypeOpt) {
            type_ = try b.buildReturnAnnotOpt(kids[idx]);
            idx  += 1;
        }
        if (idx < kids.len) {
            if (kids[idx] == .inner and ntOf(kids[idx]) == .VarInitOpt) {
                const vk = ch(kids[idx]);
                if (vk.len >= 2) init_ = try b.box(Ast.Expr, try b.buildExpr(vk[1]));
            } else if (isLeafKind(kids[idx], .assign)) {
                init_ = try b.box(Ast.Expr, try b.buildExpr(kids[idx + 1]));
            }
        }
        return .{
            .span     = spanOf(node, b.tokens),
            .mods     = Ast.Modifiers{},
            .name     = name,
            .type_    = type_,
            .init     = init_,
            .is_const = is_const,
        };
    }

    // ── Expressions ───────────────────────────────────────────────────────────

    fn buildExpr(b: Builder, node: TN) anyerror!Ast.Expr {
        return switch (ntOf(node)) {
            .Expr, .Expr2, .Expr3, .Expr4,
            .Expr5, .Expr6, .Expr7, .Expr8, .Expr9 => b.buildExprLevel(node),
            .Atom       => b.buildAtom(node),
            .AllAnyExpr => b.buildAllAnyExpr(node),
            else => std.debug.panic("buildExpr: unexpected NT {s}", .{@tagName(ntOf(node))}),
        };
    }

    fn buildExprLevel(b: Builder, node: TN) anyerror!Ast.Expr {
        const kids = ch(node);
        const s    = spanOf(node, b.tokens);

        // Passthrough: single child
        if (kids.len == 1) return b.buildExpr(kids[0]);

        // Unary prefix: 2 children, first is a leaf operator
        if (kids.len == 2 and kids[0] == .leaf) {
            const opExpr = try b.box(Ast.Expr, try b.buildExpr(kids[1]));
            return switch (kids[0].leaf.token) {
                .minus   => .{ .unary = try b.box(Ast.ExprUnary, .{ .span=s, .op=.neg,     .operand=opExpr }) },
                .tilde   => .{ .unary = try b.box(Ast.ExprUnary, .{ .span=s, .op=.bit_not, .operand=opExpr }) },
                .kw_not  => .{ .unary = try b.box(Ast.ExprUnary, .{ .span=s, .op=.not_,    .operand=opExpr }) },
                .kw_old  => .{ .old   = try b.box(Ast.ExprOld,   .{ .span=s, .expr=opExpr }) },
                .kw_try  => .{ .try_  = try b.box(Ast.ExprTry,   .{ .span=s, .expr=opExpr }) },
                else => std.debug.panic("buildExprLevel unary: {s}", .{@tagName(kids[0].leaf.token)}),
            };
        }

        // `to?` postfix: 2 children, second is .toq
        if (kids.len == 2 and isLeafKind(kids[1], .toq)) {
            return .{ .to_nilable = try b.box(Ast.ExprToNilable, .{
                .span = s,
                .expr = try b.box(Ast.Expr, try b.buildExpr(kids[0])),
            }) };
        }

        // Member access: Expr9 . id — 3 children, right is a bare identifier.
        // Must be checked before the generic binary handler because `kids[2]`
        // is a leaf token, not an expression node.
        if (kids.len == 3 and isLeafKind(kids[1], .dot) and isLeafKind(kids[2], .id)) {
            return .{ .member = try b.box(Ast.ExprMember, .{
                .span   = s,
                .object = try b.box(Ast.Expr, try b.buildExpr(kids[0])),
                .member = leafText(kids[2], b.tokens),
            }) };
        }

        // Pipeline: Expr arrow PipelineCall — 3 children, middle is arrow leaf
        // `a -> f(x)` desugars to `f(a, x)` (first-arg injection)
        if (kids.len == 3 and isLeafKind(kids[1], .arrow)) {
            return try b.buildPipeline(s, kids[0], kids[2]);
        }

        // `to!` — 3 children: Expr kw_to bang  (must be checked BEFORE generic binary
        // handler because that handler eagerly calls buildExpr on kids[2], which would
        // panic on a bare `bang` leaf)
        if (kids.len == 3 and isLeafKind(kids[1], .kw_to) and isLeafKind(kids[2], .bang)) {
            return .{ .to_non_nil = try b.box(Ast.ExprToNonNil, .{
                .span = s,
                .expr = try b.box(Ast.Expr, try b.buildExpr(kids[0])),
            }) };
        }

        // Binary: 3 children, middle is a leaf operator
        if (kids.len == 3 and kids[1] == .leaf) {
            const op_tok = kids[1].leaf.token;
            const left   = try b.box(Ast.Expr, try b.buildExpr(kids[0]));
            const right  = try b.box(Ast.Expr, try b.buildExpr(kids[2]));
            const mk = struct {
                fn bin(bb: Builder, ss: Ast.Span, op: Ast.BinaryOp, l: *Ast.Expr, r: *Ast.Expr) anyerror!Ast.Expr {
                    return .{ .binary = try bb.box(Ast.ExprBinary, .{ .span=ss, .op=op, .left=l, .right=r }) };
                }
            };
            return switch (op_tok) {
                .kw_or     => mk.bin(b, s, .or_,     left, right),
                .kw_and    => mk.bin(b, s, .and_,    left, right),
                .kw_is     => mk.bin(b, s, .eq,      left, right),
                .kw_in     => mk.bin(b, s, .eq,      left, right),
                .eq        => mk.bin(b, s, .eq,      left, right),
                .ne        => mk.bin(b, s, .ne,      left, right),
                .lt        => mk.bin(b, s, .lt,      left, right),
                .le        => mk.bin(b, s, .le,      left, right),
                .gt        => mk.bin(b, s, .gt,      left, right),
                .ge        => mk.bin(b, s, .ge,      left, right),
                .plus      => mk.bin(b, s, .add,     left, right),
                .minus     => mk.bin(b, s, .sub,     left, right),
                .star      => mk.bin(b, s, .mul,     left, right),
                .slash     => mk.bin(b, s, .div,     left, right),
                .slashslash => mk.bin(b, s, .int_div, left, right),
                .percent   => mk.bin(b, s, .mod,     left, right),
                .starstar  => mk.bin(b, s, .pow,     left, right),
                .kw_orelse => .{ .orelse_ = try b.box(Ast.ExprOrelse, .{
                    .span = s, .expr = left, .fallback = right,
                }) },
                .kw_catch  => .{ .catch_ = try b.box(Ast.ExprCatch, .{
                    .span = s, .expr = left, .err_var = null, .fallback = right,
                }) },
                .dot => .{ .member = try b.box(Ast.ExprMember, .{
                    .span   = s,
                    .object = left,
                    .member = leafText(kids[2], b.tokens),
                }) },
                .kw_to => {
                    // expr to T  — target is a TypeRef (inner node)
                    if (kids[2] == .inner) {
                        return .{ .cast = try b.box(Ast.ExprCast, .{
                            .span   = s,
                            .expr   = left,
                            .target = try b.buildTypeRef(kids[2]),
                        }) };
                    }
                    return mk.bin(b, s, .eq, left, right); // shouldn't happen
                },
                else => std.debug.panic("buildExprLevel binary: {s}", .{@tagName(op_tok)}),
            };
        }

        // `not in` — 4 children: Expr kw_not kw_in Expr
        if (kids.len == 4 and isLeafKind(kids[1], .kw_not) and isLeafKind(kids[2], .kw_in)) {
            const inner_bin = try b.box(Ast.ExprBinary, .{
                .span  = s,
                .op    = .eq,
                .left  = try b.box(Ast.Expr, try b.buildExpr(kids[0])),
                .right = try b.box(Ast.Expr, try b.buildExpr(kids[3])),
            });
            return .{ .unary = try b.box(Ast.ExprUnary, .{
                .span    = s,
                .op      = .not_,
                .operand = try b.box(Ast.Expr, .{ .binary = inner_bin }),
            }) };
        }

        // `catch |e| fallback` — 6 children: Expr kw_catch | id | Expr2
        if (kids.len == 6 and isLeafKind(kids[1], .kw_catch)) {
            return .{ .catch_ = try b.box(Ast.ExprCatch, .{
                .span     = s,
                .expr     = try b.box(Ast.Expr, try b.buildExpr(kids[0])),
                .err_var  = leafText(kids[3], b.tokens),
                .fallback = try b.box(Ast.Expr, try b.buildExpr(kids[5])),
            }) };
        }

        // Index: Expr [ Expr ] — 4 children
        if (kids.len == 4 and isLeafKind(kids[1], .lbracket)) {
            return .{ .index = try b.box(Ast.ExprIndex, .{
                .span   = s,
                .object = try b.box(Ast.Expr, try b.buildExpr(kids[0])),
                .index  = try b.box(Ast.Expr, try b.buildExpr(kids[2])),
            }) };
        }
        // Slice: Expr [ Expr .. Expr ] — 6 children
        if (kids.len == 6 and isLeafKind(kids[1], .lbracket) and isLeafKind(kids[3], .dotdot)) {
            return .{ .slice = try b.box(Ast.ExprSlice, .{
                .span   = s,
                .object = try b.box(Ast.Expr, try b.buildExpr(kids[0])),
                .start  = try b.box(Ast.Expr, try b.buildExpr(kids[2])),
                .stop   = try b.box(Ast.Expr, try b.buildExpr(kids[4])),
            }) };
        }

        // Method call: Expr9 . open_call ArgList rparen — 5 children
        if (kids.len == 5 and isLeafKind(kids[1], .dot)) {
            // open_call text already excludes the `(` (the tokenizer strips it).
            const mname = leafText(kids[2], b.tokens);
            const obj    = try b.box(Ast.Expr, try b.buildExpr(kids[0]));
            const callee = try b.box(Ast.Expr, .{ .member = try b.box(Ast.ExprMember, .{
                .span = s, .object = obj, .member = mname,
            }) });
            return .{ .call = try b.box(Ast.ExprCall, .{
                .span      = s,
                .callee    = callee,
                .type_args = &.{},
                .args      = try b.buildArgListNode(kids[3]),
            }) };
        }

        // Keyword method call: Expr9 . kw_get lparen ArgList rparen — 6 children
        // Handles obj.get(args), obj.post(args) where the method name is a keyword.
        if (kids.len == 6 and isLeafKind(kids[1], .dot) and isLeafKind(kids[3], .lparen)) {
            const mname = leafText(kids[2], b.tokens);
            const obj    = try b.box(Ast.Expr, try b.buildExpr(kids[0]));
            const callee = try b.box(Ast.Expr, .{ .member = try b.box(Ast.ExprMember, .{
                .span = s, .object = obj, .member = mname,
            }) });
            return .{ .call = try b.box(Ast.ExprCall, .{
                .span      = s,
                .callee    = callee,
                .type_args = &.{},
                .args      = try b.buildArgListNode(kids[4]),
            }) };
        }

        std.debug.panic("buildExprLevel: children={} nt={s}", .{ kids.len, @tagName(ntOf(node)) });
    }

    // ── Atom ──────────────────────────────────────────────────────────────────

    fn buildAtom(b: Builder, node: TN) anyerror!Ast.Expr {
        const kids = ch(node);
        const s    = spanOf(node, b.tokens);

        if (kids.len == 1) {
            const kid = kids[0];
            if (kid == .leaf) {
                const tok  = kid.leaf.token;
                const text = leafText(kid, b.tokens);
                return switch (tok) {
                    .kw_true  => .{ .bool_lit = .{ .span = s, .value = true } },
                    .kw_false => .{ .bool_lit = .{ .span = s, .value = false } },
                    .kw_nil   => .{ .nil = s },
                    .kw_this  => .{ .this = s },
                    .id       => .{ .ident = .{ .span = s, .name = text } },
                    .integer_lit, .integer_lit_explicit,
                    .hex_lit, .hex_lit_unsign, .hex_lit_explicit
                              => .{ .int_lit = .{ .span = s, .text = text,
                                    .base = if (std.mem.startsWith(u8, text, "0x")) .hex else .decimal } },
                    .float_lit, .float_lit_exp, .fractional_lit
                              => .{ .float_lit = .{ .span = s, .text = text } },
                    .char_lit_single, .char_lit_double
                              => .{ .char_lit = .{ .span = s, .text = text } },
                    .string_single, .string_double
                              => .{ .string_lit = .{ .span = s, .kind = .plain, .text = text } },
                    .string_nosub_single, .string_nosub_double
                              => .{ .string_lit = .{ .span = s, .kind = .nosub, .text = text } },
                    .string_raw_single, .string_raw_double
                              => .{ .string_lit = .{ .span = s, .kind = .raw, .text = text } },
                    .zig_single, .zig_double
                              => .{ .zig_lit = .{ .span = s, .text = text } },
                    .doc_string_line
                              => .{ .string_lit = .{ .span = s, .kind = .plain, .text = text } },
                    else => std.debug.panic("buildAtom leaf: {s}", .{@tagName(tok)}),
                };
            }
            // Inner child (AllAnyExpr or LambdaExpr)
            if (kid == .inner and ntOf(kid) == .LambdaExpr) {
                return b.buildLambdaExpr(kid);
            }
            return b.buildExpr(kid);
        }

        // .foo  — self member (dot id)
        if (kids.len == 2 and isLeafKind(kids[0], .dot)) {
            return .{ .member = try b.box(Ast.ExprMember, .{
                .span   = s,
                .object = try b.box(Ast.Expr, .{ .this = s }),
                .member = leafText(kids[1], b.tokens),
            }) };
        }

        // open_call ArgList rparen  — free function call (3 children)
        if (kids.len == 3 and isLeafKind(kids[0], .open_call)) {
            const name = leafText(kids[0], b.tokens); // open_call text has no `(`
            return .{ .call = try b.box(Ast.ExprCall, .{
                .span      = s,
                .callee    = try b.box(Ast.Expr, .{ .ident = .{ .span = s, .name = name } }),
                .type_args = &.{},
                .args      = try b.buildArgListNode(kids[1]),
            }) };
        }

        // (Expr)  — grouped
        if (kids.len == 3 and isLeafKind(kids[0], .lparen)) {
            return b.buildExpr(kids[1]);
        }

        // .open_call ArgList rparen  — self method call (4 children: dot, open_call, ArgList, rparen)
        if (kids.len == 4 and isLeafKind(kids[0], .dot) and isLeafKind(kids[1], .open_call)) {
            const name = leafText(kids[1], b.tokens); // open_call text has no `(`
            const obj  = try b.box(Ast.Expr, .{ .this = s });
            return .{ .call = try b.box(Ast.ExprCall, .{
                .span      = s,
                .callee    = try b.box(Ast.Expr, .{ .member = try b.box(Ast.ExprMember, .{
                    .span = s, .object = obj, .member = name,
                }) }),
                .type_args = &.{},
                .args      = try b.buildArgListNode(kids[2]),
            }) };
        }

        // @[args]  — array literal (3 children: at_lbracket, ArgList, rbracket)
        if (kids.len == 3 and isLeafKind(kids[0], .at_lbracket)) {
            return .{ .array_lit = try b.box(Ast.ExprArrayLit, .{
                .span  = s,
                .elems = try b.buildArgExprs(kids[1]),
            }) };
        }

        // if(cond, then, else) — ternary (8 children)
        if (kids.len == 8 and isLeafKind(kids[0], .kw_if)) {
            return .{ .if_expr = try b.box(Ast.ExprIf, .{
                .span      = s,
                .cond      = try b.box(Ast.Expr, try b.buildExpr(kids[2])),
                .then_expr = try b.box(Ast.Expr, try b.buildExpr(kids[4])),
                .else_expr = try b.box(Ast.Expr, try b.buildExpr(kids[6])),
            }) };
        }

        // Interpolated string
        if (isLeafKind(kids[0], .string_start_single) or isLeafKind(kids[0], .string_start_double)) {
            return try b.buildStringInterp(s, kids);
        }

        std.debug.panic("buildAtom: children={}", .{kids.len});
    }

    // ── AllAny comprehension ──────────────────────────────────────────────────

    fn buildAllAnyExpr(b: Builder, node: TN) anyerror!Ast.Expr {
        // kw_all/kw_any kw_for ForVarList kw_in Expr kw_get Expr
        const kids = ch(node);
        var vars = std.ArrayList([]const u8){};
        try b.collectForVarList(kids[2], &vars);
        return .{ .all_any = try b.box(Ast.ExprAllAny, .{
            .span = spanOf(node, b.tokens),
            .kind = if (isLeafKind(kids[0], .kw_all)) .all else .any,
            .var_ = if (vars.items.len > 0) vars.items[0] else "_",
            .iter = try b.box(Ast.Expr, try b.buildExpr(kids[4])),
            .cond = try b.box(Ast.Expr, try b.buildExpr(kids[6])),
        }) };
    }

    // ── String interpolation builder ─────────────────────────────────────────

    /// Build `ExprStringInterp` from the Atom rule:
    ///   string_start_X  InterpBodyX  string_stop_X
    ///
    /// Parts layout:  literal | expr | format ...  (first/last always literal)
    /// The leading literal is the `string_start_X` text with the opening quote
    /// stripped.  Middle literals come from `string_part_X` tokens (raw, no
    /// quotes).  The trailing literal is the `string_stop_X` token text (raw,
    /// no closing quote).
    fn buildStringInterp(b: Builder, s: Ast.Span, kids: []const TN) anyerror!Ast.Expr {
        // kids: [string_start_X, InterpBodyX, string_stop_X]
        var parts = std.ArrayList(Ast.StringPart){};

        // Leading literal (strip opening quote character).
        const start_text = leafText(kids[0], b.tokens);
        try parts.append(b.arena, .{ .literal = start_text[1..] });

        // Walk InterpBodyX recursively.
        try b.collectInterpBody(kids[1], &parts);

        // Trailing literal (no quotes in stop token text).
        const stop_text = leafText(kids[2], b.tokens);
        try parts.append(b.arena, .{ .literal = stop_text });

        return .{ .string_interp = .{
            .span  = s,
            .parts = try parts.toOwnedSlice(b.arena),
        } };
    }

    /// Walk `InterpBodyX` → `InterpExprX rcurly_special InterpRestX`
    /// and append parts to `out`.
    fn collectInterpBody(b: Builder, node: TN, out: *std.ArrayList(Ast.StringPart)) anyerror!void {
        // InterpBodyS/D: InterpExprX  rcurly_special  InterpRestX
        const kids = ch(node);  // [InterpExprX, rcurly_special, InterpRestX]
        try b.collectInterpExpr(kids[0], out);
        try b.collectInterpRest(kids[2], out);
    }

    /// Walk `InterpExprX` → `Expr` | `Expr string_part_format`
    fn collectInterpExpr(b: Builder, node: TN, out: *std.ArrayList(Ast.StringPart)) anyerror!void {
        const kids = ch(node);
        const expr  = try b.box(Ast.Expr, try b.buildExpr(kids[0]));
        try out.append(b.arena, .{ .expr = expr });
        if (kids.len == 2) {
            // Optional format spec (string_part_format text starts with ':')
            const fmt_text = leafText(kids[1], b.tokens);
            try out.append(b.arena, .{ .format = fmt_text[1..] }); // strip leading ':'
        }
    }

    /// Walk `InterpRestX` → ε | `string_part_X InterpExprX rcurly_special InterpRestX`
    fn collectInterpRest(b: Builder, node: TN, out: *std.ArrayList(Ast.StringPart)) anyerror!void {
        switch (node) {
            .epsilon => return,
            .inner   => |inner| {
                if (inner.children.len == 0) return; // ε production
                // [string_part_X, InterpExprX, rcurly_special, InterpRestX]
                const kids = inner.children;
                const lit_text = leafText(kids[0], b.tokens);
                try out.append(b.arena, .{ .literal = lit_text });
                try b.collectInterpExpr(kids[1], out);
                try b.collectInterpRest(kids[3], out);
            },
            .leaf => return,
        }
    }

    // ── Pipeline desugaring ───────────────────────────────────────────────────

    /// `left -> PipelineCall` desugars to `f(left, existing_args...)`.
    ///
    /// `PipelineCall` grammar:
    ///   open_call ArgList rparen             — direct call: `f(x)` → f(left, x)
    ///   Expr9 dot open_call ArgList rparen   — member call: `obj.f(x)` → obj.f(left, x)
    fn buildPipeline(b: Builder, s: Ast.Span, lhs: TN, pipe_node: TN) anyerror!Ast.Expr {
        const piped  = try b.box(Ast.Expr, try b.buildExpr(lhs));
        const p_kids = ch(pipe_node);

        // Direct call: open_call ArgList rparen  (3 children)
        if (p_kids.len == 3 and isLeafKind(p_kids[0], .open_call)) {
            const fname = leafText(p_kids[0], b.tokens); // open_call text has no `(`
            const rest  = try b.buildArgListNode(p_kids[1]);
            // Prepend piped value
            var args = std.ArrayList(Ast.Arg){};
            try args.append(b.arena, .{ .span = s, .name = null, .value = piped });
            try args.appendSlice(b.arena, rest);
            return .{ .call = try b.box(Ast.ExprCall, .{
                .span      = s,
                .callee    = try b.box(Ast.Expr, .{ .ident = .{ .span = s, .name = fname } }),
                .type_args = &.{},
                .args      = try args.toOwnedSlice(b.arena),
            }) };
        }

        // Member call: Expr9 dot open_call ArgList rparen  (5 children)
        if (p_kids.len == 5 and isLeafKind(p_kids[2], .open_call)) {
            const mname = leafText(p_kids[2], b.tokens); // open_call text has no `(`
            const obj   = try b.box(Ast.Expr, try b.buildExpr(p_kids[0]));
            const callee = try b.box(Ast.Expr, .{ .member = try b.box(Ast.ExprMember, .{
                .span = s, .object = obj, .member = mname,
            }) });
            const rest  = try b.buildArgListNode(p_kids[3]);
            var args = std.ArrayList(Ast.Arg){};
            try args.append(b.arena, .{ .span = s, .name = null, .value = piped });
            try args.appendSlice(b.arena, rest);
            return .{ .call = try b.box(Ast.ExprCall, .{
                .span      = s,
                .callee    = callee,
                .type_args = &.{},
                .args      = try args.toOwnedSlice(b.arena),
            }) };
        }

        std.debug.panic("buildPipeline: unexpected PipelineCall shape (children={})", .{p_kids.len});
    }

    // ── Lambda builder ────────────────────────────────────────────────────────

    /// Expression-body lambda: `def(params) [as T] = Expr`
    /// Grammar: kw_def lparen ParamList rparen ReturnAnnotOpt assign Expr
    fn buildLambdaExpr(b: Builder, node: TN) anyerror!Ast.Expr {
        const kids = ch(node);
        const s    = spanOf(node, b.tokens);
        // kids: [kw_def, lparen, ParamList, rparen, ReturnAnnotOpt, assign, Expr]
        const params   = try b.buildParamList(kids[2]);
        const ret_type = try b.buildReturnAnnotOpt(kids[4]);
        const body_expr = try b.box(Ast.Expr, try b.buildExpr(kids[6]));
        return .{ .lambda = try b.box(Ast.ExprLambda, .{
            .span        = s,
            .params      = params,
            .return_type = ret_type,
            .body        = .{ .expr = body_expr },
            .capture     = &.{},
        }) };
    }

    // ── Argument / expression list helpers ────────────────────────────────────

    fn buildArgListNode(b: Builder, node: TN) anyerror![]const Ast.Arg {
        // ArgList → ε | ArgListNE
        switch (node) {
            .epsilon => return &.{},
            .inner   => |inner| {
                if (inner.children.len == 0) return &.{};
                return b.collectArgListNE(inner.children[0]);
            },
            .leaf => return &.{},
        }
    }

    fn collectArgListNE(b: Builder, node: TN) anyerror![]const Ast.Arg {
        var out = std.ArrayList(Ast.Arg){};
        try b.flattenArgListNE(node, &out);
        return out.toOwnedSlice(b.arena);
    }

    fn flattenArgListNE(b: Builder, node: TN, out: *std.ArrayList(Ast.Arg)) !void {
        // Expr | ArgListNE , Expr
        const kids = ch(node);
        if (kids.len == 1) {
            try out.append(b.arena,.{
                .span  = spanOf(kids[0], b.tokens),
                .name  = null,
                .value = try b.box(Ast.Expr, try b.buildExpr(kids[0])),
            });
        } else {
            try b.flattenArgListNE(kids[0], out);
            try out.append(b.arena,.{
                .span  = spanOf(kids[2], b.tokens),
                .name  = null,
                .value = try b.box(Ast.Expr, try b.buildExpr(kids[2])),
            });
        }
    }

    /// Extract just the `*Expr` pointers from an ArgList (for array literals / print).
    fn buildArgExprs(b: Builder, node: TN) anyerror![]const *Ast.Expr {
        const args = try b.buildArgListNode(node);
        const out = try b.arena.alloc(*Ast.Expr, args.len);
        for (args, out) |arg, *p| p.* = arg.value;
        return out;
    }

    fn buildExprListPtrs(b: Builder, node: TN) anyerror![]const *Ast.Expr {
        // ExprList → ε | ExprListNE
        switch (node) {
            .epsilon => return &.{},
            .inner   => |inner| {
                if (inner.children.len == 0) return &.{};
                return b.buildExprListNE(inner.children[0]);
            },
            .leaf => return &.{},
        }
    }

    fn buildExprListNE(b: Builder, node: TN) anyerror![]const *Ast.Expr {
        var out = std.ArrayList(*Ast.Expr){};
        try b.flattenExprListNE(node, &out);
        return out.toOwnedSlice(b.arena);
    }

    fn flattenExprListNE(b: Builder, node: TN, out: *std.ArrayList(*Ast.Expr)) !void {
        const kids = ch(node);
        if (kids.len == 1) {
            try out.append(b.arena,try b.box(Ast.Expr, try b.buildExpr(kids[0])));
        } else {
            try b.flattenExprListNE(kids[0], out);
            try out.append(b.arena,try b.box(Ast.Expr, try b.buildExpr(kids[2])));
        }
    }

    // ── Arena helper ──────────────────────────────────────────────────────────

    fn box(b: Builder, comptime T: type, value: T) anyerror!*T {
        return Ast.alloc(b.arena, T, value);
    }
};

// ── Modifier helpers ──────────────────────────────────────────────────────────

/// Set `shared = true` on any member decl that carries a `Modifiers` field.
fn setShared(d: *Ast.Decl) void {
    switch (d.*) {
        .method   => |n| n.mods.shared = true,
        .var_     => |n| n.mods.shared = true,
        .property => |n| n.mods.shared = true,
        .init     => |n| n.mods.shared = true,
        .class    => |n| n.mods.shared = true,
        .interface=> |n| n.mods.shared = true,
        .struct_  => |n| n.mods.shared = true,
        .mixin    => |n| n.mods.shared = true,
        .enum_    => |n| n.mods.shared = true,
        .union_   => |n| n.mods.shared = true,
        .use, .namespace, .extend => {}, // no mods field
    }
}

// ── Tree-node helpers (free functions) ────────────────────────────────────────

/// Children of an inner node.  Panics if the node is not `.inner`.
fn ch(node: TN) []const TN {
    return node.inner.children;
}

/// NT of an inner node.  Returns `.Program` (a safe sentinel) for non-inner nodes.
fn ntOf(node: TN) NT {
    return if (node == .inner) @enumFromInt(node.inner.nt) else .Program;
}

/// The sole child of a single-child inner node.
fn singleChild(node: TN) TN {
    return node.inner.children[0];
}

/// True when `node` is a leaf whose token kind is `kind`.
fn isLeafKind(node: TN, kind: TokenKind) bool {
    return node == .leaf and node.leaf.token == kind;
}

/// Source text of a leaf token.  Panics on non-leaf.
fn leafText(node: TN, tokens: []const Token) []const u8 {
    return tokens[node.leaf.position].text;
}

/// One-token span from a leaf.
fn leafSpan(node: TN, tokens: []const Token) Ast.Span {
    const tok = tokens[node.leaf.position];
    return .{
        .line     = tok.line,
        .col      = tok.col,
        .end_line = tok.line,
        .end_col  = tok.col + @as(u16, @intCast(tok.text.len)),
    };
}

/// Span covering the full token range of any node.
fn spanOf(node: TN, tokens: []const Token) Ast.Span {
    return switch (node) {
        .inner  => |n| {
            if (n.start >= tokens.len) return emptySpan();
            const first = tokens[n.start];
            const last  = if (n.end > 0 and n.end - 1 < tokens.len)
                tokens[n.end - 1]
            else
                first;
            return .{
                .line     = first.line,
                .col      = first.col,
                .end_line = last.line,
                .end_col  = last.col + @as(u16, @intCast(last.text.len)),
            };
        },
        .leaf   => leafSpan(node, tokens),
        .epsilon => emptySpan(),
    };
}

fn emptySpan() Ast.Span {
    return .{ .line = 0, .col = 0, .end_line = 0, .end_col = 0 };
}

/// Raw source text covering the node's full token range.
/// Reconstructs a contiguous slice from the original source buffer.
fn spanText(node: TN, tokens: []const Token) []const u8 {
    switch (node) {
        .inner => |n| {
            if (n.start >= tokens.len) return "";
            const first = tokens[n.start];
            const eidx  = if (n.end > 0 and n.end - 1 < tokens.len) n.end - 1 else n.start;
            const last  = tokens[eidx];
            const start = first.text.ptr;
            const end   = last.text.ptr + last.text.len;
            return start[0 .. @intFromPtr(end) - @intFromPtr(start)];
        },
        .leaf => |l| return tokens[l.position].text,
        .epsilon => return "",
    }
}

