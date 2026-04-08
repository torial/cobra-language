const std = @import("std");

fn fib(n: i64) i64 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

fn sumLoop(n: i64) i64 {
    var acc: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) acc += i;
    return acc;
}

pub fn main() void {
    const f = fib(40);
    std.debug.print("{}\n", .{f});
    const s = sumLoop(100_000_000);
    std.debug.print("{}\n", .{s});
}
