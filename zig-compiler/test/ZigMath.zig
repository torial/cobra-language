// Native Zig file: test/ZigMath.zig
// Included in a Zebra project via `use ZigMath`.

pub fn square(x: i64) i64 { return x * x; }
pub fn clamp(v: i64, lo: i64, hi: i64) i64 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}
pub fn abs(x: i64) i64 { return if (x < 0) -x else x; }
