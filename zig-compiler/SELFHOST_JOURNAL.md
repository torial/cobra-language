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
