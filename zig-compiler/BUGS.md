# Zebra Compiler — Bug Tracker

Running triage list. Updated each milestone. Format: severity (blocker/high/medium/low), status (open/fixed/deferred), and milestone target.

---

## Open Bugs

### BUG-001: ~~Shared method calling shared method emits `self.` prefix~~ — FIXED
- **Status:** Fixed (prior session — TCO work fixed bare shared method calls)
- Was: `testHelper()` inside a shared method generated `self.testHelper()`.
- Now: emits `ClassName.methodName()` correctly for shared→shared calls.

---

### BUG-002: `guard` + `try_postfix` runtime error propagation
- **Severity:** Medium
- **Status:** Open
- **Target:** 0.3 or 0.5 (source-mapped errors)
- **Symptom A (`guard_test`):** `checkPositive` raises inside a guard else block; top-level `try Main.main()` panics with `error: ZebraError`.
- **Symptom B (`try_postfix_test`):** `safeDiv(10,0)?` propagates through `main throws`; top-level panics. The test doesn't catch the error — it's testing propagation but exits non-zero.
- **Note:** Both are likely correct behavior for Zebra error semantics. The tests need `try/catch` wrapping to validate error propagation without panicking. Test quality issue + potentially a compiler issue with top-level error display.

---

### BUG-003: ~~HTTP `serve` fails on Windows with "comptime call of extern function"~~ — FIXED
- **Status:** Fixed 2026-04-09
- Was: `_Ctx` struct stored `handler: Handler` where `Handler = @TypeOf(handler)` is a bare function type (comptime-only in Zig). Made the entire struct comptime-only, so `page_allocator.create(_Ctx)` triggered the `NtAllocateVirtualMemory` comptime path.
- Fix: Declare `const _HFn = *const fn(HttpRequest) HttpResponse` and coerce `const _fn: _HFn = handler` before `_Ctx`. Store `handler_fn: _HFn` in `_Ctx` (fn-pointer = runtime type). Call `ctx.handler_fn(_req)` directly. All three HTTP routes verified working on Windows.

---

### BUG-004: `padLeft/padRight/center` — fill char `'*'` passed as string to `u8` param — FIXED this session
- **Status:** Fixed 2026-04-08
- Was: `_pad_left(s, n, "*", alloc)` failed — `"*"` is `*const [1:0]u8`, not `u8`.
- Fix: Changed pad helpers to accept `anytype` fill; added `_pad_fill` normaliser that handles both char literals (comptime_int) and 1-char strings (pointer).

---

## Library Files with No Entry Point (Expected "Failures")

These are not bugs — they're library files that can't run standalone:
- `MathUtils.zbr` — utility class, imported by `crossmod_*`, `use_test`, `transitive_test`
- `StringHelper.zbr` — utility class, imported by `transitive_test`

---

## Intentional Error Tests (Correct Behavior)

These fail WITH A COMPILER ERROR — that IS the test passing:
- `branch_infer_miss_test.zbr` — expects error for non-exhaustive branch
- `branch_missing_test.zbr` — expects error for missing variant
- `capture_error.zbr` — expects error for undeclared capture

---

---

### BUG-005: `{d:0>N}` format adds `+` prefix to positive `i64` in Zig 0.15 — FIXED
- **Status:** Fixed 2026-04-09
- **Context:** DateTime preamble `_dt_to_iso8601` and `_dt_format` used `i64` fields with `{d:0>N}` format spec. Zig 0.15.2 adds a `+` sign to positive signed integers when using fill-aligned format (e.g. `{d:0>4}` for `i64 = 1970` → `+1970`).
- **Fix:** Cast all date fields to unsigned types (`@as(u32, ...)`, `@as(u8, ...)`) before passing to `bufPrint`/`allocPrint`. Unsigned integers never receive a sign prefix.
- **Broader note:** This is a Zig 0.15 breaking change from 0.14. Any future preamble code that formats `i64` values with fill-aligned specs should cast to unsigned first.

---

### BUG-006: `zig"..."` expression statement emits double semicolon
- **Severity:** Low
- **Status:** Open
- **Target:** 0.5 (low priority)
- **Symptom:** `zig"some_stmt;"` inside a method body emits `some_stmt;;` — the zig literal already ends with `;`, and `genStmt` for `.expr` always appends another `;`.
- **Fix:** In the `.expr` case of `genStmt`, detect when the expression is a `zig_lit` ending with `;` and skip the trailing `;\n` append.

---

---

### BUG-007: `String + String` string concatenation not handled — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `+` operator on strings fell through to the numeric `else` branch in `genBinary`, emitting `(a + b)` which Zig rejects for `[]const u8`. TypeChecker also rejected `String + String` as arithmetic.
- **Fix:**
  - TypeChecker `inferBinary`: added `if (e.op == .add and lt == .string) break :blk .string` before the numeric guard.
  - CodeGen `genBinary`: added dedicated `.add` case — if left operand is string, emits `_str_concat(a, b, _allocator)`.
  - Preamble: added `_str_concat(a, b, alloc)` using `std.mem.concat`.
- **Note:** String concat was previously untested; all prior tests used interpolation `"${var}"` or `StringBuilder`. Now `greeting + ", " + name` style works.

---

---

### BUG-008: Mutation scanner — `.unknown` TC type caused spurious `var` — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** When `tc.resolve.exprs` had no entry for an ident used as a method receiver (common for stdlib builtins like `sys.args()`), `inferIdent` returned `.unknown`, which the scanner conservatively treated as always-mutating — marking variables like `args` as `var` when they should be `const`.
- **Fix:** Removed the `if (obj_type == .unknown) break :blk true` conservative path. Unknown types now fall through to the explicit allow-list. Added `if (obj_type == .string) break :blk false` guard: Zebra strings are always immutable, so no method call should mark a string var as `var`. These two changes together fix `string_methods_test` (`str.reverse()` was in the List-mutation allow-list) and `sys_test` (`args.count()` was treating the unresolved `args` as always-mutating).

---

### BUG-009: Escape analysis — field writes not propagated — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `propagateEscapesOnce` only traced `var y = <expr>` alias chains. If a variable was stored into a returned struct's field (`result.items = list; return result`), `list` was not marked escaped and would get a `defer list.deinit()` while `result.items` still referenced its memory — a UAF.
- **Fix:** Added `.assign => |s|` handling in `propagateEscapesOnce`: if the assignment target is a field access (`obj.field`) and `obj` is already in the escaped set, all idents in the RHS value are added to the escaped set.

---

### BUG-010: Partial class — duplicate method silently appended — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `mergePartialInto` concatenated all members from a partial without checking for name conflicts. If a partial redefined a method already in the root file, both definitions were appended, producing a Zig compile error with a confusing message about the generated file.
- **Fix:** `mergePartialInto` now scans for duplicate method names before merging. Duplicates emit a clear warning (`"duplicate method 'ClassName.method' — already defined in root"`) and the partial definition is skipped. Non-method members (vars, properties) are still appended unconditionally.

---

### BUG-011: `tcTypeAnnotation` — comprehensive type annotation for `var` locals
- **Status:** Fixed 2026-04-09
- **Context:** Previously `genLocalVar` used an ad-hoc 6-case inline switch (`.int`, `.uint`, `.float`, `.bool`, `.char`, `.string`) to emit type annotations on mutable local variables. Several cases were missing: sized numerics (`int32`, `uint8`), optional wrappers (`?str`), and `str_slice` (`[]str`).
- **Fix:** Replaced the inline switch with `tcTypeAnnotation(t, alloc)` — a dedicated module-level function mapping all `TypeChecker.Type` variants to Zig annotation strings. All results are uniformly heap-allocated and freed with `defer`. Unknown types and named/stdlib types return null (Zig infers correctly for those). The generic-type assumption (generics always have explicit AST annotations so tcTypeAnnotation is never called for them) is documented inline.

---

### BUG-012: `_type_id` uninitialized for classes without explicit `cue init` — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** Classes with no explicit `cue init` were constructed via `ClassName{}` (struct literal), which sets fields to their defaults. The `_type_id: u32 = _tid_ClassName` field default worked in simple cases but was structurally fragile — any path that bypassed struct-literal construction (e.g., inline Zig `= undefined`) left `_type_id` garbage.
- **Fix:** `genClass` now checks whether any member (own or mixin) is `.init`. If not, a synthetic default `pub fn init() ClassName` is emitted that explicitly stamps `self._type_id = _tid_ClassName`. The constructor call site was updated to emit `ClassName.init()` instead of `ClassName{}` for classes with no explicit init, so all construction paths go through init().

---

### BUG-013: `collectEnumMembers` — blank-line leaf detection used structural comparison — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `if (kids[1] != .leaf)` in `collectEnumMembers` was a structural assumption about the tree shape — it relied on the fact that blank-line productions always produce `.leaf` nodes, which is an implementation detail of the Earley grammar output format.
- **Fix:** Replaced with the named helper `isMeaningfulNode(tn: TN) bool` (returns `true` only for `.inner` nodes), co-located with the other tree-node helpers near the bottom of `AstBuilder.zig`. Intent is now explicit: skip everything that isn't a grammar rule reduction.

---

*Last updated: 2026-04-10*

---

### BUG-009: `opt?.field` emits `try opt.?.field` inside `if opt != nil` guard — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `opt?.x` inside an `if opt != nil` block generated `try opt.?.x` instead of `opt.?.x`. Root cause was two-layered:
  1. `exprHasTry`/`bodyHasRaise` treated all `.try_` nodes as error propagation, causing `Main.main()` to get `anyerror!void` return type even when `opt` was a plain optional.
  2. `genExpr` for `.try_` used `tc.expr_types.get(inner_ident)` to detect optional unwraps, but inside a nil-guard the ident's TC type is already narrowed to the non-optional inner type — so the optional check always missed.
- **Fix:** TypeChecker now populates `optional_unwraps: AutoHashMap(*const Ast.Expr, void)` in TypeCheckResult. When inferring a `.try_` node, it checks the inner ident's **declared** type (via `symbolType`, which bypasses nil-narrowing) rather than the inferred type. `exprHasTry` and `genExpr` both consult `optional_unwraps` instead of `expr_types`. The nil-narrowed `genIdent` path (which already emits `name.?`) is detected and the extra `.?` suppressed to prevent double-unwrap.
