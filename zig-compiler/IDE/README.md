# Zebra IDE — Self-Hosted Development Environment

This directory contains two Zebra IDEs written in Zebra itself, using the Dear ImGui GUI backend.

## What's Here

- **ProxyIDE.zbr** — Fully functional IDE **ready to use now**. Uses a mock compiler for demonstration.
- **ZebraIDE.zbr** — Complete IDE specification awaiting compiler features (4 stubs).
- **_ide_stubs.zbr** — Documentation of the 4 compiler stubs needed for ZebraIDE.
- **samples/** — Test Zebra files for IDE demonstration.

## ProxyIDE — The Working Demo

ProxyIDE is a complete, functional IDE that works **today** with current Zebra compiler features.

### Features

- **File Operations** — Open, save, and edit `.zbr` files
- **Mock Compiler** — Simulated diagnostics based on filename and content
- **Error Detection** — Scans for unclosed string literals and returns mock errors
- **Output Display** — Shows simulated program output
- **Stateful UI** — Persistent editor state via capture blocks across frames

### Run ProxyIDE

```bash
cd zig-compiler
zebra --gui-backend=glfw IDE/ProxyIDE.zbr
```

### Testing ProxyIDE

1. **Open samples/hello.zbr** — Click "Open", enter `samples/hello.zbr`, then "Check"
   - Result: No errors, clean compilation message
   - Click "Run" to see simulated output: `Hello, World!`

2. **Open samples/error.zbr** — Click "Open", enter `samples/error.zbr`, then "Check"
   - Result: Two hardcoded errors displayed in the diagnostics panel
     - Line 5: `type mismatch: expected 'str', got 'int'`
     - Line 9: `undefined: 'undefinedVar'`

3. **Create a new file** with an unclosed string, e.g., `test.zbr`:
   ```zebra
   var x = "unclosed
   ```
   - Click "Check" → ProxyIDE detects the unclosed string and reports it

### How ProxyIDE Works

ProxyIDE uses a `MockCompiler` class that:

1. **Analyzes filenames** — Returns hardcoded diagnostics for `hello.zbr` and `error.zbr`
2. **Scans content** — Detects unclosed string literals by counting quote characters
3. **Simulates execution** — Returns canned output based on filename
4. **Displays diagnostics** — Shows errors with line:column and message in a panel

The mock approach allows demonstrating the full IDE workflow before the compiler subprocess API is implemented.

## ZebraIDE — The Full-Featured IDE

ZebraIDE is a complete IDE specification designed to work with the **real** Zebra compiler via subprocess calls.

### Features (Awaiting 4 Compiler Stubs)

- **Real Compiler Integration** — Calls `zebra -c <file>` and `zebra <file>` as subprocesses
- **Syntax Highlighting & Error Markers** — Full-featured code editor with ImGuiColorTextEdit
- **Read-Only Output Pane** — Displays program output with the same editor control
- **Diagnostic Parsing** — Parses real compiler diagnostics from stderr
- **Undo/Redo, Copy/Paste** — Full text editor capabilities

### Why ZebraIDE Isn't Ready Yet

ZebraIDE requires **4 compiler features** that haven't been implemented yet:

| # | Feature | Where to Implement | Status |
|---|---------|-------------------|--------|
| 1 | `sys.run(argv) as SysRunResult` | `CodeGen.zig` `genSysCall` | **STUB** |
| 2 | `CodeEditor` type + render methods | `CodeGen.zig` + C++ shim | **STUB** |
| 3 | `g.inputMultiline()` GUI widget | `CodeGen.zig` `genGuiCall` | **STUB** |
| 4 | `g.panel()` child window widget | `CodeGen.zig` `genGuiCall` | **STUB** |

See `_ide_stubs.zbr` for detailed implementation specifications for each stub.

### Try ZebraIDE (With Stubs)

```bash
cd zig-compiler
zebra --gui-backend=glfw IDE/ZebraIDE.zbr
```

If you get compiler errors like `undefined sys.run`, that's expected — the stubs need implementation. See `_ide_stubs.zbr` for what to implement.

## Architecture

### ProxyIDE Class Hierarchy

```
Main
├── ideFrame(g as Gui)               — Main frame callback with capture block
├── renderFileBar(g, state)          — Toolbar: Open, Save, Check, Run buttons
├── renderEditor(g, state)           — Display numbered source lines
├── renderDiagnostics(g, state)      — Error list with icons
└── renderOutput(g, state)           — Program output display

ProxyIDEState (persisted via capture)
├── filepath as str
├── sourceCode as str
├── diagnostics as List(Diagnostic)
├── output as str
├── isDirty as bool
├── errorCount as int
└── lastLoaded as str

MockCompiler (simulates compiler behavior)
├── check(filepath, source) → List(Diagnostic)
└── run(filepath) → str

Diagnostic (compiler output)
├── line as int
├── col as int
├── message as str
└── isError as bool
```

### ZebraIDE Class Hierarchy

```
Main
├── ideFrame(g as Gui)               — Main frame with capture block
├── renderToolbar(g, state, editor)  — Open, Save, Check, Run, filename
├── renderBody(g, state, editor)     — Side-by-side editor + diagnostics
├── renderOutput(g, state)           — Read-only output editor
├── doCheck(state, editor)           — Invoke compiler check
└── doRun(state, editor)             — Invoke compiler run

IDEState (persisted via capture)
├── filepath as str
├── diags as List(IDEDiagnostic)
├── output as str
├── dirty as bool
└── lastCheck as str

CompilerBridge (real compiler subprocess calls)
├── check(filepath) → List(IDEDiagnostic)           — Calls zebra -c
├── runFile(filepath) → str                         — Calls zebra <file>
├── parseOutput(raw) → List(IDEDiagnostic)         — Parses stderr
└── parseLine(line) → IDEDiagnostic?               — Parses single line

IDEDiagnostic (parsed compiler output)
├── line as int
├── col as int
├── end_col as int
├── message as str
└── is_error as bool

CodeEditor (STUB: ImGuiColorTextEdit wrapper)
├── forZebra() → CodeEditor            — Factory for Zebra syntax
├── setText(text)                      — Set buffer content
├── getText() → str                    — Get current content
├── setErrorMarkers(diags)             — Mark lines with errors
├── setReadOnly(flag)                  — Lock editing
└── render(g, id, width, height)       — Draw each frame
```

## File Organization

```
IDE/
├── ProxyIDE.zbr               ✓ Ready now
├── ZebraIDE.zbr               ⏳ Awaits stubs
├── _ide_stubs.zbr             📋 Implementation spec
├── README.md                  👈 You are here
└── samples/
    ├── hello.zbr              ✓ Clean program
    └── error.zbr              ✓ Program with errors
```

## Implementation Progress

### Phase 1: Proxy IDE (✅ Complete)

- [x] Create ProxyIDE.zbr with mock compiler
- [x] Implement file I/O (load/save)
- [x] Implement diagnostic parsing from mock output
- [x] Create UI layout: toolbar + editor + diagnostics + output
- [x] Create sample test files
- [x] Document usage

### Phase 2: Full IDE (⏳ Awaiting Compiler Stubs)

When the 4 stubs are implemented in the compiler:

1. Implement `sys.run()` in `CodeGen.zig` genSysCall
   - Add `SysRunResult` type to `Builtins.zig` NAMES table
   - Emit `_sys_run()` preamble using `std.process.Child.run()`

2. Implement `CodeEditor` type and `genCodeEditorCall` in `CodeGen.zig`
   - Create C++ shim `ide_editor.cpp` wrapping ImGuiColorTextEdit
   - Register Zebra syntax rules from `Token.zig` keywords
   - Support error markers, read-only mode, undo/redo

3. Add `g.inputMultiline()` to `genGuiCall` in `CodeGen.zig`
   - Call ImGui's `InputTextMultiline()`
   - Allocate and manage mutable buffers

4. Add `g.panel()` to `genGuiCall` in `CodeGen.zig`
   - Wrap ImGui's `BeginChild()` / `EndChild()`
   - Create scrollable child windows

Once these stubs land, **ZebraIDE.zbr will compile and run as a fully-featured self-hosted IDE.**

### Phase 3: Enhancements (Post-MVP)

- [ ] Jump to error — click diagnostic to scroll editor to line
- [ ] File picker — text input for filename or file browser
- [ ] Auto-check on save — validate as you type
- [ ] Keyboard shortcuts — F5 to Check, F9 to Run, Ctrl+S to Save
- [ ] Multiple file tabs — support editing multiple files at once
- [ ] Find/Replace — leverage ImGuiColorTextEdit's built-in search (Ctrl+F)

## Key Decisions

**Why two IDEs?**

ProxyIDE demonstrates the IDE concept and workflow **today** without waiting for compiler features. ZebraIDE shows the full-featured architecture once stubs are available. This lets us validate UI design, user workflow, and file I/O patterns immediately.

**Why ImGuiColorTextEdit?**

The santaclose/ImGuiColorTextEdit fork provides:
- Syntax highlighting with custom language definitions
- Error markers (red squiggles) with hover tooltips
- Line numbers, undo/redo, copy/paste
- Read-only mode (useful for the output pane)
- Tight ImGui integration (renders each frame in immediate mode)

**Why subprocess calls instead of in-process compilation?**

Calling the compiler as a subprocess via `sys.run()` keeps the IDE responsive and decouples UI state from compiler state. If compilation fails, only the subprocess exits, not the IDE.

**Why capture blocks for state?**

Capture blocks allow IDE state (filepath, editor content, diagnostics) to persist across frames without global variables. Each frame callback can access the persisted state and update it.

## Next Steps for Developers

1. **Test ProxyIDE** — Run it, open samples, verify mock diagnostics work
2. **Implement the 4 stubs** — See `_ide_stubs.zbr` for detailed specs
3. **Switch to ZebraIDE** — Once stubs land, use real compiler integration
4. **Stress-test the language** — Use ZebraIDE to write larger programs in Zebra

## References

- Compiler diagnostic format: `zig-compiler/main.zig` (search for `printDiag`)
- Zebra keywords: `zig-compiler/src/Token.zig` (keyword map)
- Current `sys` module: `zig-compiler/src/Builtins.zig` (SYS section)
- Gui API reference: `zig-compiler/test/gui_test.zbr`
- Capture block examples: Multiple test files in `zig-compiler/test/`
