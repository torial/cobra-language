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

### BUG-003: HTTP `serve` fails on Windows with "comptime call of extern function"
- **Severity:** High (server_test blocked)
- **Status:** Open
- **Target:** 0.3 (needed for Http.json/postJson)
- **Symptom:** `Http.serve(port, handler)` fails to compile on Windows. The `_http_serve` preamble function uses `page_allocator` in a context that gets evaluated at comptime when the handler closure type is being monomorphized.
- **Error:** `error: comptime call of extern function` from `PageAllocator.zig:33`
- **Fix area:** `CodeGen.zig` HTTP preamble — ensure `_http_serve` doesn't allocate at comptime; may need to restructure the handler dispatch or use `std.heap.c_allocator` or defer the allocation.

---

### BUG-004: `padLeft/padRight/center` — fill char `'*'` passed as string to `u8` param — FIXED this session
- **Status:** Fixed 2026-04-08
- Was: `_pad_left(s, n, "*", alloc)` failed — `"*"` is `*const [1:0]u8`, not `u8`.
- Fix: Changed pad helpers to accept `anytype` fill; added `_pad_fill` normaliser that handles both char literals (comptime_int) and 1-char strings (pointer).

---

## Library Files with No Entry Point (Expected "Failures")

These are not bugs — they're library files that can't run standalone:
- `MathUtils.zbr` — utility class, imported by other tests
- `StringHelper.zbr` — utility class
- `mathlib_test.zbr` — uses multi-file `use` which the compiler handles separately
- `hello.zbr` — no `main`, depends on another file

---

## Intentional Error Tests (Correct Behavior)

These fail WITH A COMPILER ERROR — that IS the test passing:
- `branch_infer_miss_test.zbr` — expects error for non-exhaustive branch
- `branch_missing_test.zbr` — expects error for missing variant
- `capture_error.zbr` — expects error for undeclared capture

---

*Last updated: 2026-04-08*
