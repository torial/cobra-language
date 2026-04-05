//! Single source of truth for Zebra built-in type names and their Zig
//! equivalents.  Previously these were duplicated in Resolver.zig,
//! TypeChecker.zig, and CodeGen.zig; any addition to the builtin set
//! now requires editing only this file.

const std = @import("std");

// ── Builtin name set ──────────────────────────────────────────────────────────

/// Every type name that the compiler treats as pre-declared.
/// - Scalar primitives and their aliases.
/// - Sized numeric types: int8/16/32/64/128, uint8/16/32/64/128, float16/32/64/128.
/// - Semantic aliases: byte (u8), size (usize), uint (u64).
/// - Stdlib container types (List, HashMap).
/// - I/O types (File).
pub const NAMES = std.StaticStringMap(void).initComptime(&.{
    // Default scalar types
    .{ "int",      {} },
    .{ "float",    {} },
    .{ "bool",     {} },
    .{ "char",     {} },
    .{ "str",      {} },  // shorthand for String
    .{ "String",   {} },
    .{ "num",      {} },
    .{ "decimal",  {} },
    .{ "dynamic",  {} },
    .{ "object",   {} },
    .{ "void",     {} },
    .{ "same",     {} },
    // Default unsigned int
    .{ "uint",     {} },
    // Semantic aliases
    .{ "byte",     {} },  // = uint8 = u8
    .{ "size",     {} },  // = usize
    // Sized signed integers
    .{ "int8",     {} },
    .{ "int16",    {} },
    .{ "int32",    {} },
    .{ "int64",    {} },
    .{ "int128",   {} },
    // Sized unsigned integers
    .{ "uint8",    {} },
    .{ "uint16",   {} },
    .{ "uint32",   {} },
    .{ "uint64",   {} },
    .{ "uint128",  {} },
    // Sized floats
    .{ "float16",  {} },
    .{ "float32",  {} },
    .{ "float64",  {} },
    .{ "float128", {} },
    // Stdlib generic containers
    .{ "List",          {} },
    .{ "HashMap",       {} },
    // Stdlib string builder
    .{ "StringBuilder", {} },
    // Stdlib file I/O
    .{ "File",          {} },
    // Stdlib networking
    .{ "Http",          {} },
    .{ "HttpRequest",   {} },
    .{ "HttpResponse",  {} },
    .{ "Tcp",           {} },
    .{ "TcpConn",       {} },
    .{ "Udp",           {} },
    .{ "UdpSocket",     {} },
    // Stdlib regex
    .{ "Regex",         {} },
    // Stdlib UI
    .{ "Gui",           {} },
    // System / process
    .{ "sys",           {} },
});

/// Returns true iff `name` is a built-in type name.
pub fn isBuiltin(name: []const u8) bool {
    return NAMES.get(name) != null;
}

/// Returns true iff `name` is a dynamically-sized numeric type (e.g. `int5`,
/// `uint3`, `float7`) that is NOT in the static NAMES table.
/// Used by the Resolver to recognise arbitrary-width types from `int(N)` syntax.
pub fn isDynamicSizedNumeric(name: []const u8) bool {
    if (NAMES.get(name) != null) return false; // already in static table
    if (name.len > 3 and std.mem.startsWith(u8, name, "int")   and std.ascii.isDigit(name[3]))   return true;
    if (name.len > 4 and std.mem.startsWith(u8, name, "uint")  and std.ascii.isDigit(name[4]))   return true;
    if (name.len > 5 and std.mem.startsWith(u8, name, "float") and std.ascii.isDigit(name[5]))   return true;
    return false;
}

// ── Zebra → Zig type name mapping ─────────────────────────────────────────────

/// Map a Zebra scalar type name to its Zig equivalent.
/// Returns `name` unchanged for unknown/user-defined names and for
/// dynamically-sized types like `int5` (handled in CodeGen via `zigSizedTypeName`).
pub fn zigTypeName(name: []const u8) []const u8 {
    // Default scalars
    if (std.mem.eql(u8, name, "int"))      return "i64";
    if (std.mem.eql(u8, name, "uint"))     return "u64";
    if (std.mem.eql(u8, name, "float"))    return "f64";
    if (std.mem.eql(u8, name, "bool"))     return "bool";
    if (std.mem.eql(u8, name, "char"))     return "u21";
    if (std.mem.eql(u8, name, "str"))      return "[]const u8";
    if (std.mem.eql(u8, name, "String"))   return "[]const u8";
    if (std.mem.eql(u8, name, "num"))      return "f64";
    if (std.mem.eql(u8, name, "decimal"))  return "f64";
    if (std.mem.eql(u8, name, "dynamic"))  return "anytype";
    if (std.mem.eql(u8, name, "object"))   return "*anyopaque";
    if (std.mem.eql(u8, name, "void"))     return "void";
    // Semantic aliases
    if (std.mem.eql(u8, name, "byte"))     return "u8";
    if (std.mem.eql(u8, name, "size"))     return "usize";
    // Sized signed integers
    if (std.mem.eql(u8, name, "int8"))     return "i8";
    if (std.mem.eql(u8, name, "int16"))    return "i16";
    if (std.mem.eql(u8, name, "int32"))    return "i32";
    if (std.mem.eql(u8, name, "int64"))    return "i64";
    if (std.mem.eql(u8, name, "int128"))   return "i128";
    // Sized unsigned integers
    if (std.mem.eql(u8, name, "uint8"))    return "u8";
    if (std.mem.eql(u8, name, "uint16"))   return "u16";
    if (std.mem.eql(u8, name, "uint32"))   return "u32";
    if (std.mem.eql(u8, name, "uint64"))   return "u64";
    if (std.mem.eql(u8, name, "uint128"))  return "u128";
    // Sized floats
    if (std.mem.eql(u8, name, "float16"))  return "f16";
    if (std.mem.eql(u8, name, "float32"))  return "f32";
    if (std.mem.eql(u8, name, "float64"))  return "f64";
    if (std.mem.eql(u8, name, "float128")) return "f128";
    // UI context
    if (std.mem.eql(u8, name, "Gui"))      return "GuiContext";
    return name;
}

/// For dynamically-sized types like `int5` or `uint3` that aren't in the
/// static table, derive the Zig type name and write it directly to `w`.
/// Returns true if the name matched a sized pattern and was written.
/// Caller should fall back to `zigTypeName` if this returns false.
pub fn writeZigSizedType(w: anytype, name: []const u8) !bool {
    // intN → iN
    if (name.len > 3 and std.mem.startsWith(u8, name, "int") and std.ascii.isDigit(name[3])) {
        try w.print("i{s}", .{name[3..]});
        return true;
    }
    // uintN → uN
    if (name.len > 4 and std.mem.startsWith(u8, name, "uint") and std.ascii.isDigit(name[4])) {
        try w.print("u{s}", .{name[4..]});
        return true;
    }
    // floatN → fN
    if (name.len > 5 and std.mem.startsWith(u8, name, "float") and std.ascii.isDigit(name[5])) {
        try w.print("f{s}", .{name[5..]});
        return true;
    }
    return false;
}

/// Map a Zebra generic container name to its Zig equivalent.
pub fn zigGenericName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "List"))        return "std.ArrayList";
    if (std.mem.eql(u8, name, "Dictionary"))  return "std.AutoHashMap";
    if (std.mem.eql(u8, name, "IList"))       return "std.ArrayList";
    if (std.mem.eql(u8, name, "Set"))         return "std.AutoHashMap";
    return name;
}

/// Returns true iff `name` is any spelling of the Zebra string type.
pub fn isStringTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "str") or std.mem.eql(u8, name, "String");
}

// ── TypeChecker type enum mapping ─────────────────────────────────────────────
//
// Kept here rather than in TypeChecker to avoid a circular import.
// TypeChecker imports Builtins and calls scalarKind().

/// Tagged union so sized variants can carry their bit width.
pub const ScalarKind = union(enum) {
    int,         // default: i64
    uint,        // default: u64
    float,       // default: f64
    bool,
    char,
    string,
    void_,
    unknown,
    int_n:   u16,  // signed, N bits  (e.g. int32 → .{ .int_n = 32 })
    uint_n:  u16,  // unsigned, N bits (e.g. uint8 → .{ .uint_n = 8 })
    float_n: u16,  // float, N bits    (e.g. float32 → .{ .float_n = 32 })
};

/// Map a builtin type name to a scalar kind for the TypeChecker.
/// Returns `.unknown` for non-scalar builtins (List, HashMap, …) or unknowns.
pub fn scalarKind(name: []const u8) ScalarKind {
    // Default scalars
    if (std.mem.eql(u8, name, "int"))      return .int;
    if (std.mem.eql(u8, name, "uint"))     return .uint;
    if (std.mem.eql(u8, name, "float"))    return .float;
    if (std.mem.eql(u8, name, "bool"))     return .bool;
    if (std.mem.eql(u8, name, "char"))     return .char;
    if (std.mem.eql(u8, name, "str"))      return .string;
    if (std.mem.eql(u8, name, "String"))   return .string;
    if (std.mem.eql(u8, name, "num"))      return .float;
    if (std.mem.eql(u8, name, "decimal"))  return .float;
    if (std.mem.eql(u8, name, "void"))     return .void_;
    // Semantic aliases
    if (std.mem.eql(u8, name, "byte"))     return .{ .uint_n = 8 };
    if (std.mem.eql(u8, name, "size"))     return .uint;   // usize — treat as uint family
    // Sized signed integers (static)
    if (std.mem.eql(u8, name, "int8"))     return .{ .int_n = 8 };
    if (std.mem.eql(u8, name, "int16"))    return .{ .int_n = 16 };
    if (std.mem.eql(u8, name, "int32"))    return .{ .int_n = 32 };
    if (std.mem.eql(u8, name, "int64"))    return .{ .int_n = 64 };
    if (std.mem.eql(u8, name, "int128"))   return .{ .int_n = 128 };
    // Sized unsigned integers (static)
    if (std.mem.eql(u8, name, "uint8"))    return .{ .uint_n = 8 };
    if (std.mem.eql(u8, name, "uint16"))   return .{ .uint_n = 16 };
    if (std.mem.eql(u8, name, "uint32"))   return .{ .uint_n = 32 };
    if (std.mem.eql(u8, name, "uint64"))   return .{ .uint_n = 64 };
    if (std.mem.eql(u8, name, "uint128"))  return .{ .uint_n = 128 };
    // Sized floats (static)
    if (std.mem.eql(u8, name, "float16"))  return .{ .float_n = 16 };
    if (std.mem.eql(u8, name, "float32"))  return .{ .float_n = 32 };
    if (std.mem.eql(u8, name, "float64"))  return .{ .float_n = 64 };
    if (std.mem.eql(u8, name, "float128")) return .{ .float_n = 128 };
    // Dynamic: intN / uintN / floatN with arbitrary N
    if (name.len > 3 and std.mem.startsWith(u8, name, "int") and std.ascii.isDigit(name[3])) {
        const bits = parseBits(name[3..]) orelse return .unknown;
        return .{ .int_n = bits };
    }
    if (name.len > 4 and std.mem.startsWith(u8, name, "uint") and std.ascii.isDigit(name[4])) {
        const bits = parseBits(name[4..]) orelse return .unknown;
        return .{ .uint_n = bits };
    }
    if (name.len > 5 and std.mem.startsWith(u8, name, "float") and std.ascii.isDigit(name[5])) {
        const bits = parseBits(name[5..]) orelse return .unknown;
        return .{ .float_n = bits };
    }
    return .unknown;
}

/// Parse a decimal digit string to u16.  Returns null on overflow or non-digit.
fn parseBits(s: []const u8) ?u16 {
    var n: u16 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        const d: u16 = c - '0';
        n = std.math.mul(u16, n, 10) catch return null;
        n = std.math.add(u16, n, d)  catch return null;
    }
    return if (n == 0) null else n;
}
