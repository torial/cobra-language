//! TypeChecker: semantic analysis Pass 3 — assign types to expressions
//! and verify type compatibility.
//!
//! Consumes Pass 1 (`SymbolTable`) and Pass 2 (`ResolveResult`) to:
//!   - Assign a concrete `Type` to every expression in the AST.
//!   - Verify that variable initialisers match declared types.
//!   - Verify that `return` expressions match method return types.
//!   - Verify that assignment RHS types match LHS types.
//!   - Verify that `if` / `while` / `assert` conditions are `bool`.
//!   - Verify that `and` / `or` operands are `bool`.
//!   - Verify that arithmetic operands are numeric and have matching types.
//!
//! ## What is deferred
//!
//! - Compound types (`T?`, `!T`, generics) are recorded as `Type.unknown`
//!   and checked in a later pass.
//! - Member-access type resolution (`obj.field`) is deferred to Pass 4,
//!   when the full type of the object is available.
//! - Method-call argument type checking is deferred similarly.
//!
//! ## Usage
//!
//! ```zig
//! var tc_result = try TypeChecker.typeCheckPass3(module, &resolve_result, gpa, gpa);
//! defer tc_result.deinit();
//! if (tc_result.hasErrors()) { /* report */ }
//! ```

const std      = @import("std");
const Ast      = @import("Ast.zig");
const ST       = @import("SymbolTable.zig");
const Binder   = @import("Binder.zig");
const Resolver = @import("Resolver.zig");
const Builtins = @import("Builtins.zig");

const Allocator   = std.mem.Allocator;
const Symbol      = ST.Symbol;
const SymbolKind  = ST.SymbolKind;
const Diagnostic  = Binder.Diagnostic;
const DiagKind    = Binder.DiagKind;

// ── Type representation ───────────────────────────────────────────────────────

pub const Type = union(enum) {
    // ── Primitives ────────────────────────────────────────────────────────────
    int,              // i64  (default signed integer)
    uint,             // u64  (default unsigned integer)
    float,            // f64  (default float)
    bool,
    char,
    string,
    void_,

    // ── Sized numeric types ───────────────────────────────────────────────────
    /// Signed integer with explicit bit width: int8, int32, int(5), …
    int_n:   u16,
    /// Unsigned integer with explicit bit width: uint8, uint32, byte, …
    uint_n:  u16,
    /// Floating-point with explicit bit width: float32, float16, …
    float_n: u16,

    // ── User-defined ──────────────────────────────────────────────────────────
    /// A class / interface / struct / mixin / enum.
    named: *const Symbol,
    /// A generic class instantiated with concrete type arguments.
    /// E.g. `Stack(int)` → `{ sym: Stack_sym, args: [.int] }`.
    /// Enables member lookups that substitute type params with actual types.
    generic_named: struct { sym: *const Symbol, args: []const Type },

    // ── Stdlib types ─────────────────────────────────────────────────────────
    /// `StringBuilder` — wraps `std.ArrayList(u8)`.
    string_builder,
    /// `HttpRequest` — incoming server request passed to `Http.serve` handler.
    http_request,
    /// `HttpResponse` — result of `Http.get` / `Http.post`, or constructed via `HttpResponse.ok` etc.
    http_response,
    /// `TcpConn` — result of `Tcp.connect`.
    tcp_conn,
    /// `UdpSocket` — result of `Udp.socket`.
    udp_socket,
    /// `Regex` — compiled regular expression.
    regex,
    /// `Gui` — GUI context passed to `Gui.run` frame callback; also the `Gui` namespace type.
    gui_context,
    /// `Shell` — process execution namespace.
    shell,
    /// `File` — file I/O namespace.
    file,
    /// `[]str` — immutable slice of strings (e.g. `Net.resolve` return value).
    str_slice,
    /// `SysRunResult` — result of `sys.run(argv)` with exit_code/stdout/stderr fields.
    sys_run_result,
    /// `JsonValue` — a parsed JSON value (wraps `std.json.Value`).
    json_value,
    /// `[]JsonValue` — JSON array slice returned by `getList`.
    json_array,
    /// `DateTime` — epoch-ms point in time.
    date_time,
    /// `CalendarView` — calendar-specific lens over a `DateTime`.
    calendar_view,
    /// `CsvTable` — parsed CSV data, accessible by row index and column name.
    csv_table,
    /// `CsvWriter` — builder for RFC 4180 CSV output.
    csv_writer,
    /// A single CSV row (behaves like `List(str)`; each element is a field string).
    csv_row,
    /// `ArgResult` — parsed command-line arguments from `Arg.parse()`.
    arg_result,
    /// `UriResult` — parsed URI from `Uri.parse(url)`.
    uri_result,
    /// `TimerHandle` — high-resolution timer from `Timer.start()`.
    timer_handle,

    // ── Optional ──────────────────────────────────────────────────────────────
    /// `?T` — nilable wrapper around another type.
    optional: *const Type,

    // ── Tuple ─────────────────────────────────────────────────────────────────
    /// `(T1, T2, …)` — tuple with ordered element types.
    tuple: []const Type,

    // ── Cross-module instances ────────────────────────────────────────────────
    /// An instance of a user-defined type from an imported module.
    /// Stored as `(module_alias, type_name)` string slices — no Symbol pointers,
    /// so this is safe to keep in `TypeCheckResult.expr_types` across compilation
    /// boundaries.  The slices point into the `imported_modules` key arena.
    cross_module: struct { module: []const u8, type_name: []const u8 },

    // ── Function reference ────────────────────────────────────────────────────
    /// A first-class reference to a named function / method.
    /// Produced when a method ident is used in non-call position:
    ///   `var f = isAlpha`  or  `list.forEach(isAlpha)`
    /// The referenced symbol is stored for later arity/type checking.
    fn_ref: *const Symbol,

    // ── Named function-type alias (sig) ───────────────────────────────────────
    /// A `sig`-typed parameter or variable: the type is a named delegate alias.
    /// Produced when a local/param has a TypeRef that resolves to a `sig_` symbol.
    /// Stores the DeclSig so `inferCall` can recover the return type.
    fn_sig: *const Ast.DeclSig,

    // ── Special ───────────────────────────────────────────────────────────────
    /// Cannot determine type: upstream error or unsupported construct.
    /// Suppresses further cascading errors.
    unknown,

    /// Two types are the same value.
    pub fn eql(a: Type, b: Type) bool {
        return switch (a) {
            .int     => b == .int,
            .uint    => b == .uint,
            .float   => b == .float,
            .bool    => b == .bool,
            .char    => b == .char,
            .string  => b == .string,
            .void_   => b == .void_,
            .int_n   => |wa| switch (b) { .int_n   => |wb| wa == wb, else => false },
            .uint_n  => |wa| switch (b) { .uint_n  => |wb| wa == wb, else => false },
            .float_n => |wa| switch (b) { .float_n => |wb| wa == wb, else => false },
            .named          => |sa| switch (b) {
                .named        => |sb| sa == sb,
                // cross_module and named are the same user type in two representations.
                // A constructor call `TcScope()` yields .cross_module; a type annotation
                // `as TcScope` on an exposed import yields .named.  Treat them as equal
                // when the type_name matches the symbol name.
                .cross_module => |cm| std.mem.eql(u8, sa.name, cm.type_name),
                else          => false,
            },
            .generic_named  => |ga| switch (b) {
                .generic_named => |gb| blk: {
                    if (ga.sym != gb.sym) break :blk false;
                    if (ga.args.len != gb.args.len) break :blk false;
                    for (ga.args, gb.args) |ta, tb| if (!ta.eql(tb)) break :blk false;
                    break :blk true;
                },
                else => false,
            },
            .optional       => |ia| switch (b) { .optional => |ib| ia.eql(ib.*), else => false },
            .string_builder => b == .string_builder,
            .http_request   => b == .http_request,
            .http_response  => b == .http_response,
            .tcp_conn       => b == .tcp_conn,
            .udp_socket     => b == .udp_socket,
            .regex          => b == .regex,
            .gui_context    => b == .gui_context,
            .shell          => b == .shell,
            .file           => b == .file,
            .str_slice      => b == .str_slice,
            .sys_run_result => b == .sys_run_result,
            .json_value     => b == .json_value,
            .date_time      => b == .date_time,
            .calendar_view  => b == .calendar_view,
            .csv_table      => b == .csv_table,
            .csv_writer     => b == .csv_writer,
            .csv_row        => b == .csv_row,
            .arg_result     => b == .arg_result,
            .uri_result     => b == .uri_result,
            .timer_handle   => b == .timer_handle,
            .json_array     => b == .json_array,
            .tuple => |ea| switch (b) {
                .tuple => |eb| blk: {
                    if (ea.len != eb.len) break :blk false;
                    for (ea, eb) |ta, tb| if (!ta.eql(tb)) break :blk false;
                    break :blk true;
                },
                else => false,
            },
            .cross_module   => |cm_a| switch (b) {
                .cross_module => |cm_b| std.mem.eql(u8, cm_a.module, cm_b.module) and
                                        std.mem.eql(u8, cm_a.type_name, cm_b.type_name),
                // Symmetric: named ↔ cross_module when type names match.
                .named        => |sb| std.mem.eql(u8, cm_a.type_name, sb.name),
                else => false,
            },
            .fn_ref         => |sa| switch (b) { .fn_ref => |sb| sa == sb, else => false },
            .fn_sig         => |da| switch (b) { .fn_sig => |db| da == db, else => false },
            .unknown        => b == .unknown,
        };
    }

    /// `from` can be assigned where `to` is expected.
    /// `unknown` on either side bypasses the check (error already reported).
    /// All numeric types are assignment-compatible with each other at the
    /// Zebra level — Zig enforces the actual range/precision constraints.
    /// This reflects the "integer literals are untyped" principle.
    pub fn isAssignable(from: Type, to: Type) bool {
        if (from == .unknown or to == .unknown) return true;
        // Any numeric → any numeric: defer to Zig.
        if (from.isNumeric() and to.isNumeric()) return true;
        // char (u21) is assignment-compatible with integer types — it IS a codepoint.
        if (to == .char and (from.isNumeric() or from == .char)) return true;
        if (from == .char and to.isNumeric()) return true;
        if (from == .http_request  and to == .http_request)  return true;
        if (from == .http_response and to == .http_response) return true;
        if (from == .tcp_conn   and to == .tcp_conn)   return true;
        if (from == .udp_socket and to == .udp_socket) return true;
        if (from == .regex      and to == .regex)       return true;
        if (from == .date_time     and to == .date_time)     return true;
        if (from == .calendar_view and to == .calendar_view) return true;
        if (from == .gui_context and to == .gui_context) return true;
        // optional(T) is assignable to optional(T), and nil (.optional(.void_)) to any optional
        if (from == .optional and to == .optional) return isAssignable(from.optional.*, to.optional.*);
        if (from == .optional and from.optional.* == .void_) return to == .optional; // nil → ?T
        // T is assignable to ?T (wrapping in optional)
        if (to == .optional) return isAssignable(from, to.optional.*);
        // Any fn_ref is assignable to any fn_ref (same-arity compatibility deferred to runtime)
        if (from == .fn_ref and to == .fn_ref) return true;
        // fn_ref is assignable to fn_sig (the sig provides the typed context; Zig enforces arity)
        if (from == .fn_ref and to == .fn_sig) return true;
        // fn_sig is assignable to fn_sig (e.g. passing a sig-typed local to a sig-typed param)
        if (from == .fn_sig and to == .fn_sig) return true;
        return eql(from, to);
    }

    /// Human-readable name for diagnostics.
    pub fn name(t: Type) []const u8 {
        return switch (t) {
            .int     => "int",
            .uint    => "uint",
            .float   => "float",
            .bool    => "bool",
            .char    => "char",
            .string  => "String",
            .void_   => "void",
            .int_n   => "int<N>",    // diagnostic only — exact width not tracked in []const u8
            .uint_n  => "uint<N>",
            .float_n => "float<N>",
            .named          => |s| s.name,
            .generic_named  => |g| g.sym.name,
            .string_builder => "StringBuilder",
            .http_request   => "HttpRequest",
            .http_response  => "HttpResponse",
            .tcp_conn       => "TcpConn",
            .udp_socket     => "UdpSocket",
            .regex          => "Regex",
            .gui_context    => "Gui",
            .shell          => "Shell",
            .file           => "File",
            .str_slice      => "[]str",
            .sys_run_result => "SysRunResult",
            .json_value     => "JsonValue",
            .json_array     => "[]JsonValue",
            .date_time      => "DateTime",
            .calendar_view  => "CalendarView",
            .csv_table      => "CsvTable",
            .csv_writer     => "CsvWriter",
            .csv_row        => "CsvRow",
            .arg_result     => "ArgResult",
            .uri_result     => "UriResult",
            .timer_handle   => "TimerHandle",
            .optional       => "?T",
            .tuple          => "tuple",
            .cross_module   => |cm| cm.type_name,
            .fn_ref         => |s| s.name,
            .fn_sig         => |d| d.name,
            .unknown        => "<unknown>",
        };
    }

    /// True for any signed integer type.
    pub fn isIntFamily(t: Type) bool {
        return switch (t) { .int, .int_n => true, else => false };
    }

    /// True for any unsigned integer type.
    pub fn isUintFamily(t: Type) bool {
        return switch (t) { .uint, .uint_n => true, else => false };
    }

    /// True for any floating-point type.
    pub fn isFloatFamily(t: Type) bool {
        return switch (t) { .float, .float_n => true, else => false };
    }

    /// True for any numeric type (signed, unsigned, or float).
    pub fn isNumeric(t: Type) bool {
        return t.isIntFamily() or t.isUintFamily() or t.isFloatFamily();
    }
};

// ── Cross-file module interface ───────────────────────────────────────────────

/// Exported type surface of a compiled Zebra module, carried across compilation
/// boundaries so the root file's TypeChecker can resolve cross-module calls.
///
/// Category of a top-level type exported by a module.
/// Stored in `ModuleInterface.types` so CodeGen can distinguish class (reference
/// semantics, emitted as `*T`) from struct/enum (value semantics, emitted as `T`).
pub const TypeKind = enum { class, struct_, union_, enum_ };

/// Keys use "ClassName.memberName" convention.  Only primitive return/field types
/// are preserved (int, str, bool, etc.); user-defined types resolve to `.unknown`
/// since Symbol pointers from the dep's arena cannot safely outlive it.
pub const ModuleInterface = struct {
    /// Method return types: "ClassName.methodName" → Type
    methods: std.StringHashMap(Type),
    /// Field / property types: "ClassName.fieldName" → Type
    fields:  std.StringHashMap(Type),
    /// Exported type names: class, struct, enum, union names declared at top level.
    /// Used by the Resolver to recognise cross-module TypeRefs and by CodeGen to:
    ///   - decide whether to unwrap a sole same-named type on import (unions are skipped)
    ///   - emit `*ClassName` for class types (reference semantics) vs `StructName` (value)
    types:   std.StringHashMap(TypeKind),
    /// Subset of `methods` keys for methods declared `throws`.
    /// Used by CodeGen to emit `catch` redirects when a cross-module throwing method
    /// is called inside a `try/catch` block's var initializer.
    throws_methods: std.StringHashMap(void),
    /// Union variants whose payload type is `^T` (heap-boxed pointer).
    /// Key: "UnionName.variantName", value: inner type name (the T in ^T).
    /// Used by CodeGen to emit the labeled-block boxing expression when constructing
    /// cross-module union variants:
    ///   `box: { const _p = try _allocator.create(T); _p.* = val; break :box _p; }`
    boxed_variants: std.StringHashMap([]const u8),
    /// Union variant payload struct names: "UnionName.variantName" → struct type name.
    /// Populated for variants whose payload is a named struct/class (or ^StructName).
    /// Used by the TypeChecker to type branch-binding variables for cross-module unions:
    ///   `on Parser.PNode.module_ as m` → m has type cross_module{ "Parser", "PModule" }
    /// This makes `m.field` member accesses type-checkable against the module interface.
    variant_payload_types: std.StringHashMap([]const u8),
    /// Instance field type names for user-defined (non-primitive) field types.
    /// Key: "ClassName.fieldName", Value: type name string (e.g. "TcScope", "AstNode").
    /// Populated when `simpleTypeFromRef` returns `.unknown` for a named user type.
    /// Used by `inferMember` to return a `cross_module` type for cross-module field
    /// accesses, enabling chained member inference: `inst.field.method()`.
    instance_field_types: std.StringHashMap([]const u8),
    /// Instance method return type names for user-defined return types.
    /// Key: "ClassName.methodName", Value: type name string.
    /// Mirrors `instance_field_types` for method calls on cross-module instances.
    instance_method_return_types: std.StringHashMap([]const u8),
    /// Top-level function return type names for user-defined return types.
    /// Key: function name only (no class prefix), Value: type name string.
    /// Separate from `instance_method_return_types` to avoid key collision with
    /// a method whose qualified key accidentally matches a bare function name.
    /// Used by `inferCall` so e.g. `analyzeEscapes(...)` returns `cross_module{StrSet}`.
    fn_return_types: std.StringHashMap([]const u8),
    /// Set of fields declared as `^T` (non-optional ref_to pointer) in structs/classes.
    /// Key: "TypeName.fieldName" — present iff the field is `^T` (NOT `^T?`).
    /// Used by CodeGen to emit `field.*` auto-deref for cross-module struct field accesses.
    ref_fields: std.StringHashMap(void),
    /// Set of fields declared as `^T?` (optional ref_to pointer) in structs/classes.
    /// Key: "TypeName.fieldName" — present iff the field is `^T?`.
    /// Used by CodeGen to emit `field.?.*` in `expr to!` unwrap operations.
    optional_ref_fields: std.StringHashMap(void),
    /// Per-struct `cue init` parameter boxing flags.
    /// Key: struct name (e.g. "ExprBinary").
    /// Value: owned bool slice — one entry per param, true iff that param is `^T`.
    /// Used by CodeGen to auto-box `T` → `*T` when calling cross-module constructors.
    struct_init_ref_params: std.StringHashMap([]bool),
    /// Element type names for struct/class fields declared as `List(T)`.
    /// Key: "ClassName.fieldName", Value: element type name string.
    /// Used by TypeChecker's `inferForInElemType` to type loop vars when iterating
    /// cross-module List(T) fields, enabling ref_fields deref for `^T` elements.
    list_field_elem_types: std.StringHashMap([]const u8),

    pub fn deinit(self: *ModuleInterface) void {
        const alloc = self.methods.allocator;
        var mk = self.methods.keyIterator();
        while (mk.next()) |k| alloc.free(k.*);
        self.methods.deinit();
        var fk = self.fields.keyIterator();
        while (fk.next()) |k| alloc.free(k.*);
        self.fields.deinit();
        var tk = self.types.keyIterator();
        while (tk.next()) |k| alloc.free(k.*);
        self.types.deinit();
        var tmk = self.throws_methods.keyIterator();
        while (tmk.next()) |k| alloc.free(k.*);
        self.throws_methods.deinit();
        var bvk = self.boxed_variants.keyIterator();
        while (bvk.next()) |k| alloc.free(k.*);
        var bvv = self.boxed_variants.valueIterator();
        while (bvv.next()) |v| alloc.free(v.*);
        self.boxed_variants.deinit();
        var vpk = self.variant_payload_types.keyIterator();
        while (vpk.next()) |k| alloc.free(k.*);
        var vpv = self.variant_payload_types.valueIterator();
        while (vpv.next()) |v| alloc.free(v.*);
        self.variant_payload_types.deinit();
        var iftk = self.instance_field_types.keyIterator();
        while (iftk.next()) |k| alloc.free(k.*);
        var iftv = self.instance_field_types.valueIterator();
        while (iftv.next()) |v| alloc.free(v.*);
        self.instance_field_types.deinit();
        var imrtk = self.instance_method_return_types.keyIterator();
        while (imrtk.next()) |k| alloc.free(k.*);
        var imrtv = self.instance_method_return_types.valueIterator();
        while (imrtv.next()) |v| alloc.free(v.*);
        self.instance_method_return_types.deinit();
        var frtk = self.fn_return_types.keyIterator();
        while (frtk.next()) |k| alloc.free(k.*);
        var frtv = self.fn_return_types.valueIterator();
        while (frtv.next()) |v| alloc.free(v.*);
        self.fn_return_types.deinit();
        var rfk = self.ref_fields.keyIterator();
        while (rfk.next()) |k| alloc.free(k.*);
        self.ref_fields.deinit();
        var orfk = self.optional_ref_fields.keyIterator();
        while (orfk.next()) |k| alloc.free(k.*);
        self.optional_ref_fields.deinit();
        var sirpk = self.struct_init_ref_params.keyIterator();
        while (sirpk.next()) |k| alloc.free(k.*);
        var sirpv = self.struct_init_ref_params.valueIterator();
        while (sirpv.next()) |v| alloc.free(v.*);
        self.struct_init_ref_params.deinit();
        var lfetk = self.list_field_elem_types.keyIterator();
        while (lfetk.next()) |k| alloc.free(k.*);
        var lfetv = self.list_field_elem_types.valueIterator();
        while (lfetv.next()) |v| alloc.free(v.*);
        self.list_field_elem_types.deinit();
    }
};

/// Walk `module`'s declarations and extract the publicly visible type surface
/// into a `ModuleInterface`.  All resulting `Type` values are primitives or
/// `.unknown`; no pointers into the dep's arena are retained.
///
/// Call this before freeing the dep's `Resolver.ResolveResult`.
pub fn extractModuleInterface(
    module:  Ast.Module,
    resolve: *const Resolver.ResolveResult,
    alloc:   Allocator,
) !ModuleInterface {
    var methods = std.StringHashMap(Type).init(alloc);
    errdefer methods.deinit();
    var fields = std.StringHashMap(Type).init(alloc);
    errdefer fields.deinit();
    var types = std.StringHashMap(TypeKind).init(alloc);
    errdefer types.deinit();
    var throws_methods = std.StringHashMap(void).init(alloc);
    errdefer throws_methods.deinit();
    var boxed_variants = std.StringHashMap([]const u8).init(alloc);
    errdefer boxed_variants.deinit();
    var variant_payload_types = std.StringHashMap([]const u8).init(alloc);
    errdefer variant_payload_types.deinit();
    var instance_field_types = std.StringHashMap([]const u8).init(alloc);
    errdefer instance_field_types.deinit();
    var instance_method_return_types = std.StringHashMap([]const u8).init(alloc);
    errdefer instance_method_return_types.deinit();
    var fn_return_types = std.StringHashMap([]const u8).init(alloc);
    errdefer fn_return_types.deinit();
    var ref_fields = std.StringHashMap(void).init(alloc);
    errdefer ref_fields.deinit();
    var optional_ref_fields = std.StringHashMap(void).init(alloc);
    errdefer optional_ref_fields.deinit();
    var struct_init_ref_params = std.StringHashMap([]bool).init(alloc);
    errdefer struct_init_ref_params.deinit();
    var list_field_elem_types = std.StringHashMap([]const u8).init(alloc);
    errdefer list_field_elem_types.deinit();

    try extractFromDecls(module.decls, resolve, alloc, &methods, &fields, &types, &throws_methods, &boxed_variants, &variant_payload_types, &instance_field_types, &instance_method_return_types, &fn_return_types, &ref_fields, &optional_ref_fields, &struct_init_ref_params, &list_field_elem_types);
    return .{ .methods = methods, .fields = fields, .types = types, .throws_methods = throws_methods, .boxed_variants = boxed_variants, .variant_payload_types = variant_payload_types, .instance_field_types = instance_field_types, .instance_method_return_types = instance_method_return_types, .fn_return_types = fn_return_types, .ref_fields = ref_fields, .optional_ref_fields = optional_ref_fields, .struct_init_ref_params = struct_init_ref_params, .list_field_elem_types = list_field_elem_types };
}

fn extractFromDecls(
    decls:                        []const Ast.Decl,
    resolve:                      *const Resolver.ResolveResult,
    alloc:                        Allocator,
    methods:                      *std.StringHashMap(Type),
    fields:                       *std.StringHashMap(Type),
    types:                        *std.StringHashMap(TypeKind),
    throws_methods:               *std.StringHashMap(void),
    boxed_variants:               *std.StringHashMap([]const u8),
    variant_payload_types:        *std.StringHashMap([]const u8),
    instance_field_types:         *std.StringHashMap([]const u8),
    instance_method_return_types: *std.StringHashMap([]const u8),
    fn_return_types:              *std.StringHashMap([]const u8),
    ref_fields:                   *std.StringHashMap(void),
    optional_ref_fields:          *std.StringHashMap(void),
    struct_init_ref_params:       *std.StringHashMap([]bool),
    list_field_elem_types:        *std.StringHashMap([]const u8),
) !void {
    for (decls) |decl| switch (decl) {
        .class  => |c| {
            const key = try alloc.dupe(u8, c.name);
            try types.put(key, .class);
            try extractFromMembers(c.name, c.members, resolve, alloc, methods, fields, throws_methods, instance_field_types, instance_method_return_types, ref_fields, optional_ref_fields, struct_init_ref_params, list_field_elem_types);
        },
        .struct_ => |s| {
            const key = try alloc.dupe(u8, s.name);
            try types.put(key, .struct_);
            try extractFromMembers(s.name, s.members, resolve, alloc, methods, fields, throws_methods, instance_field_types, instance_method_return_types, ref_fields, optional_ref_fields, struct_init_ref_params, list_field_elem_types);
        },
        .enum_ => |e| {
            const key = try alloc.dupe(u8, e.name);
            try types.put(key, .enum_);
        },
        .union_ => |u| {
            const key = try alloc.dupe(u8, u.name);
            try types.put(key, .union_); // unions skipped in sole-type import heuristic
            // Record variant payload type names for principled branch-binding inference.
            // Also record ^T variants for CodeGen's labeled-block boxing.
            for (u.variants) |v| {
                if (v.payload) |pl| {
                    // Unwrap ^T if heap-boxed; record the inner named type.
                    const inner_ref: *const Ast.TypeRef = switch (pl) {
                        .ref_to => |inner| blk: {
                            // Also record in boxed_variants (^T boxing for CodeGen).
                            switch (inner.*) {
                                .named => |nr| {
                                    const bv_key = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ u.name, v.name });
                                    errdefer alloc.free(bv_key);
                                    const bv_val = try alloc.dupe(u8, nr.name);
                                    try boxed_variants.put(bv_key, bv_val);
                                },
                                else => {},
                            }
                            break :blk inner;
                        },
                        else => &pl,
                    };
                    // Record payload struct name for branch-binding type inference.
                    if (inner_ref.* == .named) {
                        const vp_key = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ u.name, v.name });
                        errdefer alloc.free(vp_key);
                        const vp_val = try alloc.dupe(u8, inner_ref.named.name);
                        try variant_payload_types.put(vp_key, vp_val);
                    }
                }
            }
        },
        .namespace => |ns| try extractFromDecls(ns.decls, resolve, alloc, methods, fields, types, throws_methods, boxed_variants, variant_payload_types, instance_field_types, instance_method_return_types, fn_return_types, ref_fields, optional_ref_fields, struct_init_ref_params, list_field_elem_types),
        // Top-level functions: record return type name in fn_return_types when it is a
        // user-defined type.  Key = function name only (no class prefix) so there is no
        // ambiguity with the "ClassName.methodName" keys in instance_method_return_types.
        .method => |m| {
            if (m.return_type) |*rt| {
                if (namedTypeStr(rt, resolve)) |ret_name| {
                    const key = try alloc.dupe(u8, m.name);
                    errdefer alloc.free(key);
                    const val = try alloc.dupe(u8, ret_name);
                    try fn_return_types.put(key, val);
                }
            }
        },
        else => {},
    };
}

fn extractFromMembers(
    class_name:                   []const u8,
    members:                      []const Ast.Decl,
    resolve:                      *const Resolver.ResolveResult,
    alloc:                        Allocator,
    methods:                      *std.StringHashMap(Type),
    fields:                       *std.StringHashMap(Type),
    throws_methods:               *std.StringHashMap(void),
    instance_field_types:         *std.StringHashMap([]const u8),
    instance_method_return_types: *std.StringHashMap([]const u8),
    ref_fields:                   *std.StringHashMap(void),
    optional_ref_fields:          *std.StringHashMap(void),
    struct_init_ref_params:       *std.StringHashMap([]bool),
    list_field_elem_types:        *std.StringHashMap([]const u8),
) !void {
    for (members) |m| switch (m) {
        .method => |meth| {
            const ret = simpleTypeFromRef(
                if (meth.return_type) |*rt| rt else null,
                resolve, alloc,
            );
            // Key ownership: HashMap stores the slice pointer; do NOT free here.
            // ModuleInterface.deinit() walks and frees keys.
            const key = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ class_name, meth.name });
            try methods.put(key, ret);
            if (meth.throws) {
                const tk = try alloc.dupe(u8, key);
                try throws_methods.put(tk, {});
            }
            // For user-defined return types, record the type name so cross-module
            // method calls can return a typed cross_module value instead of .unknown.
            if (ret == .unknown) {
                if (meth.return_type) |*rt| {
                    if (namedTypeStr(rt, resolve)) |tname| {
                        const imrt_key = try alloc.dupe(u8, key);
                        const imrt_val = try alloc.dupe(u8, tname);
                        try instance_method_return_types.put(imrt_key, imrt_val);
                    }
                }
            }
        },
        .var_  => |v| {
            const t = simpleTypeFromRef(if (v.type_) |*tr| tr else null, resolve, alloc);
            const key = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ class_name, v.name });
            try fields.put(key, t);
            if (v.type_) |*tr| {
                // For user-defined field types, record the type name for cross-module
                // chained access: inst.field.method() needs inst.field to be typed.
                if (t == .unknown) {
                    if (namedTypeStr(tr, resolve)) |tname| {
                        const ift_key = try alloc.dupe(u8, key);
                        const ift_val = try alloc.dupe(u8, tname);
                        try instance_field_types.put(ift_key, ift_val);
                    }
                }
                // Track List(T) fields so for-in iterations can type the loop variable.
                if (tr.* == .generic and std.mem.eql(u8, tr.generic.name, "List") and
                    tr.generic.args.len > 0)
                {
                    const elem_tr = &tr.generic.args[0];
                    if (namedTypeStr(elem_tr, resolve)) |elem_name| {
                        const lfet_key = try alloc.dupe(u8, key);
                        const lfet_val = try alloc.dupe(u8, elem_name);
                        try list_field_elem_types.put(lfet_key, lfet_val);
                    }
                }
                // Track ^T and ^T? fields for cross-module auto-deref:
                //   ^T  (ref_to non-nilable) → ref_fields: emit `field.*`
                //   ^T? (ref_to wrapping nilable) → optional_ref_fields: emit `field.?.*` on to!
                if (tr.* == .ref_to) {
                    const is_optional_ref = tr.ref_to.* == .nilable;
                    const rf_key = try alloc.dupe(u8, key);
                    if (is_optional_ref) {
                        try optional_ref_fields.put(rf_key, {});
                    } else {
                        try ref_fields.put(rf_key, {});
                    }
                }
            }
        },
        .property => |p| {
            const t = simpleTypeFromRef(if (p.type_) |*tr| tr else null, resolve, alloc);
            const key = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ class_name, p.name });
            try fields.put(key, t);
            if (t == .unknown) {
                if (p.type_) |*tr| {
                    if (namedTypeStr(tr, resolve)) |tname| {
                        const ift_key = try alloc.dupe(u8, key);
                        const ift_val = try alloc.dupe(u8, tname);
                        try instance_field_types.put(ift_key, ift_val);
                    }
                }
            }
        },
        .init => |ci| {
            // Record per-param boxing flags for cross-module constructor calls.
            // For each param, true iff the param is `^T` (ref_to).
            if (ci.params.len > 0) {
                var flags = try alloc.alloc(bool, ci.params.len);
                for (ci.params, 0..) |p, i| {
                    flags[i] = if (p.type_) |pt| pt == .ref_to else false;
                }
                // Only store if at least one param needs boxing.
                const any_ref = for (flags) |f| { if (f) break true; } else false;
                if (any_ref) {
                    const sirp_key = try alloc.dupe(u8, class_name);
                    try struct_init_ref_params.put(sirp_key, flags);
                } else {
                    alloc.free(flags);
                }
            }
        },
        else => {},
    };
}

/// Extract the string name of a user-defined (non-builtin) type from a TypeRef.
/// Returns the name if the TypeRef resolves to a symbol (user-defined type),
/// or null for builtins, generics, and other compound types.
/// Unwraps `^T` (ref_to) to get the inner named type.
///
/// IMPORTANT: `tr` must be a pointer into the AST arena (not a stack copy).
/// `resolve.types` is keyed by arena `*const Ast.NamedTypeRef` pointers; a
/// by-value switch would produce stack pointers that never match.
fn namedTypeStr(tr: *const Ast.TypeRef, resolve: *const Resolver.ResolveResult) ?[]const u8 {
    return switch (tr.*) {
        .named  => |*n| blk: {
            const resolved = resolve.types.get(n) orelse break :blk null;
            break :blk switch (resolved) {
                .symbol  => n.name,
                .builtin => null,
            };
        },
        .ref_to => |inner| namedTypeStr(inner, resolve), // inner is *Ast.TypeRef — unwrap ^T
        else    => null,
    };
}

/// Convert a `TypeRef` to a `Type` using only the resolver's builtin table.
/// Returns `.unknown` for user-defined types (Symbol pointers can't safely
/// cross compilation boundaries) and for compound types not yet modelled.
fn simpleTypeFromRef(
    tr:      ?*const Ast.TypeRef,
    resolve: *const Resolver.ResolveResult,
    alloc:   Allocator,
) Type {
    const t = tr orelse return .void_;
    return switch (t.*) {
        .void_  => .void_,
        .named  => |*n| blk: {
            const resolved = resolve.types.get(n) orelse break :blk .unknown;
            break :blk switch (resolved) {
                .builtin => builtinType(n.name),
                .symbol  => .unknown, // user-defined type; Symbol lives in dep's arena
            };
        },
        .nilable => |inner| blk: {
            const inner_t = simpleTypeFromRef(inner, resolve, alloc);
            if (inner_t == .unknown) break :blk .unknown;
            const boxed = alloc.create(Type) catch break :blk .unknown;
            boxed.* = inner_t;
            break :blk Type{ .optional = boxed };
        },
        .tuple => |ttr| blk: {
            const elems = alloc.alloc(Type, ttr.elems.len) catch break :blk .unknown;
            for (ttr.elems, elems) |*el, *out|
                out.* = simpleTypeFromRef(el, resolve, alloc);
            break :blk Type{ .tuple = elems };
        },
        // ^T — heap-indirection: type-check as inner type.
        .ref_to => |inner| simpleTypeFromRef(inner, resolve, alloc),
        // Compound types deferred.
        .stream, .error_union, .generic, .same => .unknown,
    };
}

// ── Result ────────────────────────────────────────────────────────────────────

pub const TypeCheckResult = struct {
    /// Every walked expression → its inferred `Type`.
    expr_types: std.AutoHashMap(*const Ast.Expr, Type),
    diags:      []const Diagnostic,
    diag_alloc: Allocator,
    /// "ClassName.propName" → void — getter properties that should be called as obj.prop().
    getter_methods: std.StringHashMap(void),
    /// "TypeName.methodName" → DeclMethod* — extension methods from `extend` blocks.
    ext_methods: std.StringHashMap(*const Ast.DeclMethod),
    /// Set of `.try_` Expr nodes that represent optional-unwraps (`opt?.x`), NOT error
    /// propagation.  Populated during type-checking by looking at the inner ident's
    /// DECLARED type (pre nil-narrowing) to distinguish `Foo? → .?` from `Result → try`.
    optional_unwraps: std.AutoHashMap(*const Ast.Expr, void),
    /// Set of argument expressions that must be prefixed with `&` in Zig because they
    /// are fn_ref function names being passed into a fn_sig (delegate) parameter.
    /// Populated by inferCall when a fn_ref arg matches a sig-typed parameter.
    fn_ref_args: std.AutoHashMap(*const Ast.Expr, void),

    pub fn hasErrors(self: TypeCheckResult) bool {
        for (self.diags) |d| if (d.kind == .err) return true;
        return false;
    }

    pub fn deinit(self: *TypeCheckResult) void {
        for (self.diags) |d| self.diag_alloc.free(d.message);
        self.diag_alloc.free(self.diags);
        self.expr_types.deinit();
        self.getter_methods.deinit();
        self.ext_methods.deinit();
        self.optional_unwraps.deinit();
        self.fn_ref_args.deinit();
    }
};

// ── Union variant scanning ────────────────────────────────────────────────────

fn collectUnionVariants(
    module: Ast.Module,
    out:    *std.StringHashMap([]const []const u8),
    alloc:  Allocator,
) !void {
    try collectUnionVariantsInDecls(module.decls, out, alloc);
}

fn collectUnionVariantsInDecls(
    decls: []const Ast.Decl,
    out:   *std.StringHashMap([]const []const u8),
    alloc: Allocator,
) !void {
    for (decls) |decl| switch (decl) {
        .union_ => |u| {
            var names = try alloc.alloc([]const u8, u.variants.len);
            for (u.variants, 0..) |v, i| names[i] = v.name;
            try out.put(u.name, names);
        },
        .namespace => |n| try collectUnionVariantsInDecls(n.decls, out, alloc),
        .class     => |c| try collectUnionVariantsInDecls(c.members, out, alloc),
        else       => {},
    };
}

// ── Nil narrowing helpers ─────────────────────────────────────────────────────

const NilNarrow = struct { name: []const u8, expr: *const Ast.Expr };

/// If `cond` is `x != nil` (for_then=true) or `x == nil` (for_then=false),
/// returns the variable name and its Expr node (for type lookup). Null otherwise.
fn nilNarrowedVarExpr(cond: *const Ast.Expr, for_then: bool) ?NilNarrow {
    if (cond.* != .binary) return null;
    const b = cond.binary;
    const want_op: Ast.BinaryOp = if (for_then) .ne else .eq;
    if (b.op != want_op) return null;
    if (b.left.* == .ident and b.right.* == .nil)
        return .{ .name = b.left.ident.name, .expr = b.left };
    if (b.right.* == .ident and b.left.* == .nil)
        return .{ .name = b.right.ident.name, .expr = b.right };
    return null;
}

// ── Getter method scanning ────────────────────────────────────────────────────

/// Scan all class declarations and record "ClassName.propName" for every getter property.
fn collectGetterMethods(
    module: Ast.Module,
    out:    *std.StringHashMap(void),
    alloc:  Allocator,
) !void {
    try collectGetterMethodsInDecls(module.decls, out, alloc);
}

fn collectGetterMethodsInDecls(
    decls:      []const Ast.Decl,
    out:        *std.StringHashMap(void),
    alloc:      Allocator,
) !void {
    for (decls) |decl| switch (decl) {
        .class => |c| {
            for (c.members) |m| switch (m) {
                .property => |p| if (p.getter != null) {
                    const key = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ c.name, p.name });
                    try out.put(key, {});
                },
                else => {},
            };
            try collectGetterMethodsInDecls(c.members, out, alloc);
        },
        .namespace => |n| try collectGetterMethodsInDecls(n.decls, out, alloc),
        else => {},
    };
}

// ── Extension method scanning ────────────────────────────────────────────────

/// Scan all `extend` declarations and record "TypeName.methodName" → DeclMethod*.
fn collectExtMethods(
    module: Ast.Module,
    out:    *std.StringHashMap(*const Ast.DeclMethod),
    alloc:  Allocator,
) !void {
    try collectExtMethodsInDecls(module.decls, out, alloc);
}

fn collectExtMethodsInDecls(
    decls: []const Ast.Decl,
    out:   *std.StringHashMap(*const Ast.DeclMethod),
    alloc: Allocator,
) !void {
    for (decls) |decl| switch (decl) {
        .extend => |ext| {
            const tname = switch (ext.target) {
                .named   => |n| n.name,
                .generic => |g| g.name,
                else     => continue,
            };
            for (ext.members) |m| switch (m) {
                .method => |meth| {
                    const key = try std.fmt.allocPrint(alloc, "{s}.{s}", .{tname, meth.name});
                    try out.put(key, meth);
                },
                else => {},
            };
        },
        .namespace => |n| try collectExtMethodsInDecls(n.decls, out, alloc),
        else => {},
    };
}

// ── Public entry point ────────────────────────────────────────────────────────

/// Run Pass 3 on `module` using the already-populated `resolve` result.
///
/// - `map_alloc`         — owns the `expr_types` hash-map entries.
/// - `diag_alloc`        — owns the `diags` slice and message strings.
/// - `imported_modules`  — module interfaces from `use`d deps (may be null).
///                         Keys are the Zebra dotted use-path (e.g. `"Math"`).
pub fn typeCheckPass3(
    module:           Ast.Module,
    resolve:          *const Resolver.ResolveResult,
    map_alloc:        Allocator,
    diag_alloc:       Allocator,
    imported_modules: ?*const std.StringHashMap(ModuleInterface),
) anyerror!TypeCheckResult {
    var expr_types      = std.AutoHashMap(*const Ast.Expr, Type).init(map_alloc);
    var optional_unwraps = std.AutoHashMap(*const Ast.Expr, void).init(map_alloc);
    var fn_ref_args      = std.AutoHashMap(*const Ast.Expr, void).init(map_alloc);
    var loop_var_types  = std.StringHashMap(Type).init(map_alloc);
    defer loop_var_types.deinit();
    var list_elem_types = std.StringHashMap(Type).init(map_alloc);
    defer list_elem_types.deinit();
    var union_variants  = std.StringHashMap([]const []const u8).init(map_alloc);
    defer union_variants.deinit();
    try collectUnionVariants(module, &union_variants, map_alloc);
    var getter_methods  = std.StringHashMap(void).init(map_alloc);
    try collectGetterMethods(module, &getter_methods, map_alloc);
    var ext_methods     = std.StringHashMap(*const Ast.DeclMethod).init(map_alloc);
    try collectExtMethods(module, &ext_methods, map_alloc);
    var narrowed_types  = std.StringHashMap(Type).init(map_alloc);
    defer narrowed_types.deinit();
    var diags           = std.ArrayList(Diagnostic){};

    const tc = TypeChecker{
        .resolve          = resolve,
        .map_alloc        = map_alloc,
        .diag_alloc       = diag_alloc,
        .expr_types       = &expr_types,
        .diags            = &diags,
        .return_type      = .void_,
        .owner_sym        = null,
        .loop_var_types   = &loop_var_types,
        .list_elem_types  = &list_elem_types,
        .union_variants   = &union_variants,
        .narrowed_types   = &narrowed_types,
        .ext_methods      = &ext_methods,
        .imported_modules = imported_modules,
        .optional_unwraps = &optional_unwraps,
        .fn_ref_args      = &fn_ref_args,
    };

    try tc.checkModule(module);

    return .{
        .expr_types       = expr_types,
        .diags            = try diags.toOwnedSlice(diag_alloc),
        .diag_alloc       = diag_alloc,
        .getter_methods   = getter_methods,
        .ext_methods      = ext_methods,
        .optional_unwraps = optional_unwraps,
        .fn_ref_args      = fn_ref_args,
    };
}

// ── TypeChecker context ───────────────────────────────────────────────────────
//
// Passed by value; `expr_types` and `diags` are behind pointers so all copies
// share the same output maps.  `return_type` and `owner_sym` are cheap scalars
// that are overridden via `withReturn` / `withOwner` when descending into a
// method or type body.

const TypeChecker = struct {
    resolve:     *const Resolver.ResolveResult,
    map_alloc:   Allocator,
    diag_alloc:  Allocator,
    expr_types:  *std.AutoHashMap(*const Ast.Expr, Type),
    diags:       *std.ArrayList(Diagnostic),
    /// Expected return type of the enclosing method.  `void_` at module level.
    return_type: Type,
    /// Symbol for the enclosing type body — used to resolve `this` and `same`.
    owner_sym:   ?*const Symbol,
    /// Transient element-type overrides for active loop variables.
    /// Keyed by variable name (string).  Shared across TypeChecker copies.
    loop_var_types: *std.StringHashMap(Type),
    /// Element type for variables that are List(T) at runtime but whose type
    /// resolves to .unknown in loop_var_types (generic types aren't tracked).
    /// `inferForInElemType` checks this for bare ident iterators.
    list_elem_types: *std.StringHashMap(Type),
    /// Union type name → slice of variant name strings.
    /// Used for exhaustiveness checking on `branch`.
    union_variants: *const std.StringHashMap([]const []const u8),
    /// Nil-narrowed variable name → unwrapped inner Type.
    /// When `x != nil` is the condition of an `if`, `x` is pushed here for the then_body.
    narrowed_types: *std.StringHashMap(Type),
    /// "TypeName.methodName" → DeclMethod* from all `extend` blocks in the module.
    ext_methods: *const std.StringHashMap(*const Ast.DeclMethod),
    /// Non-null inside `extend T` method bodies: the inferred type of `this`/`self`.
    ext_self_type: ?Type = null,
    /// Type surfaces of `use`d modules, keyed by Zebra dotted path (e.g. `"Math"`).
    /// Null when no module interfaces were provided (deps not compiled with type extraction).
    imported_modules: ?*const std.StringHashMap(ModuleInterface) = null,
    /// `.try_` nodes confirmed to be optional-unwraps (inner declared type is nilable).
    /// Shared across TypeChecker copies; written by inferExprInner for `.try_`.
    optional_unwraps: *std.AutoHashMap(*const Ast.Expr, void),
    /// Arg expressions that must be prefixed with `&` in Zig — fn_ref passed into fn_sig param.
    fn_ref_args: *std.AutoHashMap(*const Ast.Expr, void),

    fn withReturn(tc: TypeChecker, ret: Type) TypeChecker {
        var c = tc; c.return_type = ret; return c;
    }
    fn withOwner(tc: TypeChecker, owner: ?*const Symbol) TypeChecker {
        var c = tc; c.owner_sym = owner; return c;
    }
    fn withExtSelf(tc: TypeChecker, self_type: Type) TypeChecker {
        var c = tc; c.ext_self_type = self_type; return c;
    }

    /// Map a Type to its Zebra type name for extension method lookup.
    fn extTypeName(_: TypeChecker, t: Type) ?[]const u8 {
        return switch (t) {
            .string         => "String",
            .int            => "int",
            .uint           => "uint",
            .float          => "float",
            .bool           => "bool",
            .char           => "char",
            .string_builder => "StringBuilder",
            .named          => |sym| switch (sym.decl) {
                .class     => |c| c.name,
                .struct_   => |s| s.name,
                .interface => |i| i.name,
                else       => null,
            },
            else => null,
        };
    }

    // ── Module ────────────────────────────────────────────────────────────────

    fn checkModule(tc: TypeChecker, module: Ast.Module) anyerror!void {
        for (module.decls) |decl| try tc.checkTopDecl(decl);
    }

    fn checkTopDecl(tc: TypeChecker, decl: Ast.Decl) anyerror!void {
        switch (decl) {
            .use       => {},
            .namespace => |n| for (n.decls) |d| try tc.checkTopDecl(d),
            .class     => |n| try tc.checkClass(n),
            .interface => |n| try tc.checkInterface(n),
            .struct_   => |n| try tc.checkStruct(n),
            .mixin     => |n| try tc.checkMixin(n),
            .enum_     => |n| try tc.checkEnum(n),
            .extend    => |n| try tc.checkExtend(n),
            .method    => |n| try tc.checkMethod(n),
            .property  => |n| try tc.checkProperty(n),
            .var_      => |n| try tc.checkVarDecl(n, false),
            .init      => |n| try tc.checkInit(n),
            .union_    => {},  // no body to type-check (variants are types, not expressions)
            .sig_      => {},  // type alias — no body to type-check
        }
    }

    // ── Type declarations ─────────────────────────────────────────────────────

    fn checkClass(tc: TypeChecker, n: *Ast.DeclClass) anyerror!void {
        for (n.invariants) |e| _ = try tc.inferExpr(e);
        for (n.members)    |m| try tc.checkMember(m);
    }

    fn checkInterface(tc: TypeChecker, n: *Ast.DeclInterface) anyerror!void {
        for (n.members) |m| try tc.checkMember(m);
    }

    fn checkStruct(tc: TypeChecker, n: *Ast.DeclStruct) anyerror!void {
        for (n.invariants) |e| _ = try tc.inferExpr(e);
        for (n.members)    |m| try tc.checkMember(m);
    }

    fn checkMixin(tc: TypeChecker, n: *Ast.DeclMixin) anyerror!void {
        for (n.members) |m| try tc.checkMember(m);
    }

    fn checkEnum(tc: TypeChecker, n: *Ast.DeclEnum) anyerror!void {
        for (n.members) |*m| {
            if (m.value) |v| _ = try tc.inferExpr(v);
        }
    }

    fn checkExtend(tc: TypeChecker, n: *Ast.DeclExtend) anyerror!void {
        // Derive the self type from the target so `this` inside method bodies
        // resolves to the correct type (e.g. `.string` for `extend String`).
        const self_type = tc.typeFromRef(&n.target);
        const etc = tc.withExtSelf(self_type);
        for (n.members) |m| try etc.checkMember(m);
    }

    fn checkMember(tc: TypeChecker, decl: Ast.Decl) anyerror!void {
        switch (decl) {
            .method   => |n| try tc.checkMethod(n),
            .property => |n| try tc.checkProperty(n),
            .var_     => |n| try tc.checkVarDecl(n, false),
            .init     => |n| try tc.checkInit(n),
            else      => {},
        }
    }

    // ── Method ────────────────────────────────────────────────────────────────

    fn checkMethod(tc: TypeChecker, n: *Ast.DeclMethod) anyerror!void {
        const ret = tc.typeFromOptRef(if (n.return_type) |*rt| rt else null);
        const inner = tc.withReturn(ret);

        for (n.params) |p| {
            if (p.default) |d| {
                const dt = try inner.inferExpr(d);
                if (p.type_) |*pt| {
                    const declared = tc.typeFromRef(pt);
                    if (!Type.isAssignable(dt, declared))
                        try inner.emitMismatch(spanOf(d), dt, declared);
                }
            }
        }
        if (n.body)    |body| try inner.checkStmts(body);
        for (n.require) |e|   _ = try inner.inferExpr(e);
        for (n.ensure)  |e|   _ = try inner.inferExpr(e);
    }

    fn checkProperty(tc: TypeChecker, n: *Ast.DeclProperty) anyerror!void {
        const prop_type = tc.typeFromOptRef(if (n.type_) |*t| t else null);
        const inner = tc.withReturn(prop_type);
        if (n.getter) |body| try inner.checkStmts(body);
        if (n.setter) |body| try inner.checkStmts(body);
    }

    // ── Variable / field declaration ──────────────────────────────────────────

    fn checkVarDecl(tc: TypeChecker, n: *Ast.DeclVar, is_local: bool) anyerror!void {
        // Collection types require explicit initialization for local variables.
        // `var l as List(T)` with no `=` is a compile error to prevent the subtle
        // "declaration looks like a constructor call but leaves field unset" footgun.
        // Class fields are exempt: they're initialized in `cue init()`.
        if (is_local and n.init == null) {
            if (n.type_) |tr| {
                if (tr == .generic) {
                    const gn = tr.generic.name;
                    if (Builtins.isMutableCollection(gn)) {
                        try tc.emitError(n.span,
                            "'{s}(...)' requires explicit initialization; use 'var {s} = {s}()()'",
                            .{ gn, n.name, gn });
                        return;
                    }
                }
            }
        }
        if (n.init) |init_expr| {
            const actual = try tc.inferExpr(init_expr);
            if (n.type_) |*tr| {
                const declared = tc.typeFromRef(tr);
                if (!Type.isAssignable(actual, declared))
                    try tc.emitMismatch(spanOf(init_expr), actual, declared);
            }
        }
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    fn checkInit(tc: TypeChecker, n: *Ast.DeclInit) anyerror!void {
        for (n.params) |p| {
            if (p.default) |d| _ = try tc.inferExpr(d);
        }
        if (n.body)     |body| try tc.checkStmts(body);
        for (n.require) |e|   _ = try tc.inferExpr(e);
        for (n.ensure)  |e|   _ = try tc.inferExpr(e);
    }

    // ── Statements ────────────────────────────────────────────────────────────

    fn checkStmts(tc: TypeChecker, stmts: []const Ast.Stmt) anyerror!void {
        for (stmts) |stmt| try tc.checkStmt(stmt);
    }

    fn checkStmt(tc: TypeChecker, stmt: Ast.Stmt) anyerror!void {
        switch (stmt) {
            .if_      => |s| {
                try tc.checkBoolExpr(s.cond);
                // Nil narrowing: if `x != nil`, unwrap `x` inside then_body.
                // After checkBoolExpr, expr_types has the type of `x` (should be .optional).
                const narrow_then = nilNarrowedVarExpr(s.cond, true);
                const narrow_else = nilNarrowedVarExpr(s.cond, false);
                if (narrow_then) |nr| {
                    const opt_type = tc.expr_types.get(nr.expr) orelse .unknown;
                    const inner = if (opt_type == .optional) opt_type.optional.* else .unknown;
                    if (inner != .unknown) try tc.narrowed_types.put(nr.name, inner);
                    try tc.checkStmts(s.then_body);
                    if (inner != .unknown) _ = tc.narrowed_types.remove(nr.name);
                } else {
                    try tc.checkStmts(s.then_body);
                }
                for (s.else_ifs) |ei| {
                    try tc.checkBoolExpr(ei.cond);
                    try tc.checkStmts(ei.body);
                }
                if (s.else_body) |eb| {
                    if (narrow_else) |nr| {
                        const opt_type = tc.expr_types.get(nr.expr) orelse .unknown;
                        const inner = if (opt_type == .optional) opt_type.optional.* else .unknown;
                        if (inner != .unknown) try tc.narrowed_types.put(nr.name, inner);
                        try tc.checkStmts(eb);
                        if (inner != .unknown) _ = tc.narrowed_types.remove(nr.name);
                    } else {
                        try tc.checkStmts(eb);
                    }
                }
            },
            .while_   => |s| {
                if (s.bind) |bind| {
                    // `while var c = expr, guard` — infer bind.init type; guard references c.
                    _ = try tc.inferExpr(bind.init);
                }
                try tc.checkBoolExpr(s.cond);
                try tc.checkStmts(s.body);
                if (s.post_body) |pb| try tc.checkStmts(pb);
            },
            .for_in   => |s| {
                _ = try tc.inferExpr(s.iter);
                // Special-case HashMap(K,V) two-var iteration: first var = key, second = value.
                const is_hashmap_two_var = blk: {
                    if (s.vars.len < 2) break :blk false;
                    if (s.iter.* != .ident) break :blk false;
                    const sym = tc.resolve.exprs.get(&s.iter.ident) orelse break :blk false;
                    const dt: ?Ast.TypeRef = switch (sym.decl) {
                        .var_  => |dv| dv.type_,
                        .param => |p|  p.type_,
                        else   => null,
                    };
                    if (dt == null) break :blk false;
                    break :blk dt.? == .generic and std.mem.eql(u8, dt.?.generic.name, "HashMap");
                };
                if (is_hashmap_two_var) {
                    // Register key and value types from HashMap generic args.
                    const dt = blk: {
                        const sym = tc.resolve.exprs.get(&s.iter.ident).?;
                        break :blk switch (sym.decl) { .var_ => |dv| dv.type_.?, .param => |p| p.type_.?, else => unreachable };
                    };
                    const key_type = if (dt.generic.args.len > 0) tc.typeFromRef(&dt.generic.args[0]) else .unknown;
                    const val_type = if (dt.generic.args.len > 1) tc.typeFromRef(&dt.generic.args[1]) else .unknown;
                    if (key_type != .unknown) try tc.loop_var_types.put(s.vars[0], key_type);
                    if (val_type != .unknown) try tc.loop_var_types.put(s.vars[1], val_type);
                    // If value type is List(T), record element type so inner for-in loops
                    // on the value variable get the correct print format specifier.
                    if (dt.generic.args.len >= 2) {
                        const val_tr = dt.generic.args[1];
                        if (val_tr == .generic and
                            std.mem.eql(u8, val_tr.generic.name, "List") and
                            val_tr.generic.args.len > 0)
                        {
                            const elem_t = tc.typeFromRef(&val_tr.generic.args[0]);
                            if (elem_t != .unknown)
                                try tc.list_elem_types.put(s.vars[1], elem_t);
                        }
                    }
                    if (s.where) |w| try tc.checkBoolExpr(w);
                    try tc.checkStmts(s.body);
                    _ = tc.loop_var_types.remove(s.vars[0]);
                    _ = tc.loop_var_types.remove(s.vars[1]);
                    _ = tc.list_elem_types.remove(s.vars[1]);
                } else {
                    const elem = tc.inferForInElemType(s.iter);
                    if (elem != .unknown) {
                        for (s.vars) |vname| try tc.loop_var_types.put(vname, elem);
                    }
                    if (s.where) |w| try tc.checkBoolExpr(w);
                    try tc.checkStmts(s.body);
                    if (elem != .unknown) {
                        for (s.vars) |vname| _ = tc.loop_var_types.remove(vname);
                    }
                }
            },
            .for_num  => |s| {
                _ = try tc.inferNumericExpr(s.start);
                _ = try tc.inferNumericExpr(s.stop);
                if (s.step) |st| _ = try tc.inferNumericExpr(st);
                // Loop variable is always int.
                try tc.loop_var_types.put(s.var_, .int);
                try tc.checkStmts(s.body);
                _ = tc.loop_var_types.remove(s.var_);
            },
            .branch   => |s| {
                const subj_type = try tc.inferExpr(s.expr);
                // For Result(T, E) subjects: determine payload types for `as` bindings.
                var result_ok_type: ?Type = null;
                var result_err_type: ?Type = null;
                if (s.expr.* == .ident) {
                    if (tc.resolve.exprs.get(&s.expr.ident)) |sym| {
                        const declared_tr: ?Ast.TypeRef = switch (sym.decl) {
                            .var_  => |v| v.type_,
                            .param => |p| p.type_,
                            else   => null,
                        };
                        if (declared_tr) |dtr| {
                            if (dtr == .generic and std.mem.eql(u8, dtr.generic.name, "Result") and dtr.generic.args.len >= 2) {
                                result_ok_type = tc.typeFromRef(&dtr.generic.args[0]);
                                result_err_type = tc.typeFromRef(&dtr.generic.args[1]);
                            }
                        }
                    }
                }
                for (s.on) |on| {
                    for (on.values) |v| _ = try tc.inferExpr(v);
                    // Push binding type into narrowed_types so body stmts see the payload type.
                    if (on.binding) |bname| {
                        if (on.values.len == 1 and on.values[0].* == .member) {
                            const variant = on.values[0].member.member;
                            if (std.mem.eql(u8, variant, "ok")) {
                                if (result_ok_type) |t| try tc.narrowed_types.put(bname, t);
                            } else if (std.mem.eql(u8, variant, "err")) {
                                if (result_err_type) |t| try tc.narrowed_types.put(bname, t);
                            } else {
                                // Union variant payload: on Shape.circle as r → r has the payload type.
                                // ① Same-module union: look up the variant symbol directly.
                                if (subj_type == .named) {
                                    const union_sym = subj_type.named;
                                    if (union_sym.kind == .union_) {
                                        if (union_sym.own_scope) |scope| {
                                            if (scope.lookupLocal(variant)) |vsym| {
                                                if (vsym.decl == .union_variant) {
                                                    const uv = vsym.decl.union_variant;
                                                    if (uv.payload) |*payload_ref| {
                                                        const pt = tc.typeFromRef(payload_ref);
                                                        if (pt != .unknown)
                                                            try tc.narrowed_types.put(bname, pt);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                // ② Cross-module union: the subject is a `.named` symbol whose
                                //    kind is `.module` (the exposed type alias).  Look up the
                                //    variant payload struct name from the imported module's
                                //    `variant_payload_types` table and construct a cross_module type.
                                //    This is the principled fix for the for-in heuristic: once
                                //    `m` has type `.cross_module`, `m.field` accesses can use
                                //    the module's `fields` table.
                                if (subj_type == .named) {
                                    const sym = subj_type.named;
                                    if (sym.kind == .module) {
                                        // Find which module this type belongs to.
                                        const mod_alias = sym.decl.use.path[std.mem.lastIndexOfScalar(u8, sym.decl.use.path, '.') orelse 0 ..];
                                        const type_name = sym.name;
                                        const lookup_key = std.fmt.allocPrint(tc.map_alloc, "{s}.{s}", .{ type_name, variant }) catch continue;
                                        defer tc.map_alloc.free(lookup_key);
                                        if (tc.imported_modules) |imp| {
                                            // Find the module by alias (iterate since we only have path).
                                            var it = imp.iterator();
                                            while (it.next()) |entry| {
                                                if (entry.value_ptr.variant_payload_types.get(lookup_key)) |payload_struct_name| {
                                                    // Determine the actual module alias for this imported module.
                                                    // entry.key_ptr.* is the module alias (e.g. "Parser").
                                                    const actual_mod = blk: {
                                                        // Check if this module exports the union type_name.
                                                        if (entry.value_ptr.types.contains(type_name)) break :blk entry.key_ptr.*;
                                                        break :blk null;
                                                    };
                                                    if (actual_mod) |mod| {
                                                        _ = mod_alias; // the path-based alias is less reliable
                                                        try tc.narrowed_types.put(bname, .{ .cross_module = .{
                                                            .module    = mod,
                                                            .type_name = payload_struct_name,
                                                        }});
                                                    }
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                                // ③ Subject is already a `.cross_module` type (e.g. inferred
                                //    from a `^T` field like `a.target` where target: ^Expr).
                                //    We have the module and union type name directly; look up
                                //    the variant payload in that module's interface.
                                if (subj_type == .cross_module) {
                                    const cm = subj_type.cross_module;
                                    if (tc.imported_modules) |imp| {
                                        if (imp.get(cm.module)) |iface| {
                                            const lookup_key = std.fmt.allocPrint(tc.map_alloc, "{s}.{s}", .{ cm.type_name, variant }) catch continue;
                                            defer tc.map_alloc.free(lookup_key);
                                            if (iface.variant_payload_types.get(lookup_key)) |payload_struct_name| {
                                                try tc.narrowed_types.put(bname, .{ .cross_module = .{
                                                    .module    = cm.module,
                                                    .type_name = payload_struct_name,
                                                }});
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (on.guard) |guard| _ = try tc.inferExpr(guard);
                    try tc.checkStmts(on.body);
                    if (on.binding) |bname| _ = tc.narrowed_types.remove(bname);
                }
                if (s.else_) |eb| try tc.checkStmts(eb);
                // Exhaustiveness check: only when subject is a named union and
                // there is no catch-all else clause.
                if (s.else_ == null) {
                    if (subj_type == .named) {
                        const sym = subj_type.named;
                        if (sym.kind == .union_) {
                            const type_name = sym.decl.union_.name;
                            if (tc.union_variants.get(type_name)) |variants| {
                                // Collect covered variant names from on-clauses.
                                var covered = std.StringHashMap(void).init(tc.diag_alloc);
                                defer covered.deinit();
                                for (s.on) |on| {
                                    for (on.values) |v| {
                                        if (v.* == .member) covered.put(v.member.member, {}) catch {};
                                    }
                                }
                                // Emit a diagnostic for each uncovered variant.
                                for (variants) |vname| {
                                    if (covered.get(vname) == null) {
                                        const msg = try std.fmt.allocPrint(
                                            tc.diag_alloc,
                                            "branch on '{s}' does not cover variant '{s}' (add 'on {s}.{s}' or an 'else' clause)",
                                            .{ type_name, vname, type_name, vname },
                                        );
                                        try tc.diags.append(tc.diag_alloc, .{
                                            .span = s.span,
                                            .kind = .err,
                                            .message = msg,
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
            },
            .return_  => |s| try tc.checkReturn(s),
            .assert   => |s| {
                try tc.checkBoolExpr(s.cond);
                if (s.message) |m| _ = try tc.inferExpr(m);
            },
            .print    => |s| { for (s.args) |a| _ = try tc.inferExpr(a); },
            .yield    => |s| _ = try tc.inferExpr(s.value),
            .assign   => |s| try tc.checkAssign(s),
            .var_     => |n| try tc.checkVarDecl(n, true),
            .expr     => |e| _ = try tc.inferExpr(e),
            .contract => |s| { for (s.exprs) |e| _ = try tc.inferExpr(e); },
            .defer_   => |s| try tc.checkStmt(s.body),
            .with        => |s| { _ = try tc.inferExpr(s.target); try tc.checkStmts(s.body); },
            .arena_scope => |s| try tc.checkStmts(s.body),
            .var_except    => |s| { _ = try tc.inferExpr(s.base); for (s.fields) |f| _ = try tc.inferExpr(f.value); },
            .assign_except => |s| { _ = try tc.inferExpr(s.target); _ = try tc.inferExpr(s.base); for (s.fields) |f| _ = try tc.inferExpr(f.value); },
            .raise    => |s| {
                if (s.message) |m| _ = try tc.inferExpr(m);
                if (s.details) |d| {
                    const det_type = try tc.inferExpr(d);
                    switch (det_type) {
                        .string  => {}, // string.toString() is itself — always OK
                        .unknown => {}, // can't check statically, suppress
                        // Primitives are always displayable via Zig's std.fmt — allow them.
                        .int, .uint, .float, .bool, .char,
                        .int_n, .uint_n, .float_n => {},
                        .named   => |sym| {
                            const has_to_string = if (sym.own_scope) |scope|
                                scope.lookupLocal("toString") != null
                            else false;
                            if (!has_to_string)
                                try tc.emitError(s.span,
                                    "raise details must implement 'toString as str': type '{s}' has no toString method",
                                    .{sym.name});
                        },
                        .generic_named => {}, // generic type details — can't check toString statically
                        else => |t| try tc.emitError(s.span,
                            "raise details must implement 'toString as str': got '{s}'",
                            .{t.name()}),
                    }
                }
            },
            .try_catch => |s| {
                try tc.checkStmts(s.body);
                for (s.clauses) |cl| try tc.checkStmts(cl.body);
            },
            .guard => |s| {
                _ = try tc.inferExpr(s.cond);
                try tc.checkStmts(s.else_body);
            },
            .destruct => |s| {
                const init_type = try tc.inferExpr(s.init);
                switch (s.kind) {
                    .tuple => {
                        if (init_type == .tuple) {
                            if (init_type.tuple.len != s.names.len)
                                try tc.emitError(s.span,
                                    "destructuring expects {} names but tuple has {} elements",
                                    .{ s.names.len, init_type.tuple.len });
                        } else if (init_type != .unknown) {
                            try tc.emitError(s.span,
                                "destructuring requires a tuple, got '{s}'", .{init_type.name()});
                        }
                    },
                    .struct_ => {
                        // Struct destructuring: `var {name, age} = expr`
                        // The RHS must be a named type (class/struct).  We don't
                        // validate individual field names here — Zig will catch
                        // unknown fields at compile time.
                        if (init_type != .named and init_type != .unknown) {
                            try tc.emitError(s.span,
                                "struct destructuring requires a class or struct, got '{s}'",
                                .{init_type.name()});
                        }
                        // Register each binding's type in loop_var_types so that
                        // subsequent statements (e.g. `print name`) can infer the
                        // correct format specifier.
                        if (init_type == .named) {
                            if (init_type.named.own_scope) |scope| {
                                for (s.names) |fname| {
                                    if (scope.lookupLocal(fname)) |fsym| {
                                        const ftype = tc.symbolType(fsym);
                                        if (ftype != .unknown)
                                            try tc.loop_var_types.put(fname, ftype);
                                    }
                                }
                            }
                        }
                    },
                }
            },
            .pass, .break_, .continue_ => {},
        }
    }

    fn checkReturn(tc: TypeChecker, s: *Ast.StmtReturn) anyerror!void {
        if (s.value) |v| {
            const actual = try tc.inferExpr(v);
            if (!Type.isAssignable(actual, tc.return_type))
                try tc.emitMismatch(spanOf(v), actual, tc.return_type);
        } else {
            if (tc.return_type != .void_ and tc.return_type != .unknown)
                try tc.emitError(s.span, "return without value in non-void method", .{});
        }
    }

    fn checkAssign(tc: TypeChecker, s: *Ast.StmtAssign) anyerror!void {
        const lhs = try tc.inferExpr(s.target);
        const rhs = try tc.inferExpr(s.value);
        if (s.op == .assign) {
            if (!Type.isAssignable(rhs, lhs))
                try tc.emitMismatch(spanOf(s.value), rhs, lhs);
        } else {
            // Compound ops (+= -= etc.) require numeric LHS.
            if (!lhs.isNumeric() and lhs != .unknown)
                try tc.emitError(s.span, "compound assignment requires numeric type, got '{s}'", .{lhs.name()});
        }
    }

    // ── Expression helpers ────────────────────────────────────────────────────

    fn checkBoolExpr(tc: TypeChecker, e: *const Ast.Expr) anyerror!void {
        const t = try tc.inferExpr(e);
        if (t != .bool and t != .unknown)
            try tc.emitMismatch(spanOf(e), t, .bool);
    }

    fn inferNumericExpr(tc: TypeChecker, e: *const Ast.Expr) anyerror!Type {
        const t = try tc.inferExpr(e);
        if (!t.isNumeric() and t != .unknown)
            try tc.emitError(spanOf(e), "expected numeric type, got '{s}'", .{t.name()});
        return t;
    }

    // ── Expression type inference ─────────────────────────────────────────────

    /// Infer, record, and return the type of `expr`.
    fn inferExpr(tc: TypeChecker, expr: *const Ast.Expr) anyerror!Type {
        const t = try tc.inferExprInner(expr);
        try tc.expr_types.put(expr, t);
        return t;
    }

    fn inferExprInner(tc: TypeChecker, expr: *const Ast.Expr) anyerror!Type {
        return switch (expr.*) {
            .int_lit        => .int,
            .float_lit      => .float,
            .bool_lit       => .bool,
            .char_lit       => .char,
            .string_lit     => .string,
            .string_interp  => |e| blk: {
                // Infer sub-expression types so CodeGen can pick {s} vs {} etc.
                for (e.parts) |part| {
                    switch (part) {
                        .expr => |ex| _ = try tc.inferExpr(ex),
                        else  => {},
                    }
                }
                break :blk .string;
            },
            .nil            => .unknown, // context-dependent nilable
            .this           => tc.ext_self_type orelse
                              if (tc.owner_sym) |s| Type{ .named = s } else .unknown,
            .zig_lit        => .unknown, // opaque backend literal
            .ident          => |*e| tc.inferIdent(e),
            .member         => |e| try tc.inferMember(e),
            .call           => |e| try tc.inferCall(e),
            .index          => |e| blk: {
                const ot = try tc.inferExpr(e.object);
                _ = try tc.inferExpr(e.index);
                // string[i] → char
                break :blk if (ot == .string) .char else .unknown;
            },
            .slice          => |e| blk: {
                const ot = try tc.inferExpr(e.object);
                if (e.start) |s| _ = try tc.inferExpr(s);
                if (e.stop)  |s| _ = try tc.inferExpr(s);
                // string[i..j] → string
                break :blk if (ot == .string) .string else .unknown;
            },
            .binary         => |e| try tc.inferBinary(e),
            .unary          => |e| try tc.inferUnary(e),
            .cast           => |e| blk: { _ = try tc.inferExpr(e.expr); break :blk tc.typeFromRef(&e.target); },
            .to_nilable     => |e| blk: { _ = try tc.inferExpr(e.expr); break :blk .unknown; },
            .to_non_nil     => |e| blk: {
                // `expr to!` — force-unwrap optional; result is the inner type.
                const inner = try tc.inferExpr(e.expr);
                break :blk if (inner == .optional) inner.optional.* else inner;
            },
            .is_nil         => |e| blk: { _ = try tc.inferExpr(e.expr); break :blk .bool; },
            .orelse_        => |e| try tc.inferOrelse(e),
            .catch_         => |e| try tc.inferCatch(e),
            .if_expr        => |e| try tc.inferIfExpr(e),
            .lambda         => |e| try tc.inferLambda(e),
            .list_lit       => |e| blk: { for (e.elems) |el| _ = try tc.inferExpr(el);  break :blk .unknown; },
            .dict_lit       => |e| blk: { for (e.entries) |en| { _ = try tc.inferExpr(en.key); _ = try tc.inferExpr(en.value); } break :blk .unknown; },
            .array_lit      => |e| blk: { for (e.elems) |el| _ = try tc.inferExpr(el);  break :blk .unknown; },
            .all_any        => |e| blk: { _ = try tc.inferExpr(e.iter); _ = try tc.inferExpr(e.cond); break :blk .bool; },
            .old            => |e| try tc.inferExpr(e.expr),
            // try expr — may be error propagation OR optional-unwrap (`opt?.x`).
            // Detect optional-unwrap by checking the inner ident's DECLARED type
            // (bypassing nil-narrowing which would make ?Foo look like Foo here).
            .try_ => |e| blk: {
                const inner_t = try tc.inferExpr(e.expr);
                const is_opt_unwrap = if (e.expr.* == .ident) opt: {
                    const sym = tc.resolve.exprs.get(&e.expr.ident) orelse break :opt false;
                    break :opt tc.symbolType(sym) == .optional;
                } else inner_t == .optional;
                if (is_opt_unwrap) try tc.optional_unwraps.put(expr, {});
                break :blk inner_t;
            },
            // Tuple literal: infer each element type and build a tuple Type.
            .tuple_lit      => |e| blk: {
                const elems = try tc.map_alloc.alloc(Type, e.elems.len);
                for (e.elems, elems) |el, *out| out.* = try tc.inferExpr(el);
                break :blk Type{ .tuple = elems };
            },

            // `expr is TypeName` — always produces bool regardless of TypeName.
            // TypeName is validated at code-gen time (if it's unknown, codegen
            // emits a comment rather than crashing).
            .type_check => |e| blk: {
                _ = try tc.inferExpr(e.expr);
                break :blk .bool;
            },
        };
    }

    fn inferIdent(tc: TypeChecker, e: *const Ast.ExprIdent) Type {
        // Check if this ident is nil-narrowed in the current scope.
        if (tc.narrowed_types.get(e.name)) |narrowed| return narrowed;
        const sym = tc.resolve.exprs.get(e) orelse return .unknown;
        const t = tc.symbolType(sym);
        if (t != .unknown) return t;
        // Check if this ident is a loop variable with a known element type.
        return tc.loop_var_types.get(e.name) orelse .unknown;
    }

    fn inferMember(tc: TypeChecker, e: *Ast.ExprMember) anyerror!Type {
        // Cross-module field access: Math.PI where `use Math` imported a dep.
        if (e.object.* == .ident) {
            const mod_sym_opt: ?*const Symbol = switch (e.object.*) {
                .ident => |*id| tc.resolve.exprs.get(id),
                else   => null,
            };
            if (mod_sym_opt) |mod_sym| if (mod_sym.kind == .module) {
                _ = try tc.inferExpr(e.object);
                if (tc.imported_modules) |imp| {
                    if (imp.get(mod_sym.name)) |iface| {
                        const key = try std.fmt.allocPrint(tc.map_alloc,
                            "{s}.{s}", .{ mod_sym.name, e.member });
                        defer tc.map_alloc.free(key);
                        if (iface.fields.get(key))  |t| return t;
                        if (iface.methods.get(key)) |t| return t;
                    }
                }
                return .unknown;
            };
        }
        const obj_type = try tc.inferExpr(e.object);
        // Tuple index access: p.0, p.1, …
        if (obj_type == .tuple) {
            const idx = std.fmt.parseInt(usize, e.member, 10) catch return .unknown;
            if (idx < obj_type.tuple.len) return obj_type.tuple[idx];
            try tc.emitError(e.span, "tuple index {} out of bounds (tuple has {} elements)",
                .{ idx, obj_type.tuple.len });
            return .unknown;
        }
        // `len` property on strings and StringBuilder → usize (represented as .uint)
        if (std.mem.eql(u8, e.member, "len") and
            (obj_type == .string or obj_type == .string_builder)) return .uint;
        // Math constant access: Math.PI, Math.E, Math.TAU, Math.INF, Math.NAN
        if (e.object.* == .ident and std.mem.eql(u8, e.object.ident.name, "Math")) return .float;
        // HttpRequest field access.
        if (obj_type == .http_request) {
            if (std.mem.eql(u8, e.member, "method"))  return .string;
            if (std.mem.eql(u8, e.member, "path"))    return .string;
            if (std.mem.eql(u8, e.member, "content")) return .string;
        }
        // HttpResponse field access.
        if (obj_type == .http_response) {
            if (std.mem.eql(u8, e.member, "status")) return .uint;
            if (std.mem.eql(u8, e.member, "text"))   return .string;
        }
        // DateTime field access.
        if (obj_type == .date_time) {
            if (std.mem.eql(u8, e.member, "year")   or
                std.mem.eql(u8, e.member, "month")  or
                std.mem.eql(u8, e.member, "day")    or
                std.mem.eql(u8, e.member, "hour")   or
                std.mem.eql(u8, e.member, "minute") or
                std.mem.eql(u8, e.member, "second") or
                std.mem.eql(u8, e.member, "weekday")) return .int;
        }
        // CalendarView field access.
        if (obj_type == .calendar_view) {
            if (std.mem.eql(u8, e.member, "year")    or
                std.mem.eql(u8, e.member, "month")   or
                std.mem.eql(u8, e.member, "day")     or
                std.mem.eql(u8, e.member, "weekday")) return .int;
            if (std.mem.eql(u8, e.member, "monthName") or
                std.mem.eql(u8, e.member, "era"))        return .string;
        }
        // SysRunResult field access.
        if (obj_type == .sys_run_result) {
            if (std.mem.eql(u8, e.member, "exit_code")) return .int;
            if (std.mem.eql(u8, e.member, "stdout"))    return .string;
            if (std.mem.eql(u8, e.member, "stderr"))    return .string;
        }
        // UriResult field access.
        if (obj_type == .uri_result) {
            if (std.mem.eql(u8, e.member, "scheme") or
                std.mem.eql(u8, e.member, "host")   or
                std.mem.eql(u8, e.member, "path")   or
                std.mem.eql(u8, e.member, "query"))  return .string;
            if (std.mem.eql(u8, e.member, "port"))   return .int;
        }
        // If the object is an optional type (e.g. after `n?.next` where n is `?Node`),
        // strip the optional wrapper and look up the member on the inner type.
        // This lets the TC correctly infer member types through optional chains.
        const resolved_obj_type = if (obj_type == .optional) obj_type.optional.* else obj_type;
        // Look up the member name in the object type's own scope.
        if (resolved_obj_type == .named) {
            const sym = resolved_obj_type.named;
            if (sym.own_scope) |scope| {
                if (scope.lookupLocal(e.member)) |member_sym| {
                    return tc.symbolType(member_sym);
                }
            }
        }
        // Cross-module instance field/method access: point.x / point.show()
        // where `point` is a `.cross_module` type (e.g. `crossmod_types_lib.Point`).
        if (resolved_obj_type == .cross_module) {
            const cm = resolved_obj_type.cross_module;
            if (tc.imported_modules) |imp| {
                if (imp.get(cm.module)) |iface| {
                    const key = try std.fmt.allocPrint(tc.map_alloc,
                        "{s}.{s}", .{ cm.type_name, e.member });
                    defer tc.map_alloc.free(key);
                    if (iface.fields.get(key))  |t| if (t != .unknown) return t;
                    if (iface.methods.get(key)) |t| if (t != .unknown) return t;
                    // For user-defined field types: return a typed cross_module value
                    // so chained access (inst.field.method()) stays typed.
                    if (iface.instance_field_types.get(key)) |tname|
                        return Type{ .cross_module = .{ .module = cm.module, .type_name = tname } };
                    if (iface.instance_method_return_types.get(key)) |tname|
                        return Type{ .cross_module = .{ .module = cm.module, .type_name = tname } };
                }
            }
        }
        // Generic instance member lookup with type-param substitution.
        // e.g. `p.first` on `Pair(str,int)` → look up `first`, substitute A→str.
        if (obj_type == .generic_named) {
            const gn = obj_type.generic_named;
            if (gn.sym.decl != .class) return .unknown;
            const cls = gn.sym.decl.class;
            if (gn.sym.own_scope) |scope| {
                if (scope.lookupLocal(e.member)) |member_sym| {
                    // For fields/params: substitute type params in declared type.
                    switch (member_sym.decl) {
                        .var_   => |v| if (v.type_) |*t| return tc.substituteTypeParam(t, cls, gn.args),
                        .param  => |p| if (p.type_) |*t| return tc.substituteTypeParam(t, cls, gn.args),
                        // Methods: return symbolType (method return types handled in inferCall).
                        .method => return .unknown, // resolved later in inferCall
                        else    => {},
                    }
                    return tc.symbolType(member_sym);
                }
            }
        }
        return .unknown;
    }

    /// Infer the element type that loop variables will have when iterating `iter`.
    fn inferForInElemType(tc: TypeChecker, iter: *const Ast.Expr) Type {
        // for tag in v.getList("key")  — []JsonValue call → json_value elements
        if (iter.* == .call) {
            if (iter.call.callee.* == .member) {
                const m = iter.call.callee.member.member;
                if (std.mem.eql(u8, m, "getList")) return .json_value;
            }
        }
        // str.split(delim) / str.lines() → each element is a string
        // str.chars() → each element is a char (u21 Unicode codepoint)
        if (iter.* == .call) {
            const callee = iter.call.callee;
            if (callee.* == .member) {
                const m = callee.member.member;
                if (std.mem.eql(u8, m, "split") or std.mem.eql(u8, m, "lines")) {
                    const obj_type = tc.expr_types.get(callee.member.object) orelse .unknown;
                    if (obj_type == .string) return .string;
                }
                if (std.mem.eql(u8, m, "chars")) {
                    const obj_type = tc.expr_types.get(callee.member.object) orelse .unknown;
                    if (obj_type == .string) return .char;
                }
                // re.findAll(s) / re.groups(s) → each element is a string
                if (std.mem.eql(u8, m, "findAll") or std.mem.eql(u8, m, "groups")) {
                    const obj_type = tc.expr_types.get(callee.member.object) orelse .unknown;
                    if (obj_type == .regex) return .string;
                }
                // Net.resolve(host) → each element is a string (IP address)
                if (std.mem.eql(u8, m, "resolve")) {
                    if (callee.member.object.* == .ident and
                        std.mem.eql(u8, callee.member.object.ident.name, "Net")) return .string;
                }
            }
        }
        // str_slice / json_array variable — check expr_types first, then narrowed_types.
        if (iter.* == .ident) {
            const t = tc.expr_types.get(iter) orelse
                tc.narrowed_types.get(iter.ident.name) orelse .unknown;
            if (t == .str_slice)  return .string;
            if (t == .json_array) return .json_value;
        }
        // Loop variable known to be List(T) via list_elem_types (e.g. value var from
        // for k, v in HashMap(K, List(T))) — return its recorded element type.
        if (iter.* == .ident) {
            if (tc.list_elem_types.get(iter.ident.name)) |elem_t| return elem_t;
        }
        // Bare identifier declared as List(T) — extract element type from the
        // variable's type annotation so that for-in loops print correctly.
        if (iter.* == .ident) {
            if (tc.resolve.exprs.get(&iter.ident)) |sym| {
                const decl_type_opt: ?Ast.TypeRef = switch (sym.decl) {
                    .var_  => |dv| dv.type_,
                    .param => |p|  p.type_,
                    else   => null,
                };
                if (decl_type_opt) |dt| {
                    if (dt == .generic and
                        std.mem.eql(u8, dt.generic.name, "List") and
                        dt.generic.args.len > 0)
                    {
                        const elem_tr = &dt.generic.args[0];
                        const t = tc.typeFromRef(elem_tr);
                        if (t != .unknown) return t;
                    }
                }
            }
        }
        // csv.rows() / csv.dataRows() / csv.header() / csv.row(n) → each element is a csv_row
        if (iter.* == .call) {
            if (iter.call.callee.* == .member) {
                const m = iter.call.callee.member;
                if (std.mem.eql(u8, m.member, "rows")     or
                    std.mem.eql(u8, m.member, "dataRows") or
                    std.mem.eql(u8, m.member, "header")   or
                    std.mem.eql(u8, m.member, "row"))
                {
                    const obj_t = tc.expr_types.get(m.object) orelse .unknown;
                    if (obj_t == .csv_table) return .csv_row;
                }
            }
        }
        // for col in hdr where hdr is a csv_row (result of csv.header()/csv.row())
        if (iter.* == .ident) {
            const t = tc.expr_types.get(iter) orelse .unknown;
            if (t == .csv_row) return .string;
        }
        // Cross-module field: `c.args` where `c` has cross_module type and `args` is List(T).
        // Look up list_field_elem_types in the imported module interface.
        if (iter.* == .member) {
            const mem = iter.member;
            if (tc.imported_modules) |imp| {
                // Check narrowed_types first (branch-bound vars like `c` from `on Expr.call as c`
                // are stored there, not in expr_types).
                const obj_type = blk: {
                    if (mem.object.* == .ident) {
                        if (tc.narrowed_types.get(mem.object.ident.name)) |t| break :blk t;
                    }
                    break :blk tc.expr_types.get(mem.object) orelse .unknown;
                };
                if (obj_type == .cross_module) {
                    const cm = obj_type.cross_module;
                    if (imp.get(cm.module)) |iface| {
                        const key = std.fmt.allocPrint(tc.map_alloc, "{s}.{s}", .{ cm.type_name, mem.member }) catch return .unknown;
                        defer tc.map_alloc.free(key);
                        if (iface.list_field_elem_types.get(key)) |elem_name| {
                            return Type{ .cross_module = .{ .module = cm.module, .type_name = elem_name } };
                        }
                    }
                }
            }
        }
        // for_num loop var → int (handled at the call site)
        return .unknown;
    }

    fn inferCall(tc: TypeChecker, e: *Ast.ExprCall) anyerror!Type {
        for (e.args) |arg| _ = try tc.inferExpr(arg.value);
        // Mark fn_ref arguments that are passed to fn_sig parameters so CodeGen
        // can prepend `&` to coerce a function value to a function pointer.
        if (e.callee.* == .ident) {
            if (tc.resolve.exprs.get(&e.callee.ident)) |callee_sym| {
                if (callee_sym.kind == .method) {
                    const params = callee_sym.decl.method.params;
                    for (e.args, 0..) |arg, i| {
                        if (i >= params.len) break;
                        const arg_t = tc.expr_types.get(arg.value) orelse continue;
                        if (arg_t != .fn_ref) continue;
                        const p = params[i];
                        if (p.type_) |*pt| {
                            const param_t = tc.typeFromRef(pt);
                            if (param_t == .fn_sig) {
                                try tc.fn_ref_args.put(arg.value, {});
                            }
                        }
                    }
                }
            }
        }

        // Generic construction: Stack(int)(42) — callee ident resolves to a generic class.
        // type_args.len > 0 is the discriminator set by AstBuilder.buildGenericConstruct.
        // Return generic_named so downstream member lookups can substitute type params.
        if (e.type_args.len > 0) {
            if (e.callee.* == .ident) {
                if (tc.resolve.exprs.get(&e.callee.ident)) |sym| {
                    if (sym.kind == .class) {
                        const arg_types = try tc.map_alloc.alloc(Type, e.type_args.len);
                        for (e.type_args, arg_types) |*ta, *at| at.* = tc.typeFromRef(ta);
                        // Check `where` constraints: each type arg must satisfy its constraint.
                        if (sym.decl == .class) {
                            const cls = sym.decl.class;
                            for (cls.type_params, arg_types) |tp, arg_t| {
                                if (tp.constraint) |iface| {
                                    if (!tc.typeImplements(arg_t, iface)) {
                                        try tc.emitError(e.callee.ident.span,
                                            "type argument does not implement `{s}` (required by `{s}({s})`)",
                                            .{ iface, sym.name, tp.name });
                                    }
                                }
                            }
                        }
                        return Type{ .generic_named = .{ .sym = sym, .args = arg_types } };
                    }
                }
            }
            return .unknown;
        }

        // Special case: direct call of a named method — return its declared
        // return type so that callers can type-check against it.
        switch (e.callee.*) {
            .ident => |*ident| {
                // CsvWriter() bare constructor call.
                if (std.mem.eql(u8, ident.name, "CsvWriter")) return .csv_writer;
                if (tc.resolve.exprs.get(ident)) |sym| {
                    _ = try tc.inferExpr(e.callee);
                    if (sym.kind == .method) {
                        const decl = sym.decl.method;
                        return tc.typeFromOptRef(if (decl.return_type) |*rt| rt else null);
                    }
                    // Exposed class constructor: `use Mod exposing ClassName` then `ClassName(args)`.
                    // The symbol kind is `.module` but the name is the exposed type (not the module alias).
                    // Return `cross_module` so genLocalVar emits `var` (methods take *Self receivers).
                    if (sym.kind == .module and sym.decl == .use) {
                        const use_decl = sym.decl.use;
                        const last_dot = std.mem.lastIndexOf(u8, use_decl.path, ".");
                        const mod_alias = if (last_dot) |d| use_decl.path[d + 1..] else use_decl.path;
                        // If this is an exposed name (sym.name != module alias), it's an exposed type.
                        if (!std.mem.eql(u8, sym.name, mod_alias)) {
                            if (tc.imported_modules) |imp| {
                                if (imp.get(mod_alias)) |iface| {
                                    if (iface.types.getPtr(sym.name)) |kind_ptr| {
                                        if (kind_ptr.* != .union_) {
                                            // Non-union exposed type = class/struct constructor call.
                                            return Type{ .cross_module = .{
                                                .module    = mod_alias,
                                                .type_name = sym.name,
                                            }};
                                        }
                                    }
                                    // Exposed top-level function with a user-defined return type:
                                    // e.g. `analyzeEscapes` returns `StrSet`.
                                    // Key is the function name only — stored in fn_return_types,
                                    // not instance_method_return_types, to avoid key collision.
                                    if (iface.fn_return_types.get(sym.name)) |ret_name| {
                                        return Type{ .cross_module = .{
                                            .module    = mod_alias,
                                            .type_name = ret_name,
                                        }};
                                    }
                                }
                            }
                        }
                    }
                    const sym_type = tc.symbolType(sym);
                    // If the callee is a variable holding a function reference,
                    // chase the reference to get the actual function return type.
                    if (sym_type == .fn_ref) {
                        const ref_sym = sym_type.fn_ref;
                        if (ref_sym.kind == .method) {
                            const decl = ref_sym.decl.method;
                            return tc.typeFromOptRef(if (decl.return_type) |*rt| rt else null);
                        }
                    }
                    // If the callee is a fn_sig-typed local/param, return the sig's return type.
                    if (sym_type == .fn_sig) {
                        const sig_decl = sym_type.fn_sig;
                        return tc.typeFromOptRef(if (sig_decl.return_type) |*rt| rt else null);
                    }
                    return sym_type;
                }
            },
            .member => |mem| {
                // File.* static methods: special-case the File builtin.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "File")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "read"))      return .string;
                    if (std.mem.eql(u8, mem.member, "readLines")) return .unknown; // List(str)
                    if (std.mem.eql(u8, mem.member, "listDir"))   return .unknown; // List(str)
                    if (std.mem.eql(u8, mem.member, "exists"))    return .bool;
                    return .void_;
                }
                // Dir.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Dir")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "exists")) return .bool;
                    if (std.mem.eql(u8, mem.member, "list"))   return .unknown; // List(str)
                    return .void_;
                }
                // Path.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Path")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "isAbsolute")) return .bool;
                    if (std.mem.eql(u8, mem.member, "join") or
                        std.mem.eql(u8, mem.member, "basename") or
                        std.mem.eql(u8, mem.member, "dirname") or
                        std.mem.eql(u8, mem.member, "ext") or
                        std.mem.eql(u8, mem.member, "stem")) return .string;
                    return .void_;
                }
                // Math.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Math")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    // isNaN / isInf return bool; everything else returns float
                    if (std.mem.eql(u8, mem.member, "isNaN") or
                        std.mem.eql(u8, mem.member, "isInf")) return .bool;
                    return .float;
                }
                // Shell.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Shell")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "run")) return .string;
                    return .void_;
                }
                // Http.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Http")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "get") or std.mem.eql(u8, mem.member, "post")) {
                        const boxed = tc.map_alloc.create(Type) catch return .http_response;
                        boxed.* = .http_response;
                        return .{ .optional = boxed };
                    }
                    if (std.mem.eql(u8, mem.member, "json") or std.mem.eql(u8, mem.member, "postJson")) {
                        const boxed = tc.map_alloc.create(Type) catch return .json_value;
                        boxed.* = .json_value;
                        return .{ .optional = boxed };
                    }
                    if (std.mem.eql(u8, mem.member, "serve")) return .void_;
                    return .void_;
                }
                // HttpResponse.* factory methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "HttpResponse")) {
                    _ = try tc.inferExpr(mem.object);
                    return .http_response;  // ok, notFound, new, etc.
                }
                // Tcp.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Tcp")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "connect")) {
                        const boxed = tc.map_alloc.create(Type) catch return .tcp_conn;
                        boxed.* = .tcp_conn;
                        return .{ .optional = boxed };
                    }
                    return .void_;
                }
                // Udp.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Udp")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "socket")) return .udp_socket;
                    return .void_;
                }
                // Result.ok(v) / Result.err(v) — constructors; return type depends on context.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Result")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    return .unknown; // full generic Result type not modelled yet
                }
                // Net.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Net")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "resolve")) return .str_slice;
                    return .void_;
                }
                // Regex.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Regex")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "compile")) return .regex;
                    return .void_;
                }
                // Gui.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Gui")) {
                    _ = try tc.inferExpr(mem.object);
                    // Infer the callback arg so widget method types are checked inside it.
                    if (std.mem.eql(u8, mem.member, "run") and e.args.len >= 4)
                        _ = try tc.inferExpr(e.args[3].value);
                    return .void_;
                }
                // sys.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "sys")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "getenv"))  return .unknown; // ?str
                    if (std.mem.eql(u8, mem.member, "args"))    return .unknown; // List(str)
                    if (std.mem.eql(u8, mem.member, "run"))     return .sys_run_result;
                    if (std.mem.eql(u8, mem.member, "exit"))    return .void_;
                    if (std.mem.eql(u8, mem.member, "err"))     return .void_;
                    if (std.mem.eql(u8, mem.member, "errln"))   return .void_;
                    return .void_;
                }
                // DateTime.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "DateTime")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    return .date_time; // now(), fromEpoch(), of()
                }
                // Calendar.* constant access → string constant in Zig.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Calendar")) {
                    return .string;
                }
                // Csv.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Csv")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    if (std.mem.eql(u8, mem.member, "parse") or
                        std.mem.eql(u8, mem.member, "parseFile")) return .csv_table;
                    return .void_;
                }
                // Reflect.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Reflect")) {
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    if (std.mem.eql(u8, mem.member, "className"))  return .string;
                    if (std.mem.eql(u8, mem.member, "fieldNames") or
                        std.mem.eql(u8, mem.member, "fieldTypes")) return .str_slice;
                    return .unknown;
                }
                // Hash.* static methods — all return a hex string.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Hash")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    return .string;
                }
                // Random.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Random")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    if (std.mem.eql(u8, mem.member, "randInt"))  return .int;
                    if (std.mem.eql(u8, mem.member, "randFloat")) return .float;
                    if (std.mem.eql(u8, mem.member, "randBool"))  return .bool;
                    if (std.mem.eql(u8, mem.member, "bytes"))     return .string;
                    return .void_; // shuffle, seed; choice returns unknown element type
                }
                // Arg.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Arg")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    if (std.mem.eql(u8, mem.member, "parse")) return .arg_result;
                    return .void_;
                }
                // ArgResult instance method calls — flag/has/option/optionInt/positional/usage.
                if (try tc.inferExpr(mem.object) == .arg_result) {
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    if (std.mem.eql(u8, mem.member, "flag"))        return .bool;
                    if (std.mem.eql(u8, mem.member, "contains"))   return .bool;
                    if (std.mem.eql(u8, mem.member, "option"))     return .string;
                    if (std.mem.eql(u8, mem.member, "optionInt"))  return .int;
                    if (std.mem.eql(u8, mem.member, "usage"))      return .string;
                    if (std.mem.eql(u8, mem.member, "positional")) {
                        const boxed = tc.map_alloc.create(Type) catch return .string;
                        boxed.* = .string;
                        return .{ .optional = boxed };
                    }
                    return .unknown;
                }
                // Terminal.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Terminal")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    if (std.mem.eql(u8, mem.member, "width"))  return .int;
                    if (std.mem.eql(u8, mem.member, "height")) return .int;
                    if (std.mem.eql(u8, mem.member, "isTty"))  return .bool;
                    return .void_; // write, writeln
                }
                // Log.* static methods — all return void.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Log")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    return .void_;
                }
                // Uri.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Uri")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    if (std.mem.eql(u8, mem.member, "parse")) return .uri_result;
                    return .unknown;
                }
                // Compress.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Compress")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    if (std.mem.eql(u8, mem.member, "gzip")) return .string;
                    if (std.mem.eql(u8, mem.member, "gunzip")) {
                        const boxed = tc.map_alloc.create(Type) catch return .string;
                        boxed.* = .string;
                        return .{ .optional = boxed };
                    }
                    return .unknown;
                }
                // Mime.* static methods — all return strings.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Mime")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    return .string;
                }
                // Timer.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Timer")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    if (std.mem.eql(u8, mem.member, "start")) return .timer_handle;
                    return .unknown;
                }
                // TimerHandle instance method calls.
                if (try tc.inferExpr(mem.object) == .timer_handle) {
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    if (std.mem.eql(u8, mem.member, "elapsed"))       return .float;
                    if (std.mem.eql(u8, mem.member, "elapsedMicros")) return .int;
                    if (std.mem.eql(u8, mem.member, "reset"))         return .void_;
                    return .unknown;
                }
                // Json.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Json")) {
                    _ = try tc.inferExpr(mem.object);
                    for (e.args) |a| _ = try tc.inferExpr(a.value);
                    if (std.mem.eql(u8, mem.member, "parse")) {
                        const boxed = tc.map_alloc.create(Type) catch return .json_value;
                        boxed.* = .json_value;
                        return .{ .optional = boxed };
                    }
                    if (std.mem.eql(u8, mem.member, "stringify")) return .string;
                    if (std.mem.eql(u8, mem.member, "object"))    return .json_value;
                    if (std.mem.eql(u8, mem.member, "array"))     return .json_value;
                    return .void_;
                }
                // Cross-module call: Math.square(5) where `use Math` imported a dep.
                // Also handles cross-module constructors: crossmod_types_lib.Point(3, 4).
                // Detected by the receiver being a bare ident whose symbol kind is .module.
                if (mem.object.* == .ident) {
                    const mod_sym_opt: ?*const Symbol = switch (mem.object.*) {
                        .ident => |*id| tc.resolve.exprs.get(id),
                        else   => null,
                    };
                    if (mod_sym_opt) |mod_sym| if (mod_sym.kind == .module) {
                        _ = try tc.inferExpr(mem.object);
                        if (tc.imported_modules) |imp| {
                            if (imp.get(mod_sym.name)) |iface| {
                                // Constructor call: ModAlias.TypeName(…) → cross_module instance.
                                if (iface.types.contains(mem.member)) {
                                    return Type{ .cross_module = .{
                                        .module    = mod_sym.name,
                                        .type_name = mem.member,
                                    }};
                                }
                                // Free function / static method call: look up return type.
                                const key = try std.fmt.allocPrint(tc.map_alloc,
                                    "{s}.{s}", .{ mod_sym.name, mem.member });
                                defer tc.map_alloc.free(key);
                                if (iface.methods.get(key)) |ret| return ret;
                                if (iface.fields.get(key))  |ret| return ret;
                            }
                        }
                        return .unknown;
                    };
                }
                // Stdlib method call: infer return type from receiver type + method name.
                const obj_type = try tc.inferExpr(mem.object);
                // Generic instance method call: substitute type params in return type.
                // e.g. `s.pop()` on `Stack(int)` where pop returns `?T` → `?int`.
                if (obj_type == .generic_named) {
                    const gn = obj_type.generic_named;
                    if (gn.sym.decl == .class) {
                        const cls = gn.sym.decl.class;
                        if (gn.sym.own_scope) |scope| {
                            if (scope.lookupLocal(mem.member)) |member_sym| {
                                if (member_sym.kind == .method) {
                                    const decl = member_sym.decl.method;
                                    if (decl.return_type) |*rt|
                                        return tc.substituteTypeParam(rt, cls, gn.args);
                                    return .void_;
                                }
                                // Field access on generic instance.
                                switch (member_sym.decl) {
                                    .var_  => |v| if (v.type_) |*t| return tc.substituteTypeParam(t, cls, gn.args),
                                    .param => |p| if (p.type_) |*t| return tc.substituteTypeParam(t, cls, gn.args),
                                    else   => {},
                                }
                                return tc.symbolType(member_sym);
                            }
                        }
                    }
                }
                // Cross-module instance method call: point.show() / point.distFromOrigin()
                // where `point` has type `.cross_module`.
                if (obj_type == .cross_module) {
                    const cm = obj_type.cross_module;
                    if (tc.imported_modules) |imp| {
                        if (imp.get(cm.module)) |iface| {
                            const key = try std.fmt.allocPrint(tc.map_alloc,
                                "{s}.{s}", .{ cm.type_name, mem.member });
                            defer tc.map_alloc.free(key);
                            if (iface.methods.get(key)) |ret| if (ret != .unknown) return ret;
                            if (iface.fields.get(key))  |ret| if (ret != .unknown) return ret;
                            // For user-defined return types: return a typed cross_module value.
                            if (iface.instance_method_return_types.get(key)) |tname|
                                return Type{ .cross_module = .{ .module = cm.module, .type_name = tname } };
                            if (iface.instance_field_types.get(key)) |tname|
                                return Type{ .cross_module = .{ .module = cm.module, .type_name = tname } };
                        }
                    }
                }
                // User-defined class/struct methods: look up declared return type.
                if (obj_type == .named) {
                    const class_sym = obj_type.named;
                    if (class_sym.own_scope) |scope| {
                        if (scope.lookupLocal(mem.member)) |member_sym| {
                            if (member_sym.kind == .method) {
                                const decl = member_sym.decl.method;
                                return tc.typeFromOptRef(if (decl.return_type) |*rt| rt else null);
                            }
                            // Union variant constructor: Shape.circle(...) → Shape
                            if (member_sym.kind == .union_variant) return obj_type;
                            return tc.symbolType(member_sym);
                        }
                    }
                    // No scope match but object is a union — still a variant constructor.
                    if (class_sym.kind == .union_) return obj_type;
                    // Exposed cross-module type: `Generator` from `use codegen exposing Generator`
                    // has kind=.module but own_scope is null (it's a reference, not the definition).
                    // Treat instance method calls as cross_module lookups so the return type propagates.
                    if (class_sym.kind == .module and class_sym.decl == .use) {
                        const use_decl = class_sym.decl.use;
                        const last_dot = std.mem.lastIndexOf(u8, use_decl.path, ".");
                        const mod_alias = if (last_dot) |d| use_decl.path[d + 1..] else use_decl.path;
                        if (tc.imported_modules) |imp| {
                            if (imp.get(mod_alias)) |iface| {
                                const key = try std.fmt.allocPrint(tc.map_alloc,
                                    "{s}.{s}", .{ class_sym.name, mem.member });
                                defer tc.map_alloc.free(key);
                                if (iface.methods.get(key)) |ret| if (ret != .unknown) return ret;
                                if (iface.instance_method_return_types.get(key)) |tname|
                                    return Type{ .cross_module = .{ .module = mod_alias, .type_name = tname } };
                            }
                        }
                    }
                }
                // Extension method lookup: "TypeName.method" in ext_methods map.
                if (tc.extTypeName(obj_type)) |tname| {
                    const key = try std.fmt.allocPrint(tc.map_alloc, "{s}.{s}", .{tname, mem.member});
                    defer tc.map_alloc.free(key);
                    if (tc.ext_methods.get(key)) |ext_meth| {
                        return tc.typeFromOptRef(if (ext_meth.return_type) |*rt| rt else null);
                    }
                }
                // Generic method inference (List.at, HashMap.fetch, Result.*):
                // Extract the declared TypeRef of the receiver — handles both direct idents
                // (x.at(0)) and field-access chains (c.items.at(0)).
                const maybe_dtr: ?Ast.TypeRef = blk: {
                    if (mem.object.* == .ident) {
                        if (tc.resolve.exprs.get(&mem.object.ident)) |sym| {
                            break :blk switch (sym.decl) {
                                .var_   => |v| v.type_,
                                .param  => |p| p.type_,
                                else    => null,
                            };
                        }
                    } else if (mem.object.* == .member) {
                        // Field-access chain: c.items — look up `items` in the class that `c` belongs to.
                        // By the time we arrive here, inferExpr(mem.object) at line 1514 has already
                        // populated expr_types for the inner object (e.g., the `c` ident).
                        const inner = mem.object.member;
                        if (tc.expr_types.get(inner.object)) |owner_type| {
                            if (owner_type == .named) {
                                const class_sym = owner_type.named;
                                if (class_sym.own_scope) |scope| {
                                    if (scope.lookupLocal(inner.member)) |field_sym| {
                                        if (field_sym.decl == .var_) {
                                            break :blk field_sym.decl.var_.type_;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    break :blk null;
                };
                if (maybe_dtr) |dtr| {
                    // List(T).at(i) → T
                    if (dtr == .generic and std.mem.eql(u8, dtr.generic.name, "List") and
                        std.mem.eql(u8, mem.member, "at") and dtr.generic.args.len >= 1)
                    {
                        return tc.typeFromRef(&dtr.generic.args[0]);
                    }
                    // HashMap(K,V).fetch(k) → V
                    if (dtr == .generic and std.mem.eql(u8, dtr.generic.name, "HashMap") and
                        std.mem.eql(u8, mem.member, "fetch") and dtr.generic.args.len >= 2)
                    {
                        return tc.typeFromRef(&dtr.generic.args[1]);
                    }
                    if (dtr == .generic and std.mem.eql(u8, dtr.generic.name, "Result")) {
                        const gtr = dtr.generic;
                        if (std.mem.eql(u8, mem.member, "okValue") and gtr.args.len >= 1) {
                            const inner_t = tc.typeFromRef(&gtr.args[0]);
                            const boxed = tc.map_alloc.create(Type) catch return .unknown;
                            boxed.* = inner_t;
                            return Type{ .optional = boxed };
                        }
                        if (std.mem.eql(u8, mem.member, "errValue") and gtr.args.len >= 2) {
                            const inner_t = tc.typeFromRef(&gtr.args[1]);
                            const boxed = tc.map_alloc.create(Type) catch return .unknown;
                            boxed.* = inner_t;
                            return Type{ .optional = boxed };
                        }
                        if (std.mem.eql(u8, mem.member, "unwrap") and gtr.args.len >= 1)
                            return tc.typeFromRef(&gtr.args[0]);
                        if (std.mem.eql(u8, mem.member, "unwrapOr") and gtr.args.len >= 1)
                            return tc.typeFromRef(&gtr.args[0]);
                    }
                }
                return tc.inferStdlibMethodType(obj_type, mem.member);
            },
            else => {},
        }
        _ = try tc.inferExpr(e.callee);
        return .unknown;
    }

    /// Return type of a stdlib method call given the receiver's inferred Type.
    fn inferStdlibMethodType(tc: TypeChecker, obj_type: Type, method: []const u8) Type {
        _ = tc;
        // String methods
        if (obj_type == .string) {
            const str_string = std.StaticStringMap(void).initComptime(&.{
                .{ "concat",    {} }, .{ "format",    {} }, .{ "trim",      {} },
                .{ "trimLeft",  {} }, .{ "trimRight", {} },
                .{ "upper",     {} }, .{ "lower",     {} }, .{ "replace",   {} }, .{ "repeat",    {} },
                .{ "padLeft",   {} }, .{ "padRight",  {} }, .{ "center",    {} }, .{ "bytes",     {} },
                .{ "join",           {} }, .{ "lines",        {} }, .{ "reverse",    {} },
                .{ "toHex",          {} }, .{ "fromHex",      {} }, .{ "chars",      {} },
            });
            const str_int = std.StaticStringMap(void).initComptime(&.{
                .{ "toInt",          {} }, .{ "indexOf",      {} }, .{ "count",      {} },
                .{ "codePointCount", {} },
            });
            const str_bool = std.StaticStringMap(void).initComptime(&.{
                .{ "contains",     {} }, .{ "startsWith",  {} }, .{ "endsWith",    {} },
                .{ "isEmpty",      {} }, .{ "isAlpha",     {} }, .{ "isNumeric",   {} },
                .{ "isValidUtf8",  {} },
            });
            if (str_string.get(method) != null) return .string;
            if (str_int.get(method)    != null) return .int;
            if (str_bool.get(method)   != null) return .bool;
            if (std.mem.eql(u8, method, "toFloat")) return .float;
        }
        // StringBuilder methods
        if (obj_type == .string_builder) {
            if (std.mem.eql(u8, method, "build")) return .string;
            if (std.mem.eql(u8, method, "len"))   return .uint;
            return .void_;  // append, appendChar, clear all return void
        }
        // TcpConn methods
        if (obj_type == .tcp_conn) {
            if (std.mem.eql(u8, method, "read"))      return .string;
            if (std.mem.eql(u8, method, "readLine"))  return .string;
            if (std.mem.eql(u8, method, "readBytes")) return .string;
            return .void_;  // write, close
        }
        // UdpSocket methods
        if (obj_type == .udp_socket) {
            if (std.mem.eql(u8, method, "recv")) return .string;
            return .void_;  // send, close
        }
        // Regex methods
        if (obj_type == .regex) {
            if (std.mem.eql(u8, method, "match"))   return .bool;
            if (std.mem.eql(u8, method, "find"))    return .string;
            if (std.mem.eql(u8, method, "findAll")) return .unknown; // []const []const u8 slice — not modelled
            if (std.mem.eql(u8, method, "groups"))  return .unknown; // []const []const u8 slice — not modelled
            if (std.mem.eql(u8, method, "replace")) return .string;
            return .void_;
        }
        // Gui widget methods (on gui_context receiver)
        if (obj_type == .gui_context) {
            if (std.mem.eql(u8, method, "button"))   return .bool;
            if (std.mem.eql(u8, method, "checkbox")) return .bool;
            if (std.mem.eql(u8, method, "slider"))   return .float;
            if (std.mem.eql(u8, method, "input"))         return .string;
            if (std.mem.eql(u8, method, "inputMultiline")) return .string;
            // void-returning widgets
            return .void_;  // text, separator, sameLine, spacing, indent, unindent, panel, window
        }
        // Shell methods
        if (obj_type == .shell) {
            if (std.mem.eql(u8, method, "run")) return .string;
            return .void_;
        }
        // DateTime methods
        if (obj_type == .date_time) {
            if (std.mem.eql(u8, method, "addDays")    or
                std.mem.eql(u8, method, "addMonths")  or
                std.mem.eql(u8, method, "addYears")   or
                std.mem.eql(u8, method, "addHours")   or
                std.mem.eql(u8, method, "addMinutes") or
                std.mem.eql(u8, method, "addSeconds")) return .date_time;
            if (std.mem.eql(u8, method, "before") or
                std.mem.eql(u8, method, "after")  or
                std.mem.eql(u8, method, "equals"))    return .bool;
            if (std.mem.eql(u8, method, "daysBetween") or
                std.mem.eql(u8, method, "secondsBetween") or
                std.mem.eql(u8, method, "toEpoch"))       return .int;
            if (std.mem.eql(u8, method, "toIso8601") or
                std.mem.eql(u8, method, "format"))        return .string;
            if (std.mem.eql(u8, method, "inCalendar"))    return .calendar_view;
            return .void_;
        }
        // JsonValue methods
        if (obj_type == .json_value) {
            if (std.mem.eql(u8, method, "getStr"))   return .string;
            if (std.mem.eql(u8, method, "getInt"))   return .int;
            if (std.mem.eql(u8, method, "getFloat")) return .float;
            if (std.mem.eql(u8, method, "getBool"))  return .bool;
            if (std.mem.eql(u8, method, "getObj"))   return .json_value;
            if (std.mem.eql(u8, method, "getList")) return .json_array;
            if (std.mem.eql(u8, method, "isNull"))   return .bool;
            if (std.mem.eql(u8, method, "isObject")) return .bool;
            if (std.mem.eql(u8, method, "isArray"))  return .bool;
            return .void_;  // put/putInt/putFloat/putBool/append/appendInt/appendFloat/appendBool
        }
        // HttpResponse instance methods
        if (obj_type == .http_response) {
            if (std.mem.eql(u8, method, "withHeader")) return .http_response;
            return .unknown;
        }
        // CsvTable methods
        if (obj_type == .csv_table) {
            if (std.mem.eql(u8, method, "rowCount") or std.mem.eql(u8, method, "colCount")) return .int;
            if (std.mem.eql(u8, method, "header") or std.mem.eql(u8, method, "row")) return .csv_row;
            if (std.mem.eql(u8, method, "get")) return .string;
            return .unknown;  // rows(), dataRows() — for-in handles element type separately
        }
        // CsvWriter methods
        if (obj_type == .csv_writer) {
            if (std.mem.eql(u8, method, "build")) return .string;
            return .void_;  // writeRow
        }
        // CsvRow methods (behaves like List(str))
        if (obj_type == .csv_row) {
            if (std.mem.eql(u8, method, "at")) return .string;
            if (std.mem.eql(u8, method, "count") or std.mem.eql(u8, method, "len")) return .int;
            return .unknown;
        }
        // str_slice methods ([]str — e.g. Reflect.fieldNames, Net.resolve)
        if (obj_type == .str_slice) {
            if (std.mem.eql(u8, method, "at"))    return .string;
            if (std.mem.eql(u8, method, "count")) return .int;
        }
        // File methods (static-style)
        if (obj_type == .file) {
            if (std.mem.eql(u8, method, "listDir")) return .unknown; // List(str) — not modelled
            return .unknown;
        }
        // Result(T, E) methods — obj_type is .unknown since generics not modelled; check by method name
        if (std.mem.eql(u8, method, "isOk") or std.mem.eql(u8, method, "isErr")) return .bool;
        // map/flatMap return .unknown (result type depends on the transform function, not tracked)
        if (std.mem.eql(u8, method, "map") or std.mem.eql(u8, method, "flatMap")) return .unknown;
        // unwrap/unwrapOr/okValue/errValue return .unknown (inner type not tracked)
        // toString() on any type → string
        if (std.mem.eql(u8, method, "toString")) return .string;
        // List / HashMap methods
        const count_methods = std.StaticStringMap(void).initComptime(&.{
            .{ "count", {} },
        });
        const bool_methods = std.StaticStringMap(void).initComptime(&.{
            .{ "contains", {} },
        });
        const void_list_methods = std.StaticStringMap(void).initComptime(&.{
            .{ "sort", {} }, .{ "sortBy", {} },
        });
        if (count_methods.get(method)      != null) return .int;
        if (bool_methods.get(method)       != null) return .bool;
        if (void_list_methods.get(method)  != null) return .void_;
        return .unknown;
    }

    fn inferBinary(tc: TypeChecker, e: *Ast.ExprBinary) anyerror!Type {
        const lt = try tc.inferExpr(e.left);
        const rt = try tc.inferExpr(e.right);

        return switch (e.op) {
            // Comparisons and membership always produce bool.
            .eq, .ne, .lt, .le, .gt, .ge, .in_ => .bool,

            // Logical: operands must be bool.
            .and_, .or_ => blk: {
                if (lt != .bool and lt != .unknown)
                    try tc.emitMismatch(spanOf(e.left), lt, .bool);
                if (rt != .bool and rt != .unknown)
                    try tc.emitMismatch(spanOf(e.right), rt, .bool);
                break :blk .bool;
            },

            // String repetition: str * int → string.
            .mul => blk: {
                if (lt == .string and (rt.isIntFamily() or rt.isUintFamily())) break :blk .string;
                if (lt == .unknown or rt == .unknown) break :blk .unknown;
                if (!lt.isNumeric())
                    try tc.emitError(spanOf(e.left), "arithmetic requires numeric type, got '{s}'", .{lt.name()});
                if (!rt.isNumeric())
                    try tc.emitError(spanOf(e.right), "arithmetic requires numeric type, got '{s}'", .{rt.name()});
                if (lt.isNumeric() and rt.isNumeric() and !Type.eql(lt, rt))
                    try tc.emitError(e.span, "arithmetic operands must have the same type: '{s}' vs '{s}'", .{ lt.name(), rt.name() });
                break :blk if (lt.isNumeric()) lt else .unknown;
            },

            // Arithmetic: operands must be numeric and the same type.
            .add, .sub, .div, .int_div, .mod, .pow => blk: {
                // String + String → string concatenation.
                if (e.op == .add and lt == .string) break :blk .string;
                if (lt == .unknown or rt == .unknown) break :blk .unknown;
                if (!lt.isNumeric())
                    try tc.emitError(spanOf(e.left), "arithmetic requires numeric type, got '{s}'", .{lt.name()});
                if (!rt.isNumeric())
                    try tc.emitError(spanOf(e.right), "arithmetic requires numeric type, got '{s}'", .{rt.name()});
                if (lt.isNumeric() and rt.isNumeric() and !Type.eql(lt, rt))
                    try tc.emitError(e.span, "arithmetic operands must have the same type: '{s}' vs '{s}'", .{ lt.name(), rt.name() });
                break :blk if (lt.isNumeric()) lt else .unknown;
            },

            // Bitwise: operands must be integer family.
            .bit_and, .bit_or, .bit_xor, .shl, .shr => blk: {
                if (!lt.isIntFamily() and !lt.isUintFamily() and lt != .unknown)
                    try tc.emitError(spanOf(e.left), "bitwise operator requires integer type, got '{s}'", .{lt.name()});
                if (!rt.isIntFamily() and !rt.isUintFamily() and rt != .unknown)
                    try tc.emitError(spanOf(e.right), "bitwise operator requires integer type, got '{s}'", .{rt.name()});
                break :blk lt; // preserve the operand type
            },

            // Range: type not modelled yet.
            .dotdot => .unknown,
        };
    }

    fn inferUnary(tc: TypeChecker, e: *Ast.ExprUnary) anyerror!Type {
        const ot = try tc.inferExpr(e.operand);
        return switch (e.op) {
            .neg => blk: {
                if (!ot.isNumeric() and ot != .unknown)
                    try tc.emitError(spanOf(e.operand), "unary '-' requires numeric type, got '{s}'", .{ot.name()});
                break :blk if (ot.isNumeric()) ot else .unknown;
            },
            .not_ => blk: {
                if (ot != .bool and ot != .unknown)
                    try tc.emitMismatch(spanOf(e.operand), ot, .bool);
                break :blk .bool;
            },
            .bit_not => blk: {
                if (!ot.isIntFamily() and !ot.isUintFamily() and ot != .unknown)
                    try tc.emitError(spanOf(e.operand), "bitwise 'not' requires integer type, got '{s}'", .{ot.name()});
                break :blk ot; // preserve the operand type
            },
            .old => ot, // pre-call value — same type as operand
        };
    }

    fn inferOrelse(tc: TypeChecker, e: *Ast.ExprOrelse) anyerror!Type {
        const et = try tc.inferExpr(e.expr);
        const ft = try tc.inferExpr(e.fallback);
        // Unwrap: `opt orelse fallback` has the inner (non-optional) type.
        const inner = if (et == .optional) et.optional.* else et;
        // Fallback must be assignable to the inner type.
        if (inner != .unknown and ft != .unknown and !Type.isAssignable(ft, inner))
            try tc.emitMismatch(spanOf(e.fallback), ft, inner);
        // When the optional's inner type is unknown (e.g., generic type param),
        // use the fallback's type so print/assignment gets a concrete type hint.
        return if (inner != .unknown) inner else ft;
    }

    fn inferCatch(tc: TypeChecker, e: *Ast.ExprCatch) anyerror!Type {
        const et = try tc.inferExpr(e.expr);
        const ft = try tc.inferExpr(e.fallback);
        // The fallback should be assignable to the non-error form of expr's type.
        if (et != .unknown and ft != .unknown and !Type.isAssignable(ft, et))
            try tc.emitMismatch(spanOf(e.fallback), ft, et);
        return et;
    }

    fn inferIfExpr(tc: TypeChecker, e: *Ast.ExprIf) anyerror!Type {
        try tc.checkBoolExpr(e.cond);
        const tt = try tc.inferExpr(e.then_expr);
        const et = try tc.inferExpr(e.else_expr);
        // Both branches should have the same type.
        if (tt != .unknown and et != .unknown and !Type.isAssignable(et, tt))
            try tc.emitMismatch(spanOf(e.else_expr), et, tt);
        return if (tt != .unknown) tt else et;
    }

    fn inferLambda(tc: TypeChecker, e: *Ast.ExprLambda) anyerror!Type {
        // When the lambda has no explicit return type, use .unknown so that
        // `return expr` inside the body isn't checked against void.
        const ret: Type = if (e.return_type) |*rt| tc.typeFromRef(rt) else .unknown;
        const inner = tc.withReturn(ret);
        switch (e.body) {
            .expr  => |ex| _ = try inner.inferExpr(ex),
            .stmts => |ss| try inner.checkStmts(ss),
        }
        return .unknown; // function types not modelled yet
    }

    // ── Symbol type ───────────────────────────────────────────────────────────

    /// Get the value type of `sym`.
    ///
    /// - Variables and parameters → their declared type (or `unknown` if inferred).
    /// - Methods → `unknown` (use `inferCall` to get the return type at a call site).
    /// - Type symbols → `named(sym)` (the symbol represents the type itself).
    fn symbolType(tc: TypeChecker, sym: *const Symbol) Type {
        return switch (sym.kind) {
            .class, .interface, .struct_, .mixin, .enum_ => .{ .named = sym },
            .namespace_   => .unknown, // namespaces are not value-typed
            .method       => .{ .fn_ref = sym }, // first-class function reference
            .property     => {
                const decl = sym.decl.property;
                return tc.typeFromOptRef(if (decl.type_) |*t| t else null);
            },
            .var_, .local => switch (sym.decl) {
                .var_ => |decl| {
                    // Prefer the explicitly declared type.
                    if (decl.type_) |*t| {
                        const declared = tc.typeFromRef(t);
                        if (declared != .unknown) return declared;
                    }
                    // Fall back to the type inferred from the initialiser, if any.
                    if (decl.init) |init| return tc.expr_types.get(init) orelse .unknown;
                    return .unknown;
                },
                .catch_binding => .unknown, // error-binding var — error set type deferred
                else           => .unknown,
            },
            .param => {
                const p = sym.decl.param;
                return tc.typeFromOptRef(if (p.type_) |*t| t else null);
            },
            .enum_member   => .unknown, // TODO: resolve to parent enum type
            .union_        => .{ .named = sym }, // the union type itself
            .union_variant => .unknown, // TODO: resolve to parent union type
            .module        => .unknown, // imported module — cross-file types not yet resolved
            .type_param    => .unknown, // generic type parameter — concrete type determined at instantiation
            .sig_          => .{ .fn_sig = sym.decl.sig_ }, // sig used as a value (rare; for symmetry)
        };
    }

    // ── TypeRef → Type ────────────────────────────────────────────────────────

    fn typeFromOptRef(tc: TypeChecker, tr: ?*const Ast.TypeRef) Type {
        return if (tr) |t| tc.typeFromRef(t) else .void_;
    }

    /// Convert a `TypeRef` to a `Type` by consulting the Resolver's side-table.
    ///
    /// Compound types (`?T`, `!T`, generics) return `unknown` — they will be
    /// handled in a later pass that models nilable and error-union wrappers.
    fn typeFromRef(tc: TypeChecker, tr: *const Ast.TypeRef) Type {
        return switch (tr.*) {
            .named => |*n| blk: {
                const resolved = tc.resolve.types.get(n) orelse break :blk .unknown;
                break :blk switch (resolved) {
                    .builtin => blk2: {
                        const t = builtinType(n.name);
                        if (t != .unknown) break :blk2 t;
                        // Cross-module TypeRef: "ModAlias.TypeName" — look up in imported_modules.
                        if (std.mem.indexOfScalar(u8, n.name, '.')) |dot| {
                            const mod       = n.name[0..dot];
                            const type_name = n.name[dot+1..];
                            if (tc.imported_modules) |imp| {
                                if (imp.get(mod)) |iface| {
                                    if (iface.types.contains(type_name)) {
                                        break :blk2 Type{ .cross_module = .{
                                            .module    = mod,
                                            .type_name = type_name,
                                        }};
                                    }
                                }
                            }
                        }
                        break :blk2 .unknown;
                    },
                    .symbol  => |s| switch (s.kind) {
                        .type_param => .unknown,
                        .sig_       => .{ .fn_sig = s.decl.sig_ }, // named delegate type
                        else        => .{ .named = s },
                    },
                };
            },
            .nilable => |inner| blk: {
                const inner_type = tc.typeFromRef(inner);
                const boxed = tc.map_alloc.create(Type) catch break :blk .unknown;
                boxed.* = inner_type;
                break :blk Type{ .optional = boxed };
            },
            // ^T — heap-indirection: type-check as the inner type (pointer is a codegen detail).
            .ref_to => |inner| tc.typeFromRef(inner),
            // Compound types deferred to a later pass.
            .stream, .error_union, .generic => .unknown,
            .void_ => .void_,
            .same  => if (tc.owner_sym) |s| Type{ .named = s } else .unknown,
            .tuple => |ttr| blk: {
                const elems = tc.map_alloc.alloc(Type, ttr.elems.len) catch break :blk .unknown;
                for (ttr.elems, elems) |*el, *out| out.* = tc.typeFromRef(el);
                break :blk Type{ .tuple = elems };
            },
        };
    }

    // ── Generic type-param substitution ──────────────────────────────────────

    /// Resolve a TypeRef to a concrete Type, substituting generic type params
    /// from `cls.type_params` with the concrete `args` from a `generic_named`.
    ///
    /// Example: Stack(int) has args=[.int], type_params=["T"].
    /// substituteTypeParam(TypeRef.named("T"), Stack, [.int]) → .int
    /// substituteTypeParam(TypeRef.nilable("T"), Stack, [.int]) → .optional(.int)
    fn substituteTypeParam(
        tc:     TypeChecker,
        tr:     *const Ast.TypeRef,
        cls:    *const Ast.DeclClass,
        args:   []const Type,
    ) Type {
        switch (tr.*) {
            .named => |*n| {
                const resolved = tc.resolve.types.get(n) orelse return .unknown;
                switch (resolved) {
                    .builtin => return builtinType(n.name),
                    .symbol  => |s| {
                        if (s.kind == .type_param) {
                            // Match param name to index, return concrete arg type.
                            for (cls.type_params, 0..) |tp, i| {
                                if (std.mem.eql(u8, tp.name, n.name))
                                    return if (i < args.len) args[i] else .unknown;
                            }
                            return .unknown;
                        }
                        return .{ .named = s };
                    },
                }
            },
            .nilable => |inner| {
                const inner_t = tc.substituteTypeParam(inner, cls, args);
                const boxed = tc.map_alloc.create(Type) catch return .unknown;
                boxed.* = inner_t;
                return Type{ .optional = boxed };
            },
            .ref_to  => |inner| return tc.substituteTypeParam(inner, cls, args),
            .generic => return .unknown,  // nested generics (e.g., List(T)) — not yet substituted
            .void_   => return .void_,
            .same    => return if (tc.owner_sym) |s| Type{ .named = s } else .unknown,
            else     => return .unknown,
        }
    }

    // ── Where-constraint checking ─────────────────────────────────────────────

    /// Returns true if `t` satisfies the constraint `implements InterfaceName`.
    ///
    /// Rules:
    ///   • Built-in orderable/comparable types (int, uint, float, str, bool, char)
    ///     implicitly satisfy `Comparable`.
    ///   • A user class satisfies the constraint if its `implements` list contains
    ///     a TypeRef whose name matches `iface_name`, directly or transitively.
    ///   • All types satisfy `Any` (escape hatch).
    fn typeImplements(tc: TypeChecker, t: Type, iface_name: []const u8) bool {
        if (std.mem.eql(u8, iface_name, "Any")) return true;
        return switch (t) {
            // Numeric/ordinal primitives intrinsically satisfy Comparable.
            // bool and string are excluded: they have no declared compareTo contract.
            .int, .uint, .float, .char,
            .int_n, .uint_n, .float_n => std.mem.eql(u8, iface_name, "Comparable"),
            .named         => |sym| tc.symbolImplements(sym, iface_name, 16),
            .generic_named => |gn|  tc.symbolImplements(gn.sym, iface_name, 16),
            else => false,
        };
    }

    /// DFS through the implements hierarchy, depth-limited to `budget` to guard
    /// against cycles.  Returns true if `sym` directly or transitively satisfies
    /// `iface_name`.
    fn symbolImplements(tc: TypeChecker, sym: *const Symbol, iface_name: []const u8, budget: u8) bool {
        if (budget == 0) return false;
        const impls: []const Ast.TypeRef = switch (sym.decl) {
            .class     => |c| c.implements,
            .interface => |i| i.implements,
            .struct_   => |s| s.implements,
            else       => return false,
        };
        for (impls, 0..) |_, idx| {
            const tr = &impls[idx]; // stable arena pointer
            if (tr.* != .named) continue;
            // Direct match.
            if (std.mem.eql(u8, tr.named.name, iface_name)) return true;
            // Transitive: resolve the interface and recurse.
            if (tc.resolve.types.get(&tr.named)) |resolved| {
                if (resolved == .symbol) {
                    if (tc.symbolImplements(resolved.symbol, iface_name, budget - 1)) return true;
                }
            }
        }
        return false;
    }

    // ── Diagnostics ───────────────────────────────────────────────────────────

    fn emitError(tc: TypeChecker, span: Ast.Span, comptime fmt: []const u8, args: anytype) anyerror!void {
        const msg = try std.fmt.allocPrint(tc.diag_alloc, fmt, args);
        try tc.diags.append(tc.diag_alloc, .{ .span = span, .kind = .err, .message = msg });
    }

    fn emitMismatch(tc: TypeChecker, span: Ast.Span, actual: Type, expected: Type) anyerror!void {
        try tc.emitError(span, "type mismatch: expected '{s}', got '{s}'", .{ expected.name(), actual.name() });
    }
};

// ── Span extraction ───────────────────────────────────────────────────────────

fn spanOf(expr: *const Ast.Expr) Ast.Span {
    return switch (expr.*) {
        .int_lit       => |e| e.span,
        .float_lit     => |e| e.span,
        .bool_lit      => |e| e.span,
        .char_lit      => |e| e.span,
        .string_lit    => |e| e.span,
        .string_interp => |e| e.span,
        .nil           => |s| s,
        .this          => |s| s,
        .zig_lit       => |e| e.span,
        .ident         => |e| e.span,
        .member        => |e| e.span,
        .call          => |e| e.span,
        .index         => |e| e.span,
        .slice         => |e| e.span,
        .binary        => |e| e.span,
        .unary         => |e| e.span,
        .cast          => |e| e.span,
        .to_nilable    => |e| e.span,
        .to_non_nil    => |e| e.span,
        .is_nil        => |e| e.span,
        .orelse_       => |e| e.span,
        .catch_        => |e| e.span,
        .if_expr       => |e| e.span,
        .lambda        => |e| e.span,
        .list_lit      => |e| e.span,
        .dict_lit      => |e| e.span,
        .array_lit     => |e| e.span,
        .all_any       => |e| e.span,
        .old           => |e| e.span,
        .try_          => |e| e.span,
        .tuple_lit     => |e| e.span,
        .type_check    => |e| e.span,
    };
}

// ── Builtin name → Type ───────────────────────────────────────────────────────

fn builtinType(n: []const u8) Type {
    if (std.mem.eql(u8, n, "StringBuilder"))  return .string_builder;
    if (std.mem.eql(u8, n, "HttpRequest"))    return .http_request;
    if (std.mem.eql(u8, n, "HttpResponse"))   return .http_response;
    if (std.mem.eql(u8, n, "TcpConn"))       return .tcp_conn;
    if (std.mem.eql(u8, n, "UdpSocket"))     return .udp_socket;
    if (std.mem.eql(u8, n, "Regex"))         return .regex;
    if (std.mem.eql(u8, n, "Gui"))          return .gui_context;
    if (std.mem.eql(u8, n, "Shell"))         return .shell;
    if (std.mem.eql(u8, n, "File"))          return .file;
    if (std.mem.eql(u8, n, "SysRunResult")) return .sys_run_result;
    if (std.mem.eql(u8, n, "JsonValue"))   return .json_value;
    if (std.mem.eql(u8, n, "DateTime"))    return .date_time;
    if (std.mem.eql(u8, n, "CalendarView")) return .calendar_view;
    return switch (Builtins.scalarKind(n)) {
        .int        => .int,
        .uint       => .uint,
        .float      => .float,
        .bool       => .bool,
        .char       => .char,
        .string     => .string,
        .void_      => .void_,
        .unknown    => .unknown,
        .int_n   => |bits| .{ .int_n   = bits },
        .uint_n  => |bits| .{ .uint_n  = bits },
        .float_n => |bits| .{ .float_n = bits },
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn checkSnippet(src: []const u8) anyerror!TestResult {
    const Tokenizer  = @import("Tokenizer.zig");
    const Parser     = @import("Parser.zig");
    const AstBuilder = @import("AstBuilder.zig");

    const alloc = testing.allocator;

    const tokens = try Tokenizer.tokenize(src, alloc);
    defer alloc.free(tokens);

    var parse_result = try Parser.parse(tokens, alloc);
    defer parse_result.deinit();

    const ok = switch (parse_result) {
        .ok  => |*s| s,
        .err => |e| {
            std.debug.print("parse error at token {}\n", .{e.error_pos});
            return error.ParseFailed;
        },
    };

    var sym_arena = std.heap.ArenaAllocator.init(alloc);
    errdefer sym_arena.deinit();

    const module = try AstBuilder.build(ok, sym_arena.allocator());

    var bind = try Binder.bindPass1(module, sym_arena.allocator(), alloc);
    defer bind.deinit();

    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc, null);

    const tc = try typeCheckPass3(module, &resolve, alloc, alloc, null);
    return .{ .resolve = resolve, .tc = tc, .sym_arena = sym_arena };
}

const TestResult = struct {
    resolve:   Resolver.ResolveResult,
    tc:        TypeCheckResult,
    sym_arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestResult) void {
        self.tc.deinit();
        self.resolve.deinit();
        self.sym_arena.deinit();
    }
};

test "typecheck: int literal" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as int
        \\        return 42
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: string literal" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as String
        \\        return "hello"
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: bool literal in condition" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run
        \\        if true
        \\            pass
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: param type flows to return" {
    var tr = try checkSnippet(
        \\class Greeter
        \\    def greet(name as String) as String
        \\        return name
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: local var type matches init" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as int
        \\        var x as int = 0
        \\        return x
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: return type mismatch" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as int
        \\        return "oops"
        \\
    );
    defer tr.deinit();
    try testing.expect(tr.tc.hasErrors());
    try testing.expectEqual(@as(usize, 1), tr.tc.diags.len);
    try testing.expect(std.mem.indexOf(u8, tr.tc.diags[0].message, "int") != null);
    try testing.expect(std.mem.indexOf(u8, tr.tc.diags[0].message, "String") != null);
}

test "typecheck: var decl type mismatch" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run
        \\        var x as int = "hello"
        \\
    );
    defer tr.deinit();
    try testing.expect(tr.tc.hasErrors());
    try testing.expectEqual(@as(usize, 1), tr.tc.diags.len);
}

test "typecheck: arithmetic on matching types" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as int
        \\        var x as int = 1
        \\        var y as int = 2
        \\        return x + y
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: arithmetic type mismatch" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as int
        \\        var x as int = 1
        \\        var y as float = 2.0
        \\        return x + y
        \\
    );
    defer tr.deinit();
    try testing.expect(tr.tc.hasErrors());
}

test "typecheck: logical and on bools" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as bool
        \\        return true and false
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: call return type used in return" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def id(x as int) as int
        \\        return x
        \\    def run as int
        \\        return id(1)
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}
