//! Prints the Zebra grammar as a BNF-style listing.
//!
//! Run with:  zig build grammar

const std    = @import("std");
const earley = @import("earley");
const G      = @import("ZebraGrammar");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    try earley.printGrammar(G.TokenKind, G.grammar, buf.writer(alloc));

    // Write to stderr — works uniformly across Zig versions.
    std.debug.print("{s}", .{buf.items});
}
