# Cobra/Zig Compiler — Gap Analysis and Implementation Plan

## License Summary

### Cobra (this repo)
MIT license. Copyright 2003–2013 Cobra Language LLC. No restrictions on
reuse, modification, or relicensing. The new Zig compiler can be MIT.

### Libraries under consideration

| Library | License | Use? |
|---------|---------|------|
| `karlseguin/zul` | MIT | Yes — string building, pool allocators, utilities |
| `alexnask/interface.zig` | MIT | Possibly — vtable interfaces; verify Zig 0.15 compat first |
| `deckarep/ziglang-set` | MIT | Yes — Set(T) for binding phases |
| `cryptocode/zigfsm` | MIT | Yes — tokenizer state machine |
| `fusionlanguage/fut` | **GPL-3.0** | **No** — study only; cannot use code in MIT project |
| `C:\Projects\earley` | No LICENSE file yet | Add MIT before publishing |

**Action:** Add `LICENSE` (MIT) to the earley repo before it is used as a
dependency.

---

## What the New Compiler Must Do

The new Cobra compiler is a clean Zig reimplementation. It compiles `.cobra`
source files to `.zig` output, then invokes the Zig compiler. The existing
CLR compiler bootstraps the first version.

### Compiler phases (in order)

1. **Tokenize** — produce a flat token stream from source text
2. **Parse** — Earley parser over the token stream → CST
3. **Build AST** — lower CST to typed AST nodes
4. **Bind use** — resolve `use` directives to modules
5. **Bind inheritance** — resolve class/interface inheritance chains
6. **Bind interface** — resolve member signatures (types, parameters)
7. **Bind implementation** — resolve method bodies, expressions, type-check
8. **Identify main** — find program entry point
9. **Generate Zig** — walk AST, emit `.zig` source
10. **Invoke Zig** — shell out to `zig build-exe`

---

## AST Node Inventory

### Declarations (top-level and member)

| Cobra construct | Zig AST tag |
|----------------|------------|
| `class Foo` | `DeclClass` |
| `interface IFoo` | `DeclInterface` |
| `struct Foo` | `DeclStruct` |
| `mixin Foo` | `DeclMixin` |
| `enum Foo` | `DeclEnum` |
| `def foo(...)` | `DeclMethod` |
| `get foo` / `set foo` | `DeclProperty` |
| `var _x as T` | `DeclVar` |
| `cue init(...)` | `DeclInit` (constructor) |
| `class Foo<of T>` | `DeclGenericClass` |

### Types

| Cobra type | Internal representation |
|-----------|------------------------|
| `int`, `float`, `bool`, `char` | `PrimitiveType` enum |
| `String` | `StringType` |
| `T?` (nilable) | `NilableType { inner: TypeRef }` |
| `T*` (stream/generator) | `StreamType { inner: TypeRef }` |
| `List<of T>` | `ListType { elem: TypeRef }` |
| `Array<of T>` | `ArrayType { elem: TypeRef }` |
| `Dictionary<of K, V>` | `DictType { key, val: TypeRef }` |
| `Set<of T>` | `SetType { elem: TypeRef }` |
| user-defined class/struct | `NamedType { name: []const u8 }` |
| generic parameter | `GenericParam { name: []const u8 }` |
| `dynamic` | `DynamicType` |
| `void` | `VoidType` |

### Statements

| Statement | AST node |
|-----------|----------|
| `if ... else` | `StmtIf` |
| `while ...` | `StmtWhile` |
| `for x in ...` | `StmtForIn` |
| `for i in 0:n` | `StmtForNum` |
| `branch x on ...` | `StmtBranch` |
| `return expr` | `StmtReturn` |
| `raise expr` | `StmtRaise` |
| `try / catch / finally` | `StmtTry` |
| `assert expr` | `StmtAssert` |
| `print expr` | `StmtPrint` |
| `pass` | `StmtPass` |
| `break` / `continue` | `StmtBreak` / `StmtContinue` |
| `throw expr` | `StmtThrow` |
| `yield expr` | `StmtYield` |
| `using x = expr` | `StmtUsing` |
| `x = expr` (assignment) | `StmtAssign` |
| expression statement | `StmtExpr` |
| contract blocks (require/ensure/invariant) | `StmtContract` |

### Expressions

| Expression | AST node |
|-----------|---------|
| integer literal | `ExprIntLit` |
| float literal | `ExprFloatLit` |
| bool literal | `ExprBoolLit` |
| char literal | `ExprCharLit` |
| string literal | `ExprStringLit` |
| string interpolation `"[x]"` | `ExprStringInterp` |
| `nil` | `ExprNil` |
| `this` / `base` | `ExprThis` / `ExprBase` |
| identifier | `ExprIdent` |
| member access `.foo` | `ExprMember` |
| method call `foo(...)` | `ExprCall` |
| index `a[i]` | `ExprIndex` |
| slice `a[i:j]` | `ExprSlice` |
| binary op `a + b` | `ExprBinary` |
| unary op `not x`, `-x` | `ExprUnary` |
| `x to T` (cast) | `ExprCast` |
| `x to ?` (nilable coerce) | `ExprToNilable` |
| `x to !` (non-nil assert) | `ExprToNonNil` |
| `x?` / `x == nil` | `ExprIsNil` |
| `if(cond, t, f)` | `ExprIf` |
| lambda / anon method | `ExprLambda` |
| `List<of T>(...)` | `ExprListLit` |
| `{k: v, ...}` | `ExprDictLit` |
| `@[...]` | `ExprArrayLit` |
| `all` / `any` comprehension | `ExprAllAny` |
| `old expr` (contract) | `ExprOld` |

---

## Zig Infrastructure Needed

### Phase 1: Tokenizer

```
src/
  Token.zig        — Token tagged union: kind + source location
  Tokenizer.zig    — Hand-written scanner (zigfsm optional)
```

Key decisions:
- Tokens carry `file: []const u8`, `line: u32`, `col: u16`
- String interning for identifiers (arena + hash map)
- The tokenizer needs to handle indentation (Cobra is indentation-sensitive
  like Python — `end` keywords are implicit)

### Phase 2: Grammar + Parser

```
src/
  CobraGrammar.zig   — defineGrammar(Token, NT, .Program, &rules)
  Parser.zig         — thin wrapper: tokenize → parseResult → CST
```

Uses the earley library. The grammar file is the canonical language spec.
The CST (parse tree) is then lowered to the AST in phase 3.

### Phase 3: AST

```
src/
  Ast.zig           — all node types as tagged unions
  AstBuilder.zig    — CST → AST lowering pass
```

Key decision: AST nodes are arena-allocated. One `std.heap.ArenaAllocator`
per compilation unit, freed after code generation. No per-node `deinit`.

### Phase 4–7: Binding

```
src/
  SymbolTable.zig   — scoped symbol resolution (StringHashMap chains)
  TypeSystem.zig    — IType representation, built-in types
  Binder.zig        — multi-pass binding walker
```

The binder is the most complex part. It needs multiple passes because
Cobra allows forward references. Each pass is a visitor over the AST.

### Phase 8–9: Code Generation

```
src/
  ZigGen.zig        — AST visitor that emits Zig source text
  NativeRuntime.zig — mapping of Cobra built-ins to Zig equivalents
```

The Zig generator needs a `CurlyWriter` equivalent — a buffered writer
that tracks indentation.

### Phase 10: Driver

```
src/
  main.zig          — CLI argument parsing, phase orchestration
  Compiler.zig      — top-level coordinator
  Diagnostics.zig   — error/warning collection and formatting
```

### Data structures needed

| Need | Option |
|------|--------|
| String interning | `std.StringHashMap(u32)` + arena |
| Sets (binding phases) | `deckarep/ziglang-set` or `std.AutoHashMap(T, void)` |
| Ordered symbol tables | `std.StringArrayHashMap` (preserves insertion order) |
| String building / formatting | `karlseguin/zul` buffer, or `std.ArrayList(u8)` |
| Dynamic dispatch (IType, INode) | `interface.zig` or fat pointers (struct + vtable) |
| Arena allocation | `std.heap.ArenaAllocator` (stdlib, no dependency) |

---

## Prioritized Implementation Order

### Milestone 1: Parse a trivial Cobra program

1. `Token.zig` — token kinds, source location
2. `Tokenizer.zig` — handle keywords, identifiers, literals, indent/dedent
3. `CobraGrammar.zig` — Cobra grammar (start with a subset: class + method + simple statements)
4. `Parser.zig` — wire earley to produce a CST
5. `Ast.zig` — minimal node set for the subset
6. `AstBuilder.zig` — CST → AST for the subset

**Checkpoint:** parse `hello.cobra` into an AST and print it.

### Milestone 2: Generate Zig for a trivial program

7. `ZigGen.zig` — emit Zig for classes, methods, print statements, basic exprs
8. `main.zig` — CLI: `cobra-zig hello.cobra` → `hello.zig` → `zig build-exe`

**Checkpoint:** compile and run `hello.cobra` end-to-end via the new compiler.

### Milestone 3: Type system and binding

9. `TypeSystem.zig` — built-in types, nilable, generics skeleton
10. `SymbolTable.zig` — scoped lookup
11. `Binder.zig` — resolve types, check assignments, method signatures

**Checkpoint:** detect a type error and report it with file/line.

### Milestone 4: Full language surface

12. Remaining statement types (for, branch, try/catch, contracts)
13. Remaining expression types (lambdas, comprehensions, string interp)
14. Generics (Class<of T>)
15. Interfaces and mixins
16. Standard library mapping (List, Dict, Set → Zig stdlib equivalents)

---

## Directory Structure (proposed)

```
C:\projects\cobra-language\
  zig-compiler\          ← new compiler lives here
    build.zig
    build.zig.zon
    src\
      main.zig
      Token.zig
      Tokenizer.zig
      CobraGrammar.zig
      Parser.zig
      Ast.zig
      AstBuilder.zig
      TypeSystem.zig
      SymbolTable.zig
      Binder.zig
      ZigGen.zig
      Compiler.zig
      Diagnostics.zig
    test\
      main.zig
    examples\            ← sample .cobra programs to test against
```

The earley library is referenced as a Zig package dependency in
`build.zig.zon`:

```zig
.dependencies = .{
    .earley = .{
        .path = "../../earley",  // local path during development
    },
},
```

---

## Immediate Next Step

Create `zig-compiler/` with `build.zig`, `build.zig.zon`, and begin
`Token.zig` + `Tokenizer.zig`. The tokenizer is the natural first piece —
it has no dependencies, is fully testable in isolation, and unblocks
everything else.
