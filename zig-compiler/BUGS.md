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

### BUG-014: Regex lazy match is global, not per-quantifier
- **Severity:** Medium
- **Status:** Open — architectural limitation
- **Symptom:** In a pattern mixing lazy and greedy quantifiers (e.g., `<.*?>.*>`), the global `lazy_match` flag makes ALL quantifiers lazy, so `<.*?>.*>` on `<a><b>` returns `<a>` instead of `<a><b>`.
  - Simple lazy patterns `<.*?>` work correctly.
  - Mixed patterns `<.*?>STUFF.*>` misbehave.
- **Root cause:** The current Thompson NFA passes a global `shortest: bool` to `matchAt`. When ANY `*?`/`+?`/`??` is parsed, `flags.lazy_match = true` is set for the whole regex. The `out1`/`out2` ordering in split nodes DOES encode per-quantifier preference, but `shortest=true` causes the match loop to exit at the FIRST match found, which overrides the greedy `.*` that should extend further.
- **Fix (architectural):** Requires either:
  1. A priority-first NFA simulation (track thread priorities; when multiple threads reach match, highest-priority wins based on `out1`/`out2` ordering path) — complex to implement
  2. A backtracking regex engine — simpler but worst-case O(2^n)
- **Workaround:** For patterns needing mixed lazy/greedy, split into multiple regex calls or restructure the pattern.

---

### BUG-015: `scanMutationsInto` missing `.assert` case — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `scanMutationsInto` handled `.var_`, `.expr`, `.print`, etc. but had no `.assert` case. Method calls on user-defined types inside `assert` conditions (e.g., `assert d.show() == "x"`) were never scanned. The mutation scanner's conservative rule ("any method call on a `.named` type marks the receiver as `var`") never fired for assert conditions, so the receiver was emitted `const`. Then Zig rejected passing `*const Diag` to a method taking `*Diag`.
- **Fix:** Added `.assert => |s| try scanMutationsInExpr(s.cond, set, tc_opt)` to `scanMutationsInto`.
- **Found by:** Self-hosting probe (`test/selfhost_probe.zbr`) — `assert d.show() == "..."` triggered it.

---

### LANG-001: Top-level `def` not supported — FIXED 2026-04-10
- **Status:** Fixed
- **Was:** `def kindName(k as TokenKind) as str` at top level (outside any class) was a syntax error. `TopDecl` didn't include `MethodDecl`.
- **Fix:**
  - `ZebraGrammar.zig`: Added `TopDecl → MethodDecl` production.
  - `AstBuilder.zig`: Added `MethodDecl` case in `buildTopDecl`, setting `is_top_level = true` on the resulting `DeclMethod`.
  - `Ast.zig`: Added `is_top_level: bool = false` field to `DeclMethod`.
  - `CodeGen.zig`: In the bare-ident-call path (for calls within class methods), `is_top_level` methods skip the `self.` / `ClassName.` prefix and call directly by name.
  - Binder, Resolver, TypeChecker, and `genTopDecl` already handled top-level `method` decls.

---

### LANG-002: `on X return Y` inline form and blank-line sensitivity — FIXED 2026-04-10
- **Status:** Fixed
- **Was (a):** `on X  return Y` (no comma, inline return) failed to parse. `on X, return Y` (comma + return) also failed because `StmtReturn → kw_return Expr eol` requires a trailing `eol`, making `return` incompatible with the inline `on X, Stmt` production when `Stmt` doesn't include its own eol.
- **Was (b):** The inline comma form (`on X, return Y`) silently broke with a blank line after the last on-clause because the blank line emitted a bare `eol` token that landed inside `StmtBranch`'s expected `dedent`.
- **Fix (a):** Added `BranchOnClause → kw_on Expr kw_return Expr eol` production to `ZebraGrammar.zig`. `AstBuilder.buildBranchOnClause` detects this as `kids.len == 5 and kids[2] == kw_return` and wraps the return value in a synthetic `StmtReturn`. Now `on TokenKind.ident return "ident"` is valid syntax.
- **Fix (b):** Added `BranchOnList → BranchOnList eol` production. `collectBranchOnList` skips blank-line nodes (checking `isLeafKind(kids[1], .eol)`).
- **Verified:** `test/selfhost_probe.zbr` uses native top-level `def` + `on X return Y` syntax and passes.

### BUG-016: `inferMember` didn't unwrap optional type before member lookup — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `inferMember` only looked up fields/methods when `obj_type == .named`. For chained optional accesses like `n?.next` (where `n: ?Node`), the TC type of `n` passed to `inferMember` was `.optional(.named(Node))` — not `.named`. The member lookup silently returned `.unknown`. Local vars initialised from such accesses (`var n2 = n?.next`) then had `.unknown` declared type, so the `optional_unwraps` check for `n2?` failed and CodeGen emitted `try n2.field` (error-propagation) instead of `n2.?.field` (optional-unwrap).
- **Fix:** Added `resolved_obj_type = if (obj_type == .optional) obj_type.optional.* else obj_type` before the `.named` member lookup. The `generic_named` branch was not affected (it already has its own path).
- **Found by:** Recursive type test (`test/recursive_type_test.zbr`) — `n2?.value` where `n2` was inferred from a chained optional access.

---

### LANG-003: `^T` heap-indirection type for recursive structs — ADDED 2026-04-10
- **Status:** Implemented
- **What:** `var next as ^Node?` declares a heap-allocated pointer to `Node?`, breaking Zig's recursive struct size cycle. `^T` emits `*T` in Zig; `^T?` emits `?*T`. Type-checked as `T` (the pointer is a codegen detail only).
- **Auto-boxing:** Assignments like `a.next = b` where `a.next` is `^Node?` auto-box `b`: emits `{ const _rp = _allocator.create(Node) catch ...; _rp.* = b; a.next = _rp; }`. Value-copy semantics: the snapshot at boxing time is what's stored; later mutations to the original don't propagate to the boxed copy.
- **Test:** `test/recursive_type_test.zbr`

---

### LANG-004: Cross-module TypeRef resolution — ADDED 2026-04-10, EXTENDED 2026-04-10
- **Status:** Implemented (extended from MVP to full TC inference)
- **What:** `var x as Mod.TypeName` in a file that `use Mod` now resolves correctly. `Mod.TypeName(args)` constructor calls return TC type `.cross_module` (not `.unknown`) so method calls on the result are fully typed. String methods on cross-module instances now correctly use `std.mem.eql` instead of raw `==`.
- **How:** `ModuleInterface` tracks exported type names; `Resolver` handles dotted names; `TypeChecker` added `.cross_module { module, type_name }` Type variant returned by `typeFromRef` for cross-module TypeRefs and by `inferCall` for cross-module constructor calls; `inferMember`/`inferCall` look up field/method types in `imported_modules` when `obj_type == .cross_module`. Library modules now export `_initAllocator` and root `main` propagates its allocator to all imported modules.
- **Limitation:** Nested/chained cross-module method return types (e.g. `a.crossMod().method()`) still resolve to `.unknown`. Full cross-module generic type propagation is future work.
- **Test:** `test/crossmod_types_test.zbr` — now includes `assert p.show() == "(3, 4)"` and `assert s.label() == "(0, 0) to (3, 4)"`.

### LANG-005: `^T` auto-boxing for cross-class field assignments — FIXED 2026-04-10
- **Status:** Fixed
- **What:** `^T` (non-optional heap-indirection) field boxing via `ref_box_type_name` now works when the target field belongs to a different class than the one being generated. Previously `resolveFieldTypeRef` only searched `owner_class` which was only set for generic classes.
- **Fix:**
  1. `genClass` now uses `withClass(n)` (new helper) instead of `withOwner(n.name)`, so `owner_class` is set for ALL concrete classes.
  2. `ref_box_type_name` extended: for `localVar.field = x` targets, after searching `owner_class`, falls back to looking up the field via the TC type of the object. For nested `a.b.field = x`, looks up `field` in the declared type of `a.b`.
- **Test:** `test/recursive_type_test.zbr` — `PairHolder` test with non-optional `^Pair` field.

### BUG-017: `len` on unknown-TC-type emits `.items.len` heuristic — imprecise
- **Severity:** Low
- **Status:** Open — known imprecision; deferred until ModuleInterface preserves return types
- **Symptom:** When a local variable's TC type is `.unknown` (most commonly: the result of a cross-module method call whose return type isn't tracked in `ModuleInterface.methods`) and `.len` is accessed on it, CodeGen emits `.items.len` as a last-resort fallback. This is correct for `ArrayList`-backed `List(T)` values but is wrong for any user-defined struct that has a field named `len`.
- **Example that triggered it:** `lexer_test.zbr` — `var toks = Lexer.tokenize(src)` returned a cross-module `List(Token.Token)`; `toks.len` needed `.items.len`. TC type of `toks` was `.unknown` because `ModuleInterface.methods` stores only `TypeChecker.Type` scalars, not generic `List(T)` return shapes.
- **Root cause:** `ModuleInterface` does not preserve enough information to know that `Lexer.tokenize` returns a `List(Token.Token)`. The methods map stores `Type` values which have no "list of T" variant. So cross-module list-returning calls always land with `.unknown` TC type, and the `len` heuristic fires.
- **Proper fix:** Add a `.list { elem_type }` variant to `TypeChecker.Type`, store it in `ModuleInterface.methods` for methods that return `List(T)`, and propagate it through `inferCall` for cross-module calls. Then the heuristic can be removed; `len` on a `.list` type correctly emits `.items.len`, and `len` on any other type emits `.len` (for slices/strings).
- **Risk of current heuristic:** A user struct with a field named `len` whose type can't be inferred cross-module will silently get `.items.len` emitted — producing a Zig compile error (not a silent wrong answer), so the bug is detectable.
- **Found by:** Self-hosting Phase 1 (`selfhost/lexer_test.zbr`).

### BUG-018: Top-level `def` referenced inside class method set `uses_self = true` — FIXED 2026-04-10
- **Status:** Fixed 2026-04-10
- **Was:** `refsInExpr` set `uses_self = true` for ANY `.method` symbol, including top-level `def` functions (LANG-001). When a class method body called a top-level function (e.g., `opName(o)` inside `Calc.describe`), `uses_self` was incorrectly True, so the compiler omitted `_ = self;`. Zig then reported "unused function parameter" for `self`.
- **Fix:** `refsInExpr` now checks `sym.decl.method.is_top_level`; top-level methods do NOT set `uses_self`. Only instance method references (where the call is emitted as `self.method()`) mark self as used.
- **Found by:** Running full test suite after restoring Phase 1 self-hosting changes. `test/branch_inline_return_test.zbr` → `describe` called the top-level `opName`.

---

### BUG-019: `fn_ref` assignment in `genAssign` owns its own `;\n` terminator
- **Severity:** Low
- **Status:** Open
- **Target:** 0.5 (cleanup)
- **Symptom:** The `fn_ref_emitted` block inside `genAssign`'s `else` branch short-circuits with its own `try g.w.writeAll(";\n"); return;` instead of falling through to the shared `try g.w.writeAll(";\n")` at the bottom of the function. This asymmetry means that if any post-processing is ever added after the shared terminator (e.g., debug annotations, error redirects), the fn-ref path silently skips it.
- **Fix:** Restructure so `fn_ref_emitted` sets a flag and falls through to the shared terminator. Alternatively, extract the `;\n` + return pattern into a small helper so all early-exit paths are consistent.
- **Found by:** Post-implementation review of fn-ref reassignment (`pred = isDigit` → `pred = &isDigit`).

---

### BUG-020: `branch/on` call-expr pattern emitted wrong Zig — FIXED 2026-04-10
- **Status:** Fixed 2026-04-10
- **Was:** `on SomeUnion.variant() as x` in a `branch` on-clause is parsed as a call expression (callee = member `SomeUnion.variant`, args = []). `genBranch` only handled the `.member` case for union switch patterns, so a call expression fell through to `genExpr(v)`, which emitted the union constructor form `SomeUnion{ .variant = {} }` — a struct literal, not a valid Zig switch pattern.
- **Fix:** Added `else if (v.* == .call and v.call.callee.* == .member)` branch in `genBranch`'s union pattern path, extracting `v.call.callee.member.member` as the variant name and emitting `.variant_name`.
- **Also fixed:** Non-union `on PlainEnum.member` (no parens, `is_union = false`) was calling `genExpr(v)` for a `.member` node. Added `else if (v.* == .member)` in the non-union path to emit `.member_name` — correct Zig enum switch syntax.
- **Found by:** Self-hosting Phase 2 (`selfhost/ast_test.zbr`) — `on ast.TypeRef.nilable() as inner_ref` and `on ast.BinaryOp.add`.

---

### BUG-021: Struct `cue init` stamped `_type_tag` (class-only field) — FIXED 2026-04-10
- **Status:** Fixed 2026-04-10
- **Was:** `genInit` always emitted `self._type_tag = _ttag_StructName` as the first line of any `cue init` body. Structs have no `_type_tag` field (only classes do); the emitted assignment caused a Zig compile error (`no field named '_type_tag' in struct 'StructName'`).
- **Fix:** Added `is_struct_owner: bool = false` field to Generator. `genStruct` uses `var sg = g.withOwner(n.name)` (already done) and then sets `sg.is_struct_owner = true`. `genInit` wraps the `_type_tag` stamp in `if (!g.is_struct_owner)`.
- **Found by:** Self-hosting Phase 2 (`selfhost/ast.zbr`) — first struct with an explicit `cue init`.

---

### BUG-022: `boxed_variants` not cloned in `cloneInterface` — FIXED 2026-04-10
- **Status:** Fixed 2026-04-10
- **Was:** `cloneInterface` in `main.zig` cloned `types`, `throws_methods`, and `exposed_unions` from a `ModuleInterface` but not the new `boxed_variants` map (added for `^T` union payload boxing). Re-imported modules received an empty/uninitialized `boxed_variants`, so cross-module `^T` union construction silently skipped the boxing expression and emitted the raw value — producing a Zig type-mismatch error (`expected '*T', found 'T'`).
- **Fix:** Added full key/value clone loop for `boxed_variants` in `cloneInterface`. Also added `boxed_variants = std.StringHashMap([]const u8).init(alloc)` to the empty stub interface used for circular-import detection.
- **Found by:** Self-hosting Phase 2 (`selfhost/ast.zbr`) — cross-module `TypeRef.nilable` construction.

---

### BUG-023: Multi-line `cue init` blocked by indentation validator — FIXED 2026-04-10
- **Status:** Fixed 2026-04-10
- **Was:** The tokenizer's `processIndentation` function checked indentation on EVERY new line, including continuation lines inside open parentheses. A `cue init(a as int, b as int)` spanning two lines would trigger "SpaceIndentNotMultipleOfFour" because the continuation line's alignment indentation wasn't a multiple of 4. All `cue init` signatures had to fit on one line regardless of parameter count.
- **Fix:** Added `paren_depth: u32 = 0` tracking to Tokenizer. Incremented in `scanOperator` on `(` and decremented on `)`. Also incremented in `scanIdentOrKeyword`'s `open_call` path (which consumed `(` without going through `scanOperator`). `processIndentation` returns early when `paren_depth > 0`. EOL tokens suppressed when `paren_depth > 0` to prevent parser syntax errors on continuation lines.
- **Found by:** Self-hosting Phase 2 (`selfhost/ast.zbr`) — forced all `cue init` signatures onto single lines.

---

### BUG-024: `throws` auto-propagation missing — FIXED 2026-04-10
- **Status:** Fixed 2026-04-10
- **Was:** Calling a `throws` method from inside a `throws` method required explicit `?` suffix on every call. Without `?`, Zig rejects the call with "error union is ignored". CodeGen had no mechanism to auto-emit `try` for callee methods. This was a self-hosting blocker for the Parser phase (which throws on every input).
- **Fix:** Added `current_method_throws: bool = false` to Generator, set in `genMethod` when the method signature or body requires error return. Two propagation paths:
  1. **Bare-name calls** (`ident` callee resolved via `resolve.exprs`): auto-emits `try ` prefix when `callee_throws && current_method_throws && !in_try_block && !suppress_auto_try`.
  2. **Self-method calls** (`.method()` syntax → callee is `member(this, "name")`): walks `owner_members` for the method by name; same guard conditions.
  3. **Cross-module calls** (`Mod.method()` callee): checks `imported_modules[mod].throws_methods`; same guards.
- **`suppress_auto_try` flag:** The `.try_` codegen path (Zebra `expr?`) already emits `try ` before calling `genExpr`. Without suppression, genCall would add a second `try`, producing `try try self.foo()`. `suppress_auto_try` is set via a `g2 = g; g2.suppress_auto_try = true` local copy before delegating.
- **`owner_members` field:** Added to Generator (set by `withClass` and `genStruct`). Enables `exprCallIsThrows` to detect `this.method()` calls that throw — needed so `genTryCatch` declares the tracking variable as `var` (not `const`) when the try body contains bare self-method calls.
- **Found by:** Self-hosting Phase 2 planning + throws_autoprop_test.zbr.

---

*Last updated: 2026-04-10*

---

### BUG-009: `opt?.field` emits `try opt.?.field` inside `if opt != nil` guard — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `opt?.x` inside an `if opt != nil` block generated `try opt.?.x` instead of `opt.?.x`. Root cause was two-layered:
  1. `exprHasTry`/`bodyHasRaise` treated all `.try_` nodes as error propagation, causing `Main.main()` to get `anyerror!void` return type even when `opt` was a plain optional.
  2. `genExpr` for `.try_` used `tc.expr_types.get(inner_ident)` to detect optional unwraps, but inside a nil-guard the ident's TC type is already narrowed to the non-optional inner type — so the optional check always missed.
- **Fix:** TypeChecker now populates `optional_unwraps: AutoHashMap(*const Ast.Expr, void)` in TypeCheckResult. When inferring a `.try_` node, it checks the inner ident's **declared** type (via `symbolType`, which bypasses nil-narrowing) rather than the inferred type. `exprHasTry` and `genExpr` both consult `optional_unwraps` instead of `expr_types`. The nil-narrowed `genIdent` path (which already emits `name.?`) is detected and the extra `.?` suppressed to prevent double-unwrap.
