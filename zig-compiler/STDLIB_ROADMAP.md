# Zebra Stdlib Roadmap — Batteries Included

Decided 2026-04-10. Modules to implement in priority order, all backed by Zig stdlib.
Each module follows Zebra's ergonomic pattern: one-liner API, no allocator args exposed.

---

## Implementation Queue

### 1. `Hash` — Cryptographic hashing ✅ TODO
**Zig backing:** `std.crypto.hash` (Sha256, Sha512, Md5, Blake3)

```zebra
var h = Hash.sha256("hello world")         # → hex string
var h2 = Hash.sha512(data)
var h3 = Hash.md5(data)                    # legacy compat
var h4 = Hash.blake3(data)                 # fast, modern
var hmac = Hash.hmac256(key, data)         # HMAC-SHA256
```

Codegen: `std.crypto.hash.sha2.Sha256.hash(data, &out, .{})` → hex-encode → `[]const u8`
TC additions: `Hash` namespace type, `.hash_result` type (or just `.string` for hex)
Test: `test/hash_test.zbr`

---

### 2. `Random` — Pseudo-random and secure random ✅ TODO
**Zig backing:** `std.Random.DefaultPrng` (Xoshiro256), `std.crypto.random`

```zebra
var n = Random.randInt(1, 100)             # i64 in [min, max]  (int/float/bool are keywords)
var f = Random.randFloat()                 # f64 in [0.0, 1.0)
var b = Random.randBool()
var s = Random.choice(["a", "b", "c"])    # random element
Random.shuffle(list)                       # in-place shuffle
var bytes = Random.bytes(16)               # secure random bytes (hex)
Random.seed(42)                            # deterministic seed
```

Codegen: module-level `var _rng = std.Random.DefaultPrng.init(...)` seeded from `std.crypto.random`
TC additions: `Random` namespace type
Test: `test/random_test.zbr`

---

### 3. `Arg` — CLI argument parsing ✅ TODO
**Zig backing:** `std.process.argsWithAllocator`

```zebra
var args = Arg.parse()
var verbose = args.flag("--verbose", "-v")         # bool
var output = args.option("--output", default: "a.out")   # str
var input = args.positional(0)                     # str?
var count = args.optionInt("--count", default: 1)  # int
if args.contains("--help")
    print args.usage()
```

Codegen: `Arg` struct backed by `std.process.args()` slice; flag/option lookups are linear scans
TC additions: `arg_result` type with field accessors
Alternative considered: declarative `Arg.define(...)` — deferred, start with imperative
Test: `test/arg_test.zbr`

---

### 4. `Terminal` — Color output and terminal queries ✅ TODO
**Zig backing:** `std.io.tty`, ANSI escape sequences

```zebra
Terminal.write("Success!", "green")    # print/println are Zebra keywords → write/writeln
Terminal.write("Warning!", "yellow")
Terminal.write("Error!", "red")
Terminal.writeln("dim text", "dim")

var w = Terminal.width()                   # int (columns)
var h = Terminal.height()                  # int (rows)
var is_tty = Terminal.isTty()             # bool (false if piped)

# Escape codes when not TTY: falls back to plain print
# Colors: .red .green .yellow .blue .magenta .cyan .white .dim .bold .reset
```

Codegen: `std.io.tty.detectConfig(std.io.getStdOut())` — use `.escape_codes` path on Windows/Unix
TC additions: `Terminal` namespace, `TermColor` enum type
Test: `test/terminal_test.zbr`

---

### 5. `Log` — Structured leveled logging ✅ TODO
**Zig backing:** `std.io.getStdErr()`, timestamp from `std.time`

```zebra
Log.info("Server started on port {}", port)
Log.warn("Retry {} of {}", attempt, max)
Log.err("Connection failed: {}", reason)
Log.debug("Parsed {} tokens", count)       # only if Log.level >= .debug

Log.setLevel(.warn)                        # suppress .info and .debug
Log.setOutput(.stderr)                     # default
Log.setOutput(.stdout)
Log.timestamp(false)                       # disable timestamps
```

Codegen: module-level `var _log_level: u8` and `var _log_timestamps: bool`; writes to stderr
Format: `[INFO  2026-04-10 14:23:01] message`
TC additions: `Log` namespace, `LogLevel` enum (debug/info/warn/err)
Test: `test/log_test.zbr`

---

## Backlog (implement after the above 5)

### 6. `Uri` — URL parsing
**Zig backing:** `std.Uri`
```zebra
var u = Uri.parse("https://api.example.com/v1/users?page=2")
print u.scheme    # "https"
print u.host      # "api.example.com"
print u.path      # "/v1/users"
print u.query     # "page=2"
```

### 7. `Compress` — gzip compress/decompress
**Zig backing:** `std.compress.gzip`
```zebra
var compressed = Compress.gzip(data)       # str → str
var original   = Compress.gunzip(data)     # str → str?
```

### 8. `Mime` — MIME type lookup
**Zig backing:** static compile-time map
```zebra
var mime = Mime.fromExt(".png")            # "image/png"
var ext  = Mime.toExt("text/html")        # ".html"
```

### 9. `Timer` — High-resolution timing
**Zig backing:** `std.time.nanoTimestamp()`
```zebra
var t = Timer.start()
# ... work ...
var ms = t.elapsed()                       # float (milliseconds)
var us = t.elapsedMicros()                 # int (microseconds)
t.reset()
```

### 10. `Chan(T)` — Message-passing channels (language feature)
**Zig backing:** `std.Thread`, mutex + condvar queue

Channel syntax decided 2026-04-10:
```zebra
var ch = Chan(int)(capacity: 10)

# Send (blocks if full):
ch <- 42

# Receive (blocks if empty):
var v <- ch

# Non-blocking / select: TBD (likely `select` block)
```

Grammar tokens: `<-` as `chan_send` / `chan_recv` (directional determines which)
This is a LANGUAGE FEATURE not just a stdlib module — needs grammar, AST, TC, codegen.

### 11. `Test` — Built-in test runner
```zebra
def test_addition
    assert_eq(add(2, 3), 5)
    assert_eq(add(-1, 1), 0)

def test_throws_on_null
    assert_raises
        parseUser(nil)
```

Needs: `zebra test` subcommand, test discovery by naming convention.

---

## Design Notes

**Pattern all stdlib modules follow:**
- Static namespace (`shared` methods only, no instances except where state is needed)
- No allocator args — uses `_allocator` implicitly
- Graceful degradation (e.g., Terminal falls back to plain print when not a TTY)
- Returns `str` for binary data, using hex encoding (simpler than byte arrays for now)

**Allocator note:**
All stdlib functions use the program-wide `_allocator` (arena). Memory is held until
program exit. For compute-intensive stdlib use, users can scope with `arena` blocks.

**TC integration pattern:**
Each new stdlib module adds entries to `inferCall` and `inferMember` in TypeChecker.zig —
the same pattern used for `Http`, `File`, `Json`, `Math`, etc.

**`<-` channel operator:**
- `ch <- val` — SEND: callee is channel, arg is value  
- `var v <- ch` — RECEIVE: LHS is variable, RHS is channel
- Grammar: new infix/prefix operator; TypeChecker needs to know LHS/RHS roles
- CodeGen: emits mutex lock/unlock + queue push/pop + condvar wait/signal
- This is 1.0 work — needs thread model decision first

---

*Created: 2026-04-10*
*Status: Implementing in order listed above*
