# Zebra Language Quick Reference

This file is the **agent-facing quick reference** for the Zebra language (.zbr files).
It covers syntax, semantics, and idioms needed to read and write Zebra without
scanning the full compiler source. For the compiler's own implementation see `src/`.

---

## 1. File structure

```zebra
# comment
use ast exposing Decl, TypeRef        # import from module, expose names into scope
use codegen                            # import module (access via codegen.Name)

# top-level functions
def helper(x as int) as str
    return x.toString()

# top-level class / struct / enum / union
class Foo
    ...

struct Bar
    ...
```

- `.zbr` files are modules. The module name is the file stem (`codegen.zbr` → module `codegen`).
- `use path/to/module` makes `module.Name` available.
- `use path/to/module exposing A, B` also binds `A` and `B` directly in scope.
- No explicit `main` — programs have a `class Main` with `shared def main`.

---

## 2. Variables

```zebra
var x = 42                     # inferred type (int)
var name as str = "hello"      # explicit type annotation
var flag as bool               # declaration without init (must assign before use)
var opt as int? = nil          # optional int, initially nil
```

- `var` is always mutable. There is no `let` / `const` in Zebra source.
- The compiler emits `const` or `var` in Zig based on mutation analysis — you don't control this.
- Type annotations use `as Type` syntax.

---

## 3. Primitive types

| Zebra       | Zig             | Notes                         |
|-------------|-----------------|-------------------------------|
| `int`       | `i64`           | default integer               |
| `uint`      | `u64`           |                               |
| `float`     | `f64`           | default float                 |
| `bool`      | `bool`          |                               |
| `char`      | `u21`           | Unicode codepoint             |
| `str`       | `[]const u8`    | immutable string slice        |
| `String`    | `[]const u8`    | alias for str                 |
| `int8–128`  | `i8–i128`       | sized integers                |
| `uint8–128` | `u8–u128`       |                               |
| `float16–128` | `f16–f128`    |                               |
| `StringBuilder` | `std.ArrayList(u8)` | growable string buffer |
| `void`      | `void`          |                               |

Optionals: `T?` → `?T` in Zig. `nil` → `null`.

---

## 4. Functions (top-level `def`)

```zebra
def add(a as int, b as int) as int
    return a + b

def greet(name as str)       # void return (no `as Type`)
    print "Hello, ${name}"

def divide(a as int, b as int) as int throws   # can raise errors
    if b == 0
        raise "division by zero"
    return a / b
```

- `throws` makes the method return `anyerror!T` in Zig.
- `raise "msg"` → returns a Zig error (wraps the string in a named error set).
- Call: `add(1, 2)` — parentheses always required.

---

## 5. Classes (reference types)

Classes are heap-allocated. Variables hold a pointer (`*ClassName` in Zig).
Assigning a class variable copies the pointer, not the object.

```zebra
class Counter
    var count as int

    cue init()                    # constructor
        count = 0

    def increment
        count += 1

    def value() as int
        return count

    shared def create() as Counter    # static method
        return Counter()
```

- `cue init(params...)` is the constructor. No return type.
- `shared def` = static method. Inside shared methods, `this` is unavailable.
- Field access inside methods: `count` (no `self.` needed). External: `obj.count`.
- Constructor call: `Counter()` or `Counter(arg1, arg2)`.

---

## 6. Structs (value types)

Structs are copied on assignment. Methods take `self: *StructType` in Zig.

```zebra
struct Point
    var x as int
    var y as int

    cue init(x as int, y as int)
        this.x = x
        this.y = y

    def distSq() as int
        return x*x + y*y

    def withX(nx as int) as Point    # returns a modified copy
        var p = this except
            x = nx
        return p
```

- `this` refers to the struct value. Use `this.field` when param shadows field name.
- **`this except field = value, ...`** — creates a copy with specified fields overridden. This is the primary idiom for immutable-style context forking.
- Method chaining on temporaries is BANNED — see Section 14.

---

## 7. `struct except` — context forking

```zebra
struct Config
    var indent as int
    var owner  as str
    var verbose as bool

    def indented() as Config
        var c = this except
            indent = indent + 1
        return c

    def withOwner(name as str) as Config
        var c = this except
            owner = name
        return c
```

**Critical rule:** You CANNOT chain these calls on temporaries:
```zebra
# WRONG — compile error (temporary is *const Config):
var c = makeConfig().indented().withOwner("Foo")

# RIGHT — materialize each step:
var c0 = makeConfig()
var c1 = c0.indented()
var c  = c1.withOwner("Foo")
```

---

## 8. Enums

```zebra
enum Color
    red
    green
    blue

enum Status(int)             # backed by int
    ok = 0
    err = 1
```

Usage: `Color.red`, `Status.ok`.

---

## 9. Unions (tagged unions)

```zebra
union Expr
    int_ as int
    str_ as str
    void_                    # payload-less variant
    node_ as ^Node           # heap-indirection payload

# Construction:
var e = Expr.int_(42)
var v = Expr.void_()

# Pattern matching:
branch e
    on Expr.int_ as n
        print "int: ${n}"
    on Expr.str_ as s
        print "str: ${s}"
    on Expr.void_
        print "void"
    else
        pass
```

- `^T` payload: the pointer is transparent — the branch-binding variable has type `T`, not `*T`.
- `else` with `pass` is required for non-exhaustive branches.

---

## 10. Collections

```zebra
# List
var items = List(int)()          # empty list
items.add(1)
items.add(2)
var n = items.count()            # length
var x = items.at(0)             # index (bounds-checked)
items.remove(0)                  # remove by index

# HashMap
var m = HashMap(str, int)()
m.set("a", 1)
var v = m.get("a")              # returns int? (optional)
var has = m.contains("a")       # bool

# Iteration
for item in items
    print item

for k, v in m
    print "${k} = ${v}"
```

---

## 11. Optional types and nil

```zebra
var x as int? = nil
var y as int? = 42

if x != nil
    print x to!              # `to!` = force-unwrap (like .? in Zig)

var z = x ?? 0               # nil-coalescing: use 0 if nil

# Optional chaining:
var n = node?.next           # nil if node is nil
var v = node?.value to! + 1  # unwrap result of optional chain
```

- `x to!` is the force-unwrap operator. Panics if nil.
- `??` is nil-coalescing (like `orelse` in Zig).
- `?.` is optional member access — propagates nil.

---

## 12. Error handling

```zebra
def divide(a as int, b as int) as int throws
    if b == 0
        raise "division by zero"
    return a / b

def caller() as int throws
    var r = divide(10, 2)     # auto-propagates (same-file throws methods)
    return r

# try / catch:
try
    var r = divide(10, 0)
    print r
catch e
    print "Error: ${e}"

# Explicit propagation with `?`:
var r = someObj.method()?    # propagates if method throws
```

- `throws` on a `def` makes it return `anyerror!T`.
- Inside a `throws` method, calls to other `throws` methods in the same file auto-propagate (emit `try`).
- For cross-module `throws` calls or local variable method calls, use explicit `?` suffix.
- `raise "message"` creates an error.

---

## 13. Control flow

```zebra
# if / else if / else
if x > 0
    print "positive"
else if x < 0
    print "negative"
else
    print "zero"

# while
var i = 0
while i < 10
    print i
    i += 1

# for-in (list)
for item in items
    print item

# for-in with index
for i, item in items
    print "${i}: ${item}"

# for-num (numeric range)
for i in 0 to 10       # 0..9
    print i
for i in 0 to 10 step 2
    print i

# guard (early return on nil/false)
guard x != nil else
    return

# branch (pattern matching on unions)
branch expr
    on ExprKind.int_ as n
        return n
    on ExprKind.str_ as s
        return s.len
    else
        pass
```

---

## 14. String operations

```zebra
var s = "hello"
var t = "world"
var u = s + ", " + t           # concatenation
var n = s.len                  # length (int)
var c = s[0]                   # char at index
var sub = s[1..3]              # substring slice
var up = s.upper()
var lo = s.lower()
var trimmed = s.trim()
var b = s.startsWith("hel")   # bool
var b2 = s.endsWith("lo")     # bool
var idx = s.indexOf("ll")     # int? (nil if not found)
var parts = s.split(",")      # List(str)
var joined = items.join(", ") # str

# String interpolation
var msg = "Hello, ${name}! You have ${count} items."

# StringBuilder
var sb = StringBuilder()
sb.append("hello")
sb.append(" world")
var result = sb.build()       # str (drains the builder)
```

- `in` operator for substring check: `if "needle" in haystack`
- `"needle" in haystack` is preferred over `haystack.contains("needle")` when TC can't resolve the method.

---

## 15. Modules and cross-module usage

```zebra
# file: math_utils.zbr
def square(x as int) as int
    return x * x

struct Vec2
    var x as float
    var y as float

    def length() as float
        return Math.sqrt(x*x + y*y)
```

```zebra
# file: main.zbr
use math_utils exposing square, Vec2    # expose into scope

def main
    var n = square(5)         # direct call
    var v = Vec2(3.0, 4.0)
    print v.length()

# OR without exposing:
use math_utils

def main
    var n = math_utils.square(5)
    var v = math_utils.Vec2(3.0, 4.0)
```

**Cross-module type annotation:**
```zebra
var v as math_utils.Vec2 = math_utils.Vec2(1.0, 2.0)
# OR with exposing:
var v as Vec2 = Vec2(1.0, 2.0)
```

---

## 16. Interfaces and mixins

```zebra
interface Printable
    def show() as str

class Dog mixes Printable
    var name as str

    cue init(name as str)
        this.name = name

    def show() as str
        return "Dog(${name})"

# `is` check:
if obj is Printable
    print obj.show()
```

---

## 17. Generics

```zebra
class Stack(T)
    var _items as List(T)

    cue init()
        _items = List(T)()

    def push(item as T)
        _items.add(item)

    def pop() as T?
        if _items.count() == 0
            return nil
        var last = _items.at(_items.count() - 1)
        _items.remove(_items.count() - 1)
        return last

# Usage:
var s = Stack(int)()
s.push(1)
s.push(2)
var top = s.pop()
```

- Generic class instantiation: `Stack(int)()` — type arg then constructor args.
- Type params can have constraints: `class Cache(K where Hashable)`.

---

## 18. Properties

```zebra
class Circle
    var _radius as float

    cue init(r as float)
        _radius = r

    prop radius as float
        return _radius

    prop area as float
        return Math.PI * _radius * _radius
```

- `prop name as Type` defines a read-only computed property.
- Access: `c.radius` (no parens).

---

## 19. Lambda / closures

```zebra
var double = (x as int) -> x * 2
var items = List(int)()
items.add(1)
items.add(2)

# Higher-order (not yet widely supported — use explicit loops):
# items.map(double)
```

---

## 20. Type checks and casts

```zebra
if obj is Dog
    var d = obj as Dog      # downcast
    print d.name

var x as int? = 42
var y = x to!               # force-unwrap optional (panics if nil)
```

---

## 21. `^T` heap-indirection (recursive types only)

Used to break recursive struct cycles:

```zebra
struct Node
    var value as int
    var next  as ^Node?    # heap-boxed optional pointer

# Construction — boxing is automatic:
var a = Node(1, nil)
var b = Node(2, nil)
a.next = b                 # auto-boxes: allocates *Node, copies b into it
```

- `^T` in a field type declaration → `*T` in Zig.
- `^T?` → `?*T` in Zig.
- Assignment to a `^T` field auto-boxes: allocates a heap copy.
- Inside a `branch` on a union with `^T` payload, the binding has type `T` (pointer is transparent).

---

## 22. `zig"..."` escape hatch

Inline Zig code (for stdlib wrappers or when Zebra doesn't support a pattern):

```zebra
def rawMemset(ptr as uint, size as uint)
    zig"@memset(@as([*]u8, @ptrFromInt(ptr))[0..size], 0);"
```

---

## 23. Key idioms summary

| Pattern | Zebra | Notes |
|---------|-------|-------|
| Force-unwrap optional | `x to!` | panics if nil |
| Nil-coalescing | `x ?? default` | |
| Substring test | `"needle" in str` | prefer over `.contains` |
| Optional chain | `obj?.field` | propagates nil |
| Error propagation | `expr?` | explicit in local/cross-module calls |
| Auto-propagation | `self.method()` | same-file throws methods only |
| Struct update copy | `this except field = val` | `struct except` idiom |
| Force cast | `x as Type` | downcast after `is` check |
| Int-to-float | `x.toFloat()` | explicit conversion |
| Divide integers | use `int` division | `%` for modulo |

---

## 24. Common gotchas

1. **`else` + `pass` must be on separate lines:**
   ```zebra
   # WRONG:
   else pass
   # RIGHT:
   else
       pass
   ```

2. **`if` single-line form — body must be on new indented line:**
   ```zebra
   # WRONG:
   if x > 0 return x
   # RIGHT:
   if x > 0
       return x
   ```

3. **Multi-line `use` — all names must be on one line (no continuation):**
   ```zebra
   use ast exposing Decl, DeclEnum, DeclUnion, DeclStruct, TypeRef
   ```

4. **`List(T)()` not `List(T)` — always call the constructor:**
   ```zebra
   var items = List(int)()    # correct
   var items as List(int)     # declaration only (no init — error for collections)
   ```

5. **Class fields initialized in `cue init`, not at declaration:**
   ```zebra
   class Foo
       var items as List(int)    # no = here
       cue init()
           items = List(int)()   # init here
   ```

6. **`StringBuilder` field → use `= StringBuilder()` in cue init:**
   The compiler special-cases `StringBuilder()` to emit `std.ArrayList(u8){}`.

7. **Struct method chaining on temporaries fails** (see Section 7). Always use named intermediate vars.

8. **`print` is a statement, not a function:** `print "hello"` not `print("hello")`.
   For multiple values: `print "a", b, "c"`.

9. **Keyword escaping** — Zig keywords used as Zebra field names must be renamed with trailing underscore convention in codegen output: `type_` not `type`, `void_` not `void`.

10. **`cue init` with explicit params needs `this.field` when param shadows field:**
    ```zebra
    cue init(x as int, y as int)
        this.x = x    # 'x' param shadows 'x' field
        this.y = y
    ```

---

## 25. Build and run

```bash
# From zig-compiler/ directory:
zig build run -- path/to/file.zbr    # compile and run
zig build test                        # run test suite

# Multi-file with imports:
zig build run -- selfhost/codegen_test.zbr   # auto-discovers imports
```

The compiler resolves `use module_name` by looking for `module_name.zbr` in the same directory as the input file, then in `selfhost/`, `test/`, and stdlib paths.
