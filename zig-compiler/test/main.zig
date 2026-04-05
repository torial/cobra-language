//! Integration tests: tokenize → parse → build AST → print → compare snapshot.

const std        = @import("std");
const Tokenizer  = @import("Tokenizer");
const Parser     = @import("Parser");
const AstBuilder = @import("AstBuilder");
const AstPrinter = @import("AstPrinter");

/// Parse source text, build AST, print it, and return the printed string.
/// Caller owns the returned slice (allocated from `gpa`).
fn parseAndPrint(src: []const u8, gpa: std.mem.Allocator) ![]u8 {
    // 1. Tokenize
    const tokens = try Tokenizer.tokenize(src, gpa);
    defer gpa.free(tokens);

    // 2. Parse
    var result = try Parser.parse(tokens, gpa);
    defer result.deinit();

    const ok = switch (result) {
        .ok  => |*s| s,
        .err => |e| {
            std.debug.print("parse error at token {}\n", .{e.error_pos});
            return error.ParseFailed;
        },
    };

    // 3. Build AST
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const module = try AstBuilder.build(ok, arena.allocator());

    // 4. Print
    var buf = std.ArrayList(u8){};
    try AstPrinter.print(module, buf.writer(gpa).any());
    return buf.toOwnedSlice(gpa);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn expectPrint(src: []const u8, expected: []const u8) !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const got = try parseAndPrint(src, gpa);
    defer gpa.free(got);

    if (!std.mem.eql(u8, std.mem.trimRight(u8, got, "\n"), std.mem.trimRight(u8, expected, "\n"))) {
        std.debug.print("\n=== expected ===\n{s}\n=== got ===\n{s}\n", .{ expected, got });
        return error.TestExpectedEqual;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "use directive" {
    try expectPrint(
        \\use System.Collections
        \\
    ,
        \\(module
        \\  (use "System.Collections"))
    );
}

test "class with var member" {
    try expectPrint(
        \\class Dog
        \\    var name as String
        \\
    ,
        \\(module
        \\  (class Dog
        \\    (var name (type String))))
    );
}

test "class with method" {
    try expectPrint(
        \\class Greeter
        \\    def greet(name as String) as String
        \\        return name
        \\
    ,
        \\(module
        \\  (class Greeter
        \\    (method greet (params (param name String)) (return String)
        \\      (return name))))
    );
}

test "var and const member" {
    try expectPrint(
        \\class Point
        \\    var x as int
        \\    const ZERO as int = 0
        \\
    ,
        \\(module
        \\  (class Point
        \\    (var x (type int))
        \\    (const ZERO (type int) 0)))
    );
}

test "error union type and orelse" {
    try expectPrint(
        \\class Loader
        \\    def load as !String
        \\        return zig"hello"
        \\
    ,
        \\(module
        \\  (class Loader
        \\    (method load (return !String)
        \\      (return (zig zig"hello")))))
    );
}

test "defer and errdefer" {
    try expectPrint(
        \\class Res
        \\    def open
        \\        defer pass
        \\        errdefer pass
        \\
    ,
        \\(module
        \\  (class Res
        \\    (method open
        \\      (defer (pass))
        \\      (errdefer (pass)))))
    );
}

test "orelse expression" {
    try expectPrint(
        \\class Opt
        \\    def fetch as int
        \\        return x orelse 0
        \\
    ,
        \\(module
        \\  (class Opt
        \\    (method fetch (return int)
        \\      (return (orelse x 0)))))
    );
}

test "catch expression" {
    try expectPrint(
        \\class Safe
        \\    def run as int
        \\        return doIt catch 0
        \\
    ,
        \\(module
        \\  (class Safe
        \\    (method run (return int)
        \\      (return (catch doIt 0)))))
    );
}

test "catch with error binding" {
    try expectPrint(
        \\class Safe
        \\    def run as int
        \\        return doIt catch |e| 0
        \\
    ,
        \\(module
        \\  (class Safe
        \\    (method run (return int)
        \\      (return (catch doIt |e| 0)))))
    );
}

test "old expression in ensure" {
    try expectPrint(
        \\class Counter
        \\    def push(x as int)
        \\        ensure
        \\            count == old count + 1
        \\
    ,
        \\(module
        \\  (class Counter
        \\    (method push (params (param x int)) (ensure (== count (+ (old count) 1))))))
    );
}

test "namespace with class" {
    try expectPrint(
        \\namespace Animals
        \\    class Cat
        \\        var name as String
        \\
    ,
        \\(module
        \\  (namespace Animals
        \\    (class Cat
        \\      (var name (type String)))))
    );
}
