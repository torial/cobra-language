# Zebra Self-Hosting Journal

The goal: write the Zebra compiler in Zebra. This file records qualitative observations
as each compiler phase is ported — **before/after** comparisons between the Zig implementation
and the Zebra implementation of the same logic.

Each phase uses the same question template. Fill it in before moving to the next phase.

---

## Template (copy for each phase)

```
## Phase: <name> (<file>.zbr)
**Completed:** <date>
**Lines of Zebra / Lines of Zig (approximate):**

### Where Zebra felt better than Zig
<!-- specific moments, not generalizations -->

### Where Zebra felt worse or missing
<!-- specific friction points -->

### Did `branch` / union dispatch do its job?
<!-- how did pattern matching on AST nodes feel? -->

### Error propagation (`?` / Result) — did it read naturally?
<!-- was it Go-like (tedious), Rust-like (clean), or something else? -->

### Allocator model — did it get in the way?
<!-- was implicit arena scoping missed? where did explicit alloc hurt? -->

### Missing language features discovered
<!-- things you wanted but didn't have -->

### Surprise wins
<!-- things that worked better than expected -->

### Net verdict: easier or harder than the Zig version?
```

---

## Phases

Planned port order (roughly mirrors the Zig source structure):

1. **Token + Lexer** (`token.zbr`, `lexer.zbr`) — character iteration, keyword detection, string interning
2. **AST types** (`ast.zbr`) — recursive union types, `^T` for self-referential nodes
3. **Grammar / Parser** (`parser.zbr`) — Earley or recursive descent; tree building
4. **Resolver / Binder** (`resolver.zbr`) — scope tree, symbol table, mutable pass
5. **Type Checker** (`typechecker.zbr`) — type inference, substitution, the interior mutability problem
6. **Code Generator** (`codegen.zbr`) — StringBuilder, pattern matching on AST, emit loop
7. **Main / CLI** (`main.zbr`) — argument parsing, file I/O, subprocess invocation, error remapping

---

## Phase 1: Token + Lexer (`Token.zbr`, `Lexer.zbr`)
**Completed:** 2026-04-10
**Lines of Zebra / Lines of Zig (approximate):** 1157 Zebra (Token 382 + Lexer 775) vs ~891 Zig (Tokenizer.zig alone, no token enum file)

### Where Zebra felt better than Zig

**Union dispatch for LineKind.** `branch` on a local union type read exactly like the intent. No need to think about tagged union struct syntax or switch exhaustion — just `branch kind on empty: ...`, `on has_content: ...`. The dispatch felt declarative, not mechanical.

**Cross-module use syntax.** `use Token` followed by `Token.TokenKind.eol()` reads like natural English. The module-qualified dotted path is explicit without being verbose. Compare to Zig where you'd write `Token.TokenKind{ .eol = {} }` and have to know the struct literal syntax.

**`throws` / `?` propagation.** `lex.run()?` inside `tokenize` reads like "run and propagate any error." The try/catch in the test file matched how I'd think about it. No `try` keyword clutter in the middle of expressions.

**No allocator threading.** Writing `List(Token.Token)` and just doing `out.append(tok)` without passing an allocator at every step reduced the cognitive noise by ~30%. The arena-implicit model shone here: the lexer allocates freely, the caller owns the result.

### Where Zebra felt worse or missing

**Cross-module type qualification is verbose.** `Token.TokenKind`, `Token.Token`, `Token.Keywords` — every single cross-module type reference needs the module prefix. In a 775-line lexer that's 50+ occurrences. Felt like writing Go import prefixes everywhere. A future `use Token exposing *` or selective import would help.

**`List(Token.Token)` element type not inferrable from context.** When writing `out = List()` in `cue init`, Zebra can't infer the element type from the field's declared type. Had to rely on the compiler's `resolveListElemType` heuristic — which had to be extended to handle cross-module types. From the user's perspective this was invisible, but it was the hardest compiler bug to fix.

**No `char` pattern matching in `branch`.** The lexer's inner loop switches on characters extensively. In Zig this is `switch (c) { 'a'...'z' => ... }`. In Zebra we used `if/else if` chains with `isAlpha(c)` helpers, which works but is less data-structured. A `branch c on 'a'..'z': ...` form would be natural.

**No `while let` / `for var`.** Several patterns like "advance while peek is whitespace" required manual index loops. Zebra's `for item in collection` is clean for collections but there's no "while condition is true, bind something" form.

### Did `branch` / union dispatch do its job?

Yes, for the `LineKind` union. The `branch` on an optional (`Token.TokenKind?`) in `Keywords.lookup` was slightly awkward — had to return `nil` explicitly at the bottom. Rust's `match` on `Option<T>` with a `None` arm feels more exhaustive. But the positive cases were clean.

### Error propagation (`?` / Result) — did it read naturally?

Very naturally. `lex.run()?` in `tokenize` — one character to propagate. The test file's `try ... catch |e|` block mapped directly to mental model: "try this block of work, catch errors with name `e`." No noise.

The harder part was that the compiler had to learn that `var toks = Lexer.tokenize(src)` inside a `try` block needed a `catch` redirect for the error union — this isn't obvious from the Zebra syntax alone, it requires the compiler to know `tokenize` throws.

### Allocator model — did it get in the way?

Almost never. The implicit arena felt right for a lexer: emit tokens freely, return the list, caller owns it. The only friction: `defer list.deinit(_allocator)` in the test file — Zebra-level callers still see the allocation lifecycle. A future ownership annotation on the return type (e.g. `List(Token) owned`) could make this invisible too.

### Missing language features discovered

1. **Selective imports** (`use Token exposing TokenKind, Token`) — avoid the module prefix repetition. _Implemented 2026-04-10: `use Mod exposing A, B` registers each exposed name in scope; CodeGen emits `const A = Mod.A;` aliases and tracks exposed unions/classes for correct construction._
2. **Character range patterns** in `branch` — `on 'a'..'z':`. _Implemented 2026-04-10: `on c'a'..c'z'` parses as a `dotdot` binary expr; CodeGen detects it in `genBranch` and emits Zig's `'a'...'z'` inclusive range syntax._
3. **First-class function references** — `var f = isAlpha`, `f(c'x')`, `pred = isDigit` reassignment. _Implemented 2026-04-10: TC returns `fn_ref(sym)` for bare function names; `isAssignable` treats all fn_refs as compatible; mutable fn-ref vars emit `var f: @TypeOf(&func) = &func;`; fn-ref reassignment emits `f = &newFunc;`._
4. **Inferred generic type args from LHS annotation** — `out = List()` (or any `T()`) should infer its type argument from the declared field/variable type. Applies to all generics: `List(T)`, `HashMap(K,V)`, user-defined `Stack(T)`. _Implemented 2026-04-10: `genAssign` now uses `resolveFieldGenericTypeRef` to look up the field's declared generic TypeRef for any zero-arg constructor call._
5. **`while var c = expr, guard` bind-and-guard loop** — natural for "advance while peek is X, collecting chars": `while var c = self.peek(), isAlpha(c) { ... }`. Binds `c` each iteration; exits when guard is false. _Implemented 2026-04-10: new grammar production, AST `WhileBind` field, emitted as `while (true) { const c = expr; if (!guard) break; body }`._
6. **`str.spanWhile(pos, pred)` / find-advancing method** — the lexer has a recurring pattern: advance `pos` while a character predicate holds, then return the new position. Writing this as a method call (`pos = src.spanWhile(pos, isAlpha)`) would remove dozens of identical 3-line while loops. Needs first-class function values or method references as arguments — now available via fn-ref (#3).

### Surprise wins

**`cue init` zero-setup.** Writing the initializer as an indent-block without return or type annotation felt very clean. No struct literal boilerplate.

**`shared def tokenize` as a static method.** `Lexer.tokenize(src)` at the call site is exactly what you'd write in pseudo-code. The `shared` modifier cleanly expresses "class method, no instance needed."

**Zebra source = what you'd write in a design doc.** Looking at `Lexer.zbr`, a programmer unfamiliar with Zebra could read most of it as English-ish pseudocode and understand the algorithm.

### Net verdict: easier or harder than the Zig version?

**Easier in algorithm expression, harder in compiler infrastructure.** The Zebra lexer was enjoyable to write — the language got out of the way. The hard work was all in the compiler: making cross-module type qualification work, tracking `throws` across module boundaries, handling `List(CrossModuleType){}` initialization, and getting union variant construction right for `Token.TokenKind.eol()`. Phase 1 was as much a compiler stress-test as a language experience.

That's exactly what the self-hosting goal demands: the language should support the patterns the compiler needs, and the compiler should catch everything at the seams. Phase 1 found 8 distinct compiler bugs, all now fixed.

---

## Phase 2: AST Types (`ast.zbr`)
**Completed:** 2026-04-10
**Lines of Zebra / Lines of Zig (approximate):** ~700 Zebra vs ~900 Zig (Ast.zig)

### Where Zebra felt better than Zig

**Recursive union types with `^T` payload.** Writing `nilable as ^TypeRef` in the union declaration is a one-liner. In Zig, self-referential unions require `*TypeRef` fields with manual heap allocation at every construction site. In Zebra, the boxing is implied by the `^` sigil and the compiler handles the allocation expression automatically (labeled-block boxing). The intent — "this variant contains a heap-allocated TypeRef" — is expressed once and is invisible to callers.

**Union dispatch reads like natural case analysis.** `branch tr on TypeRef.named as nr2: ...` is exactly what you'd write in a design document. No exhaustion annotations, no `@as`, no struct literal syntax in the match arm.

**`cue init` single-line signatures.** For structs with many fields (Span, DeclVar, DeclMethod), the `cue init` line is the field list written once. No separate constructor function body, no boilerplate.

**`enum` is a first-class keyword.** `enum IntBase; decimal; hex` is two lines. In Zig you need a tagged union or a full `pub const IntBase = enum { decimal, hex };` block — more ceremony for the same semantics.

### Where Zebra felt worse or missing

**Keyword conflicts are a landmine.** At least 15 field names in the Zig AST are Zebra keywords: `body`, `init`, `pass`, `raise`, `guard`, `same`, `in`, `and`, `or`, `nil`, `any`, `all`, `namespace`, `class`, `interface`. Each required a manual rename (trailing underscore or alternate name). A `@"keyword"` escape hatch (like Zig's) would let the Zig field names survive verbatim.

**Single-line `cue init` constraint is fragile.** The tokenizer validates indentation on ALL lines, including continuation lines inside parentheses. Multi-column alignment (e.g., 13 spaces) fails with `SpaceIndentNotMultipleOfFour`. This forced every multi-parameter `cue init` onto one line — readable for 3-4 params, cramped for 7+. The right fix is: inside balanced parens, suppress indentation checking.

**No `throws` propagation through self-calls.** When a method is `throws`, calling another `throws` method on `self` requires explicit `try` in Zig. Zebra has no way to express this currently — the CodeGen doesn't know the callee's `throws` status, so it can't auto-emit `try`. This forced the test to avoid all allocation-requiring constructions (TypeRef.nilable, ExprBinary with ^Expr fields) in non-throws methods. Resolution: the CodeGen needs to emit `try` automatically when calling a `throws` method from a `throws` context — or `?` postfix should work on self-method calls.

**`^T` payload in structs (not unions).** Struct fields typed as `^T` (e.g., `DeclVar.init_expr as ^Expr?`) don't auto-box on assignment. The caller must already hold a pointer. This is correct — you don't want invisible allocations in struct construction — but it means the type definition (^T field) and the usage pattern (caller must box first) are not symmetric. A small language-level clarification would help.

### Did `branch` / union dispatch do its job?

Yes, but with a CodeGen bug discovered: `on SomeUnion.variant() as x` (call-expression form in the on-clause) was emitting wrong Zig (`SomeUnion{ .variant = {} }` instead of `.variant`). Fixed by detecting call expressions in `genBranch` and extracting the member name. Similarly, `on PlainEnum.member` (no parens) now correctly emits `.member` rather than calling `genExpr` on the full cross-module member chain. Both fixes are in CodeGen.zig.

### Error propagation (`?` / Result) — did it read naturally?

The limitation became visible: you can't `try` a constructor expression (e.g., `ast.TypeRef.nilable(inner)`) inside a non-throws method. The `?` postfix is defined for identifiers that are optional or error unions, but the TypeChecker doesn't yet resolve method return types well enough to propagate `throws` transitively through self-calls. In Phase 3 (Parser), this will be a significant pain point since the parser will throw on every input.

### Allocator model — did it get in the way?

Yes, for `^T` union variants. The implicit arena allocates correctly, but the test couldn't call union constructors with `^T` payloads from a non-throws context. The Phase 1 model (allocate freely, caller owns) works for collections; for recursive unions it surfaces as "this constructor now throws." The language needs either: (a) automatic throws-propagation so callers don't have to mark `throws` explicitly, or (b) a `catch unreachable` mode for OOM (acceptable in tests, not in production code).

### Missing language features discovered

1. **`throws` auto-propagation** — when calling a `throws` method from a `throws` method, auto-insert `try`. This is how Swift's error propagation works and how Zebra users will expect it to work.
2. **Keyword escape hatch** — `@"body"`, `@"init"`, `@"class"` for field names that are Zebra keywords. Without this, every Zig type definition requires manual renaming.
3. **Indentation suppression inside balanced parens** — the tokenizer should not check indentation inside `(...)` blocks. This unblocks multi-line `cue init` signatures with natural column alignment.

### Surprise wins

**`^T` union payload boxing "just worked" for the TypeRef.named variant.** The same-module boxing path (same-file union with `^T` payload) and the cross-module path (imported union via `boxed_variants` in ModuleInterface) both produced correct Zig without any manual intervention. The labeled-block expression (`box: { const _p = try _alloc.create(T); ... }`) is invisible to the Zebra user.

**The ast.zbr file is readable as a type specification.** A programmer reading `ast.zbr` would understand the AST structure without knowing Zebra: the union/struct/enum hierarchy mirrors what you'd draw in a design diagram. This was the motivating goal for Phase 2 and it succeeded.

### Net verdict: easier or harder than the Zig version?

**Easier for type declarations, harder for recursive types with allocation.** Structs and plain enums were faster to write in Zebra than Zig — less ceremony. The recursive `TypeRef` union and the `Decl` union (with `^DeclXxx` heap-boxing) required the most thought: understanding which field names are keywords, how `^T` boxing works, and which constructors require the caller to be `throws`. Phase 2 surfaced 3 new compiler bugs (branch/on call-expr pattern, struct `cue init` type-tag stamping, `boxed_variants` clone in `cloneInterface`) and identified 3 missing language features.

---

## Phase 3: Grammar / Parser (`parser.zbr`)
**Completed:** 2026-04-11
**Lines of Zebra / Lines of Zig (approximate):** ~910 Zebra vs ~2900 Zig (Parser.zig generated)

### Where Zebra felt better than Zig

**Recursive descent reads like the grammar.** `parseAddSub` calls `parseMulDiv`, loops on `+`/`-`, and wraps the result in `PNode.expr_binary`. In Zig the same logic is identical in structure, but the types are noisier: `*const [N:0]u8` for string literals, explicit `try` on every allocation, `anyerror!PNode` signatures. Zebra's signal-to-noise ratio was noticeably better for grammar rules.

**`throws` propagation across self-calls.** Every parsing method is `throws`. In Zebra, `const decl = .parseDecl()` automatically propagates the error union without a `try` prefix — the compiler knows `.parseDecl()` throws because it's a self-method call and resolves it via the method table. In Zig this would be `const decl = try self.parseDecl()`. Over ~40 methods and hundreds of call sites, the reduction in noise is real.

**`branch` on `PNode` is the test harness.** The parser test (`parser_test.zbr`) is essentially a series of nested `branch` statements dispatching on the result tree. This is exactly what recursive AST traversal looks like — and it reads as clearly as the grammar itself. Writing the tests confirmed that the language handles deep union dispatch well.

**`List(PNode)` as a first-class value.** Building a list, passing it into a struct, returning it — all without allocator plumbing at each step. The `var stmts as List(PNode)` → `stmts.add(s)` → `PMethod(name, stmts, ...)` pattern is the heart of every parsing method and it was frictionless.

### Where Zebra felt worse or missing

**`var l as List(PNode)` without init is a latent danger.** The pattern `var l as List(PNode)` (no init) initializes to an empty ArrayList, which is correct and necessary. But the similarity to `var x as int` (= undefined) is misleading. It would be clearer to require `var l = List(PNode)()` even for empty initialization, making the construction explicit.

**Struct constructor repetition.** `PMethod(name, params, ret_type, throws_, is_shared, stmts)` appears in one place (parseMethodDecl), but it still has 6 positional args. Named fields at construction time (`PMethod(name: name, stmts: stmts)`) would be safer and more readable. This is on the deferred features list.

**No way to write a `match` guard.** Several parser checks want `on PNode.expr_int if condition: ...`. Without guards, the `branch` must dispatch first, then `assert` inside the arm — two steps where one would do.

### Did `branch` / union dispatch do its job?

Emphatically yes. The test file is 267 lines of nested `branch` statements covering 10 distinct parser test cases, and the structure maps directly to the grammar. The hardest moment was confirming that `b.left.at(0)` returned the right variant — which was initially wrong due to a CodeGen bug (see below), not a `branch` semantics issue.

### Error propagation (`?` / Result) — did it read naturally?

Yes, with one notable pattern: the entire parser wraps each method call in `?` propagation via `.parseX()?` or just `.parseX()` (since all methods throw and the implicit `try` handles it). The test file's outer `try ... catch |e|` block is the only place errors surface to the user. Propagation through 40 layers of recursion is invisible.

### Allocator model — did it get in the way?

**Yes — and it exposed a compiler bug.** The most complex debugging in this project so far:

In `parseAddSub`, the pattern is:
```
var l as List(PNode)
l.add(left)
var r as List(PNode)
r.add(right)
left = PNode.expr_binary(PBinary(op, l, r))
```

`PBinary` copies `l` and `r` by value (sharing their `items.ptr`). The CodeGen emitted `defer l.deinit(_allocator)` for local List variables not detected as "returned." This called `Allocator.free` on `l`'s buffer — which **poisons the buffer with 0xAA bytes via `@memset`** before calling `rawFree`. Since `_p.left.items.ptr` still pointed to the same buffer, `b.left.items[0]` read garbage (appearing as `stmt_return` due to the 0xAA tag byte pattern).

**Root cause chain:** CodeGen's `analyzeEscapes` detects lists that appear directly in `return` expressions. It does NOT detect the pattern "list is passed into a struct constructor which is then assigned to another variable which is then returned." So `l` was not marked escaped, `defer l.deinit` was emitted, `Allocator.free` poisoned the shared buffer.

**Fix:** Remove ALL `defer l.deinit(_allocator)` emissions from `genLocalVar`. Since all Zebra programs use an arena allocator, individual deinit calls are both unnecessary (the arena frees at program exit) and harmful (buffer poisoning via `Allocator.free`'s `@memset`). This is the correct model: in an arena-only program, you never call `deinit` on individual collections.

**Lesson:** The arena model is sound, but the CodeGen must not emit individual deinit calls even as "cleanup." Any call to `Allocator.free` on arena memory is a semantic error waiting to happen.

### Missing language features discovered

1. **Named struct construction** — `PMethod(name: nm, stmts: stmts)` instead of positional. Already on the deferred list.
2. **`branch` guards** — `on Variant.x if condition:` to avoid two-step dispatch + assert.
3. **`var l = List(PNode)()` required for empty init** — make the empty-collection case explicit rather than type-annotation-only.

### Surprise wins

**The parser is shorter than the Zig version by a factor of 3.** ~910 Zebra lines produces ~2900 lines of generated Zig. Most of the expansion is allocator threading, `try` keywords, and verbose type annotations. The Zebra version contains essentially no boilerplate — just the grammar.

**`use Parser exposing PNode` is clean.** The test file imports `PNode` directly into scope: `branch decls.at(0) on PNode.class_ as c`. No module-prefix clutter in the 267-line test. The `exposing` feature from Phase 1 pays dividends here.

**9/9 tests passed on first clean run** (after the CodeGen bug fix). Once the `defer deinit` removal was applied, every parser test passed without further changes. The parser itself was correct — the only failure was a CodeGen artifact.

### Net verdict: easier or harder than the Zig version?

**Noticeably easier.** The grammar itself wrote cleanly in ~60% of the lines. The test harness was pleasant — nested `branch` dispatches are readable and exhaustive. The only hard part was the CodeGen bug hunt (took the majority of the phase's wall-clock time), which was invisible in the Zig version because Zig programmers would never emit a `defer deinit` on a buffer they'd already passed to a struct. Phase 3 surfaced 1 major compiler bug (arena + Allocator.free poisoning) and 3 minor missing features. Compiler bug count across all phases: Phase 1 = 8, Phase 2 = 3, Phase 3 = 1.

**Post-phase cleanup:** After passing all 9 tests, the `eff_kw` override block in `genLocalVar` was removed. That block forced `var` for any List/HashMap local that wasn't borrowed or returned, under the assumption that `deinit(*Self)` would be called. Since `deinit` is never emitted now, `scanMutations` handles `var`/`const` correctly on its own (it detects `l.add()` as a mutating call). The `analyzeEscapes` docstrings were also updated to clarify that the function is now string-only (suppressing `defer _allocator.free` for returned string slices).

---

## Phase 4: Resolver / Binder (`resolver.zbr`)
**Completed:** 2026-04-11
**Lines of Zebra / Lines of Zig (approximate):** ~283 Zebra vs ~1917 generated Zig

### Where Zebra felt better than Zig

**Flat scope-chain model was easy to reason about.** Three `HashMap(str, int)` fields — `module_scope`, `class_scope`, `method_scope` — replace a linked-list scope tree. In Zig this would require `*Scope` pointers and manual arena allocation; in Zebra the HashMaps are just fields with no lifecycle ceremony. Swapping scope levels is a single assignment (`this.class_scope = HashMap()`), visible at a glance.

**Primitive getter methods solved cross-module List inference cleanly.** The original plan used a `ResolveResult` struct with a `List(ResolveError)` field. Cross-module List field type inference doesn't work (TC returns `.unknown` for `List(T)` generics from imported modules). Replacing the result struct with `errorCount() as int`, `firstError() as str`, `symbolCount() as int` getter methods made the test file completely portable — all return types are primitives the TC can handle.

**`branch` on `PNode` inside resolver methods reads as directly as the grammar.** `branch stmt on PNode.stmt_var as v: resolveExpr(v.init_expr); method_scope.put(v.name, 4)` is the intent expressed with no noise. The two-pass structure (bind then resolve) maps onto two methods, each a `branch` on the module tree.

**3-line test structure per test case.** Each test is: parse → resolve → assert. The assertions use `r.errorCount()`, `r.symbolCount()`, `r.firstError()` — plain integers and strings that compose naturally in boolean expressions.

### Where Zebra felt worse or missing

**`for decl in m.decls` over a branch-binding field didn't work.** When `m` is bound by `on PNode.module_ as m`, `m`'s TC type is `.unknown` (branch bindings of cross-module union payloads can't be typed through the TypeChecker's symbol table). `genForIn` couldn't determine that `m.decls` is a `List(PNode)` and generated `for (m.decls) |decl|` without `.items`. Required a CodeGen fix: when the iter is a `.member` access and no type can be determined, fall back to `genForInList` — safe because in Zebra, iterating a struct field must be a `List(T)`.

**`this.field.method()` dispatch broken.** `getExprDeclaredType` handled `ident.field` (local var) and class-ident.field patterns, but NOT `this.field`. Since `this` is its own expression type (not an ident), the field type of `this.errors`, `this.method_scope`, etc. was always `.unknown`. This caused `this.method_scope.contains(name)` to dispatch through the List `contains` path (`std.mem.indexOfScalar`) instead of the HashMap path (`.contains(k)`). Required extending `getExprDeclaredType` to handle `this.field` by looking up `g.owner_members`.

**Transitive allocator initialization wasn't automatic.** `resolver_test.zbr` imports `Parser` and `Resolver` directly. `Lexer` and `Token` are transitive deps (imported by Parser). The generated `main()` only called `_initAllocator` for direct imports, leaving `Lexer._allocator` uninitialized → segfault on first `out.append()`. Required a CodeGen fix: `_initAllocator` now propagates to all of the module's own imports, so transitive init is automatic.

**No way to call `m.name` when `m` is `^PModule`.** The `^T` auto-deref works for field access inside `branch on ... as m` arms, but only for the generated field access (`m.decls`). For method calls on a `^T` binding the TC type is still `.unknown`. This is a known limitation; workaround is to extract fields into locals before passing to helpers.

### Did `branch` / union dispatch do its job?

Yes. The `resolveStmt` and `resolveExpr` methods are pure `branch` dispatch tables — one arm per statement/expression kind. Reading the code, you can see the entire Zebra grammar reflected. The `else => pass` catch-all made it safe to add new variants without breaking existing dispatch. The two-pass design (bind first, then resolve) required no special branch machinery — just separate methods called on the same tree.

### Error propagation (`?` / Result) — did it read naturally?

Yes. `r.resolve(root)?` in each test propagates errors from the resolver walk. The resolver itself uses `?` on all self-method calls transparently. The `?` on `Parser.Parser.parse(src)?` in var-init position was the only non-obvious moment — without `?`, the return type would be `anyerror!PNode` rather than `PNode`, causing a type mismatch for `root`.

### Allocator model — did it get in the way?

Less than Phase 3. HashMaps and Lists are constructed freely, no allocator threading. The `HashMap()` constructor (without type args) works correctly because the field declaration provides the key/value types. The only edge: `HashMap.put` returns `error{OutOfMemory}!void` in Zig, requiring `try`. CodeGen emits `catch unreachable` (not `try`) since OOM in an arena is fatal anyway — once `getExprDeclaredType` resolved `this.module_scope` as `HashMap(str, int)`, the correct dispatch path fired.

### Missing language features discovered

1. **Branch-binding type propagation** — when `on UnionType.variant as x`, the TC should push `x`'s type into `narrowed_types` even for cross-module union types (currently only works for same-module `.named` types). Would fix `for decl in m.decls` and all member-access-on-branch-binding patterns at the language level rather than as a CodeGen heuristic.
2. **`for x in container.field` where container is a branch binding** — sub-case of #1. The CodeGen workaround (fall back to `.items` for `.member` iter) is pragmatic but not principled.
3. **Transitive import initialization** — now fixed in CodeGen (`_initAllocator` propagates), but this should arguably be a language guarantee: "importing a module initializes it fully, including its dependencies."

### Surprise wins

**`3:1 Zebra-to-Zig compression** holds.** ~283 Zebra lines → ~1917 generated Zig. Same ratio as Phase 3. The Zig expansion is entirely allocator threading, `try` keywords, and verbose type annotations — the algorithm itself is identical.

**Zero logic bugs after the CodeGen fixes.** Once the 4 CodeGen issues (for-in member fallback, `this.field` declared-type lookup, transitive allocator init, `.items.len` cast) were resolved, all 10 resolver tests passed on the first clean run. The resolver logic itself was correct; the failures were all language-infrastructure issues.

**`.items.len` → `@as(i64, @intCast(...))` fix benefited all three emit paths.** The `usize` → `i64` cast was missing in `genStdlibProp`, the `generic_named` TC fallback, AND the last-resort `.len` path. Fixing all three means `list.len` now works correctly in return statements, arithmetic, and comparisons without any special-casing at the call site.

### Net verdict: easier or harder than the Zig version?

**Easier for the algorithm, harder than Phase 3 for infrastructure.** The resolver logic (two-pass, flat scope chain, `branch` dispatch) was pleasant to write. The friction was entirely CodeGen: three separate bugs around `this.field` type resolution, cross-module struct field iteration, and transitive initialization. All three are now fixed and will benefit Phase 5+. Phase 4 surfaced 4 new CodeGen bugs; compiler bug count across all phases: Phase 1 = 8, Phase 2 = 3, Phase 3 = 1, Phase 4 = 4, **total = 16**.

---

## Phase 5: Type Checker — Plan

**Status:** Not yet started (probe validated 2026-04-11).
**Target files (in dependency order):**

| File | Role | Key patterns |
|---|---|---|
| `tc_types.zbr` | `TcType` union + `TcTypes` helpers | All union variant kinds; `^T`, `List(T)`, struct payload; recursive `describe`/`eql` |
| `tc_scope.zbr` | `TcScope` class + `ScopeKind` enum | HashMap(str, TcSymbol); scope chain; `define`/`lookup`/`contains` |
| `tc_stdlib.zbr` | `TcStdlib` registry | Registry pattern: `HashMap(str, StdlibEntry)`; dispatch by method name; returns expected arg/return types |
| `tc_infer.zbr` | `TcInfer` — expression inference | `inferExpr(e as PNode) as TcType throws`; mutual recursion with `tc_check` |
| `tc_check.zbr` | `TcCheck` — statement checking | `checkStmt(s as PNode) throws`; calls `tc_infer`; populates `expr_types` |
| `typechecker.zbr` | `TypeChecker` — public entry point | Ties together all modules; entry: `check(root as PNode) as TcResult throws` |

### File naming convention

All TypeChecker source files use the `tc_` prefix. This is a **namespacing convention**, not a Zebra language feature — Zebra has no package system yet, so the prefix prevents name collisions with future compiler phases that may define their own `Types`, `Scope`, `Infer`, etc.

Conventions:
- `tc_*.zbr` — TypeChecker implementation files
- Class names keep the `Tc` prefix: `TcType`, `TcScope`, `TcInfer`, `TcCheck`
- The public entry class (`TypeChecker` in `typechecker.zbr`) drops the prefix since it's the only exported name

The same convention will apply when other large compiler phases are split:
- `cg_*.zbr` / `CgXxx` for Code Generator
- `pr_*.zbr` / `PrXxx` for Parser (if re-split later)

### `TcType` union design

The `TcType` union in `tc_types.zbr` mirrors the probe5 `Type` union with renamed variants to match the Zig `TypeChecker.Type` exactly:

```
union TcType
    unknown
    int_   float_   bool_   char_   str_   void_   uint_
    int_n  as int       # sized: int32, int64, etc.
    uint_n as int
    optional    as ^TcType
    error_union as ^TcType
    list_        as ^TcType
    named        as TcNamedRef   # name + kind (class/struct/union/enum/interface)
    tuple        as List(TcType)
    fn_ref       as TcFnRef      # function references (first-class fn values)
    cross_module as TcCrossRef   # two-string: module alias + type name
    string_builder  http_response  regex  gui_context   # opaque stdlib types
```

The `TcNamedRef` struct carries the symbol name and `SymbolKind` enum so union equality (`std.meta.eql`) can distinguish `class Foo` from `union Foo`.

### `TcStdlib` registry pattern

Rather than a long if-else chain, `tc_stdlib.zbr` uses a `HashMap(str, StdlibEntry)` populated in `cue init`. Each entry declares the expected argument types and return type for a stdlib method call. `TcInfer` delegates to `TcStdlib.lookup(method_name)` and returns the entry's declared return type.

This pattern is more maintainable than a switch: adding a new stdlib method is one `map.put(...)` call, and the map can be inspected / iterated for completeness checks later.

### Boxing: `catch @panic("OOM")` instead of `try`

All `^T` union variant construction uses `_allocator.create(T) catch @panic("OOM")` rather than `try _allocator.create(T)`. This means:

- **Constructors for `^T`-payload variants do NOT force their callers to be `throws`.** A plain `def describe(t as TcType) as str` can create `TcType.optional(inner)` without marking itself as `throws`.
- **Rationale:** The program uses an arena allocator. Arena allocators never return OOM in practice — they call `@panic` internally if the OS refuses `mmap`. Using `catch @panic("OOM")` makes this explicit: OOM is a fatal programming error, not a recoverable condition. `try` would force error unions through every constructor call site for a failure that cannot meaningfully be handled.

This is the correct model for any program using a Zig `std.heap.ArenaAllocator`.

### Multi-file selfhost: cross-module `^T` boxing confirmed

`tc_smoke_main.zbr` (uses `use tc_smoke_types exposing TcType, TcTypes`) passes with the `catch @panic("OOM")` fix. The cross-module boxing path (via `exposed_unions` → module alias → `iface.boxed_variants`) generates correct Zig. Phase 5 can use `use` with `exposing` freely across all 6 files.

### Bugs fixed in Phase 5 prep (probe5 — 5 additional bugs, total now 21)

1. **`^T` branch-binding auto-deref** — `on Type.optional as inner` gives `*Type` from Zig switch; now generates `|inner_ptr| { const inner = inner_ptr.*; }` to auto-deref.
2. **`List(T)` branch-binding loop tracking** — `on Type.tuple as elems` where `elems: List(Type)`; `for e in elems` now routes to `genForInList` (`.items` iteration) via `list_loop_vars` injection in `genBranch`.
3. **`resolveFieldTypeRef` struct fix** — `withStruct` never set `owner_class`, so `^T` field boxing in `genAssign` silently skipped struct fields. Now falls back to `owner_members`.
4. **Union `==` / `!=` via `std.meta.eql`** — Zig forbids `==` on tagged unions with payloads. When LHS TC type is a named union (`sym.kind == .union_`), generates `std.meta.eql(a, b)`.
5. **`^T` struct field read auto-deref** — Accessing `pair.left` where `left: ^Expr` gives `*Expr` in Zig but `Expr` in Zebra. In `genExpr(.member)`, appends `.*` when field TypeRef is `ref_to`.

---

## Phase 5: Type Checker — Completed 2026-04-11

**Status:** All 6 files written; all tests pass.
**Lines of Zebra:** 1272 total (tc_types: 395, tc_scope: 150, tc_stdlib: 274, tc_infer: 215, tc_check: 141, typechecker: 97)
**Tests:** tc_types_test, tc_scope_test, tc_stdlib_test, tc_infer_test, tc_check_test, typechecker_test — all OK.

### Bugs fixed during Phase 5 (6 additional bugs, total now 27)

1. **`cue init()` requires parens for classes** — `cue init` (no parens) is valid for structs only; class constructors need `cue init()`. Error was `syntax error near 'init'`.
2. **`list.remove(i)` usize cast** — CodeGen.zig emitted `orderedRemove(i)` with `i64` arg; Zig requires `usize`. Fixed with `@as(usize, @intCast(...))`, matching the existing `at(i)` pattern.
3. **`==` on cross-module union via `TcTypes.eql`** — The `==` operator isn't defined cross-module on TcType (a union); must use `TcTypes.eql(a, b)` as in all local union comparisons.
4. **Multi-line `if` continuation indentation** — Continuation lines in `if` conditions must be at a multiple-of-4 indentation; misaligned `or` clauses at 23 spaces caused `SpaceIndentNotMultipleOfFour`.
5. **Cross-module `^T` branch-binding return type mismatch** — `on TcType.optional as inner_t` in tc_infer.zbr; the binding's symbol pointer differed from tc_types.zbr's `TcType` symbol pointer across module boundaries. Workaround: added `TcTypes.optionalInner(t)` in tc_types.zbr (same module as TcType).
6. **Cross-module `.named` vs `.cross_module` type mismatch in `isAssignable`** — A constructor call `TcScope()` on an exposed type yields `Type{ .cross_module = ... }` while a field declaration `var _scope as TcScope` resolves to `Type{ .named = exposed_sym }`. These are the same type in two representations; added bidirectional name-match compatibility to `Type.eql()` in TypeChecker.zig.

### Flat parallel-array scope stack

`tc_scope.zbr` avoids `List(HashMap(...))` (which has mutation-via-copy problems) by using three parallel arrays:
- `_names as List(str)` — symbol names in insertion order
- `_syms as List(TcSymbol)` — corresponding symbols
- `_limits as List(int)` — frame-start indices (frame N covers `_limits[N].._limits[N+1]-1`)
- `_kinds as List(TcScopeKind)` — frame kinds

`push(kind)` records the current `_names.count()` as the new frame boundary. `pop()` truncates both `_names` and `_syms` back to that boundary. Linear scan for lookup is fine for the small scopes used in type checking.

### Class copy semantics — scope setup must precede TcInfer construction

`var inf = TcInfer(sc)` copies `sc` at construction time (Zebra class copy semantics). Any `sc.push(...)` or `sc.define(...)` calls done AFTER that copy are invisible to `inf`. Restructured all tests to complete scope setup before constructing TcInfer.

### Cross-module class field assignment pattern

When a `TypeChecker` class holds a `TcScope` field (`_scope as TcScope`), the assignment `_scope = TcScope()` triggered a `.named` vs `.cross_module` type mismatch (bug #6 above). The cross-module name-match fix in `Type.eql()` resolved this for the self-hosting port.

---

## Post-Phase-5 Compiler Improvement: Classes as Reference Types (2026-04-11)

**Motivation from self-hosting:** The "class copy semantics" footgun — where `var inf = TcInfer(sc)` copies `sc` shallowly — revealed that Zebra classes should have reference semantics. Classes that hold other classes and need to call mutating methods after construction require interior mutability. Struct copy semantics are fine for plain data; class copy semantics are a footgun for objects.

**Change:** Classes are now heap-allocated reference types. `class` = pointer (`*T`, arena-allocated); `struct` = value type (unchanged). The arena means no deallocation; `_allocator.create(T)` is used in `init()`.

**Compiler changes (`b50c0c5f`):**
- `TypeKind` enum replaces `bool` in `ModuleInterface.types` — distinguishes `class`, `struct_`, `union_`, `enum_`
- `class_names` set in Generator — pre-populated from local decls and `genUse` cross-module imports
- `genType` emits `*ClassName` for all class types
- `genInit` returns `*ClassName`; body uses `_allocator.create(ClassName) catch @panic("OOM")`
- Synthetic `init()` likewise returns `*ClassName`
- `scanMutationsInExpr`: class method receivers no longer need `var` (pointer is already mutable)

**Effect on self-hosting:** The Phase 5 workaround (setup scope before construction) is now unnecessary. `var inf = TcInfer(sc)` copies the pointer; any subsequent `sc.push(...)` is visible through `inf._scope` because both hold the same pointer.

**All existing tests pass.** No observable change to existing Zebra programs; classes were already treated as pass-by-value objects whose mutation methods happened to use pointer receivers in the generated Zig.

When a class field has a cross-module class type (`var _scope as TcScope` in typechecker.zbr), assignment from a locally-constructed instance (`var s = TcScope()`) fails with a spurious type mismatch because the constructor returns `.cross_module` while the annotation resolves to `.named`. The fix (compiler bug #6 above) makes `eql` and `isAssignable` treat these as compatible. The local-variable intermediate was still needed to allow `s.push(...)` before `_scope = s`.
