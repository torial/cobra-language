# Zebra REPL — Interactive Interpreter

A companion REPL for the [Zebra Programming Language Book](../../zebra-language-book/), letting you interactively try examples from the chapters.

## Quick Start

```bash
python3 zebra-repl.py
```

Or with explicit Python path on Windows:
```bash
C:\Users\{username}\AppData\Local\Programs\Python\Python313\python.exe zebra-repl.py
```

## Phase 0: What Works

### Expressions
```
zebra> 2 + 3
5

zebra> "hello".upper()
HELLO

zebra> 10 > 5
true
```

### Variable Definitions
```
zebra> var name = "Alice"
zebra> var age = 30
zebra> "Hello, ${name}! You are ${age}."
Hello, Alice! You are 30.
```

### String Interpolation
```
zebra> var greeting = "World"
zebra> "Hello, ${greeting}!"
Hello, World!
```

### Commands
```
zebra> :help              # Show help
zebra> :clear             # Clear all variables
zebra> :quit              # Exit
```

## How It Works

The REPL:
1. Reads your input line
2. Classifies it as a command, variable definition, or expression
3. Accumulates variable definitions in memory
4. Wraps expressions in a valid Zebra program
5. Calls the `zebra` compiler as a subprocess
6. Captures and displays the output

**No compiler modifications needed** — it communicates via the CLI only.

## Limitations (Phase 0)

- **Single-line input only** — Press Enter to execute
- **No collections** — `List()`, `HashMap()` etc. not available (no imports)
- **No functions or classes** — Just expressions and simple variable state
- **No loops or conditionals** — Only expressions and var definitions

These are Phase 1+ features, tracked in the implementation plan.

## Future Phases

| Phase | Features |
|-------|----------|
| **0 (current)** | Expressions + var definitions |
| **1** | `if`/`while`/`for` blocks (multiline input) |
| **2** | `def` function definitions |
| **3** | Port to Zebra (once `sys.run()` and `System.readLine()` are implemented) |

## Implementation Notes

The REPL is written in Python because the Zebra runtime currently lacks:
- `sys.run()` — subprocess launching
- `System.readLine()` — reading user input from stdin

Once these are implemented in the Zebra compiler, the logic can be directly ported to Zebra for self-hosting.

## For Book Readers

Use the REPL to experiment with examples from the Zebra Programming Language Book:

```
# From Chapter 02: Values and Types
zebra> var x = 42
zebra> var y = 3.14
zebra> x + y
45.14

# From Chapter 06: Strings and Unicode
zebra> var text = "Hello, World!"
zebra> text.upper()
HELLO, WORLD!

zebra> text.substring(0, 5)
Hello
```

## Finding the Zebra Binary

The REPL automatically looks for the `zebra` binary in:
1. `zig-out/bin/` (if you built with `zig build`)
2. Current directory
3. System `PATH`

If not found, you'll get an error: `Error: zebra binary not found. Is it in PATH?`

**Solution:** Build the compiler first:
```bash
zig build
```

## Troubleshooting

### "zebra binary not found"
- Run `zig build` from the `zig-compiler/` directory
- Or add the binary to your PATH

### "internal compiler error"
- This means the generated Zebra program has a syntax error
- Usually because of quote escaping or indentation issues
- Report the error message

### Variables not persisting
- Check that you defined them with `var` (silent output)
- Verify they appear with `:clear` before trying again
- Some types (Lists, HashMaps) need imports which aren't loaded in Phase 0

## See Also

- Zebra Programming Language Book: `../../zebra-language-book/`
- Zebra Compiler: `src/main.zig`
- Build system: `build.zig`
