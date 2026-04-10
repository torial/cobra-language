# Zebra Compiler Test Expansion — Issues Log

**Date:** 2026-04-07  
**Status:** Ready for Sonnet resolution  
**Test Task:** Expanding stub tests to comprehensive coverage (Tasks #1-#9 completed)

---

## Critical Issues

### Issue #1: Code Generation Bug — Shared Method-to-Method Calls

**Severity:** CRITICAL  
**Impact:** ~20+ expanded test files cannot compile  
**Root Cause:** Shared methods calling other shared methods generate invalid Zig code with undefined `self` identifier

**Error Signature:**
```
test\<file>.zig:NNN:N: error: use of undeclared identifier 'self'
    self.testHelper();
    ^~~~
```

**Affected Files:**
- greet.zbr (testGreeter → main calls)
- string_index_test.zbr (testCharIndexing → main calls)
- capture_boundary.zbr (testSimpleCapture → main calls)
- crossmod_infer_test.zbr
- dispatch_diag.zbr
- with_test.zbr
- gui_test.zbr
- raise_auto.zbr
- server_test.zbr
- file_io_test.zbr
- string_methods.zbr
- use_test.zbr
- transitive_test.zbr
- And ~7 more files with shared helper methods

**Example Pattern (FAILS):**
```zebra
class Main
    shared
        def testHelper
            var x = 5
            print x
        
        def main
            testHelper()  # ← Generates: self.testHelper()
                          # ← Error: undefined 'self' in shared context
```

**Working Pattern (SUCCESS):**
```zebra
class Main
    shared
        def main
            # Inline test code directly in main
            var x = 5
            print x
```

**Fix Options:**
1. **Compiler Fix (Preferred):** Correct code generation for shared method-to-shared method calls
   - Should NOT emit `self.` for shared-to-shared calls (or should use implicit receiver)
   - Likely in `CodeGen.zig` or `ZigGenerator.zig`

2. **Test Refactoring (Workaround):** Restructure tests to avoid helper method pattern
   - Move test code from helpers directly into main()
   - Use comments to separate test sections
   - Less ideal but unblocks testing immediately

**Related Code Generation Files:**
- `zig-compiler/src/CodeGen.zig`
- `zig-compiler/src/ZigGenerator.zig` (or equivalent)
- Check: how shared method calls are generated in Zig output

---

### Issue #2: String Concatenation Operator `+` Not Supported

**Severity:** HIGH  
**Impact:** Several test files have syntax errors  
**Root Cause:** The `+` operator doesn't work for string concatenation in Zebra

**Error Pattern:**
```
test/<file>.zbr:NNN:NN: error: arithmetic requires numeric type, got 'str'/'String'
    return "Hello, " + name + "!"
```

**Files Already Fixed:**
- greet.zbr ✅
- dns_test.zbr ✅
- result_test.zbr ✅
- sort_test.zbr ✅
- sys_test.zbr ✅
- string_methods_test.zbr ✅

**Current Workaround:**
Use `.concat()` method instead:
```zebra
# Instead of:
return "Hello, " + name + "!"

# Use:
return "Hello, ".concat(name).concat("!")
```

**Still Needs Fixing:**
No remaining occurrences in expanded tests (all fixed above).

**Note for Compiler:** If `+` operator support for strings is planned, that would improve test readability. Current tests use `.concat()` consistently.

---

## Test Files Status

### ✅ Successfully Compiling Tests

1. **nil_tracking_test.zbr**
   - Status: COMPILES & RUNS ✅
   - Output: Correct (Alice, got nil, hello, 42)
   - Pattern: Inline code in main()

### ⚠️ Tests Blocked by Issue #1 (Code Generation Bug)

**Need Compiler Fix OR Test Refactoring:**

| File | Lines | Issue | Fix Required |
|------|-------|-------|--------------|
| greet.zbr | 32 | self.testGreeter() | Refactor helpers inline |
| string_index_test.zbr | 45 | self.testCharIndexing() | Refactor helpers inline |
| capture_boundary.zbr | 40 | self.testSimpleCapture() | Refactor helpers inline |
| crossmod_infer_test.zbr | 25 | self.testTypeInference() | Refactor helpers inline |
| dispatch_diag.zbr | 35 | self.testDispatch() | Refactor helpers inline |
| with_test.zbr | 40 | self.testPointWithBlock() | Refactor helpers inline |
| gui_test.zbr | 45 | self.counterFrame() | Refactor helpers inline |
| raise_auto.zbr | 28 | self.testValidInput() | Refactor helpers inline |
| server_test.zbr | 22 | self.createHandler() | Refactor helpers inline |
| file_io_test.zbr | 38 | self.testBasicWriteRead() | Refactor helpers inline |
| string_methods.zbr | 45 | self.testCaseMethods() | Refactor helpers inline |
| use_test.zbr | 25 | self.testDoubleAndSquare() | Refactor helpers inline |
| transitive_test.zbr | 25 | self.testMathUtils() | Refactor helpers inline |
| crossmod_arith_test.zbr | 22 | self.testBasicArithmetic() | Refactor helpers inline |
| interp_test.zbr | 28 | self.testBasicInterpolation() | Refactor helpers inline |
| throws_raise.zbr | 28 | self.testValidInput() | Refactor helpers inline |
| tcp_test.zbr | 30 | self.testBasicTcpConnect() | Refactor helpers inline |
| list_direct_iter.zbr | 35 | self.testDirectIteration() | Refactor helpers inline |
| list_iter.zbr | 30 | self.testItemsProperty() | Refactor helpers inline |
| shared_field.zbr | 35 | self.testSharedField() | Refactor helpers inline |
| udp_test.zbr | 30 | self.testBasicUdp() | Refactor helpers inline |
| http_test.zbr | 35 | self.testHttpGet() | Refactor helpers inline |
| hashmap_iter.zbr | 30 | self.testBasicIteration() | Refactor helpers inline |

**Total Affected:** ~23 files

---

## Recommended Resolution Path

### For Sonnet (Immediate Actions):

**Option A: Quick Fix (Refactor Tests) — 30-60 minutes**
1. For each affected file, move test logic from helper methods into main()
2. Keep test sections separated by comments (e.g., `# ── Test: Basic Iteration ──`)
3. Maintains test coverage, unblocks compilation
4. All files will then compile and run

**Option B: Fix Root Cause (Compiler) — 2-4 hours**
1. Locate shared method call code generation in CodeGen/ZigGenerator
2. Fix: don't emit `self.` prefix for shared→shared method calls
3. Recompile compiler and test suite
4. All ~23 files should then compile correctly
5. More elegant, enables better test organization patterns going forward

**Recommended:** Do **Option A first** to unblock immediate testing, then tackle **Option B** as compiler improvement for future test suites.

---

## Test Organization Notes

### Helper Method Pattern (Currently Broken)
```zebra
class Main
    shared
        def testHelper1
            # setup and assertions
        
        def testHelper2
            # setup and assertions
        
        def main
            testHelper1()  # ← FAILS: generates self.testHelper1()
            testHelper2()  # ← FAILS: generates self.testHelper2()
```

### Inline Pattern (Currently Works)
```zebra
class Main
    shared
        def main
            # ── Test: Helper 1 ──────────────────────────────────────
            # setup and assertions
            
            # ── Test: Helper 2 ──────────────────────────────────────
            # setup and assertions
```

### Instance Method Pattern (Unknown Status)
```zebra
class Main
    def testHelper
        # ...
    
    shared
        def main
            var m = Main()
            m.testHelper()  # Would this work? Unknown
```

---

## Test Files Successfully Expanded

**Task #1–#9 Completed:** 10 comprehensive expansions  
**Total New Test Code:** ~500+ lines  
**Files Expanded:** 36+ files from 4–50 lines to 15–130 lines

### By Category:

**String Operations (Tasks #1–#5):**
- ✅ string_methods_test.zbr: 52→130 lines
- ✅ string_format_test.zbr: 30→85 lines
- ✅ regex_test.zbr: 44→120 lines
- ✅ unicode_test.zbr: 34→95 lines
- ✅ string_builder_test.zbr: 36→105 lines

**Collections & Iteration (Tasks #6–#8):**
- ✅ list_iter.zbr: 9→30 lines
- ✅ hashmap_iter.zbr: 10→30 lines
- ✅ sort_test.zbr: 55→130 lines

**Error Handling (Task #9):**
- ✅ result_test.zbr: 42→125 lines

**Stub Expansions (Task #14):**
- ✅ 26+ tests expanded from <15 lines to 15–40 lines

---

## String Concatenation — Current Status

**All tests updated to use `.concat()` method**

Files patched:
- greet.zbr
- dns_test.zbr
- result_test.zbr
- sort_test.zbr
- sys_test.zbr
- string_methods_test.zbr

No remaining `"string" + variable` syntax in expanded tests.

---

## Next Steps for Sonnet

1. **Review this file** and choose resolution path (Option A or B)
2. **If Option A:** Refactor ~23 test files to inline pattern
3. **If Option B:** Debug and fix shared method call code generation
4. **Test:** Run refactored/fixed tests with compiler
5. **Verify:** All 36+ expanded tests compile and produce correct output
6. **Consider:** Tasks #10–#22 (remaining test expansion work)

---

## File Locations

- **Expanded tests:** `/c/Projects/cobra-language/zig-compiler/test/*.zbr`
- **Generated Zig code:** `/c/Projects/cobra-language/zig-compiler/test/*.zig`
- **Compiler sources:** `/c/Projects/cobra-language/zig-compiler/src/`
- **Build file:** `/c/Projects/cobra-language/zig-compiler/build.zig`

---

## Compiler Binaries

**Recent successful builds:**
- `zebra.exe` (latest): `.zig-cache/o/0430e87b626a6c93e5919b554ef7fe54/zebra.exe`
- `bench_zebra.exe`: `zig-compiler/bench_zebra.exe` (works)
- `server_test.exe`: `zig-compiler/server_test.exe` (works)

---

## Additional Notes

- **Memory Allocator:** Tests use GPA (GeneralPurposeAllocator) from generated Zig
- **Error Context:** Threadlocal error context defined in generated code
- **GUI Backend:** Stub backend implemented, ready for Dear ImGui integration
- **String Type:** Both `str` and `String` are used; compiler treats them consistently

---

**Last Updated:** 2026-04-07 by Haiku  
**For:** Sonnet session (zig_backend branch)  
**Status:** Ready for action
