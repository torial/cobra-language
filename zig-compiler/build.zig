const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const earley_dep = b.dependency("earley", .{ .target = target, .optimize = optimize });
    const earley_mod = earley_dep.module("earley");

    // ── Compiler executable ───────────────────────────────────────────────────
    //
    // The compiler_mod root is src/main.zig; all src/*.zig files are imported
    // via relative paths and belong to a single module — only 'earley' needs
    // explicit wiring.

    const compiler_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target   = target,
        .optimize = optimize,
    });
    compiler_mod.addImport("earley", earley_mod);

    const exe = b.addExecutable(.{
        .name        = "zebra",
        .root_module = compiler_mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addArgs(b.args orelse &.{});
    const run_step = b.step("run", "Run the Zebra compiler");
    run_step.dependOn(&run.step);

    // ── Explicit module graph for tools and integration tests ─────────────────
    //
    // When src files are split across multiple modules (grammar tool, integ
    // tests) each file must belong to exactly one module.  We therefore create
    // one module per source file and wire every cross-file `@import` as a
    // named module dependency using the same string the source uses (e.g.
    // `"Token.zig"`), so the existing source files need no changes.

    const token_mod = b.createModule(.{
        .root_source_file = b.path("src/Token.zig"),
        .target   = target,
        .optimize = optimize,
    });

    const tokenizer_mod = b.createModule(.{
        .root_source_file = b.path("src/Tokenizer.zig"),
        .target   = target,
        .optimize = optimize,
    });
    tokenizer_mod.addImport("Token.zig", token_mod);

    const zebra_grammar_mod = b.createModule(.{
        .root_source_file = b.path("src/ZebraGrammar.zig"),
        .target   = target,
        .optimize = optimize,
    });
    zebra_grammar_mod.addImport("earley",    earley_mod);
    zebra_grammar_mod.addImport("Token.zig", token_mod);

    const ast_mod = b.createModule(.{
        .root_source_file = b.path("src/Ast.zig"),
        .target   = target,
        .optimize = optimize,
    });

    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/Parser.zig"),
        .target   = target,
        .optimize = optimize,
    });
    parser_mod.addImport("earley",           earley_mod);
    parser_mod.addImport("Token.zig",        token_mod);
    parser_mod.addImport("Tokenizer.zig",    tokenizer_mod);
    parser_mod.addImport("ZebraGrammar.zig", zebra_grammar_mod);

    const ast_builder_mod = b.createModule(.{
        .root_source_file = b.path("src/AstBuilder.zig"),
        .target   = target,
        .optimize = optimize,
    });
    ast_builder_mod.addImport("earley",           earley_mod);
    ast_builder_mod.addImport("Ast.zig",          ast_mod);
    ast_builder_mod.addImport("Parser.zig",       parser_mod);
    ast_builder_mod.addImport("Token.zig",        token_mod);
    ast_builder_mod.addImport("ZebraGrammar.zig", zebra_grammar_mod);

    const ast_printer_mod = b.createModule(.{
        .root_source_file = b.path("src/AstPrinter.zig"),
        .target   = target,
        .optimize = optimize,
    });
    ast_printer_mod.addImport("Ast.zig", ast_mod);

    // ── Grammar listing ───────────────────────────────────────────────────────

    const grammar_tool_mod = b.createModule(.{
        .root_source_file = b.path("tools/print_grammar.zig"),
        .target   = target,
        .optimize = optimize,
    });
    grammar_tool_mod.addImport("earley",       earley_mod);
    grammar_tool_mod.addImport("ZebraGrammar", zebra_grammar_mod);

    const grammar_exe  = b.addExecutable(.{ .name = "print-grammar", .root_module = grammar_tool_mod });
    const grammar_run  = b.addRunArtifact(grammar_exe);
    const grammar_step = b.step("grammar", "Print the Zebra grammar as a BNF listing");
    grammar_step.dependOn(&grammar_run.step);

    // ── Tests ─────────────────────────────────────────────────────────────────

    // Unit tests: single module rooted at src/main.zig — relative imports work
    // naturally; only the external 'earley' dep needs registering.
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target   = target,
        .optimize = optimize,
    });
    unit_mod.addImport("earley", earley_mod);
    const unit_tests = b.addTest(.{ .name = "unit", .root_module = unit_mod });

    // Integration tests: test/main.zig imports the explicit module graph.
    const integ_mod = b.createModule(.{
        .root_source_file = b.path("test/main.zig"),
        .target   = target,
        .optimize = optimize,
    });
    integ_mod.addImport("Tokenizer",   tokenizer_mod);
    integ_mod.addImport("Parser",      parser_mod);
    integ_mod.addImport("AstBuilder",  ast_builder_mod);
    integ_mod.addImport("AstPrinter",  ast_printer_mod);
    const integ_tests = b.addTest(.{ .name = "integration", .root_module = integ_mod });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(integ_tests).step);
}
