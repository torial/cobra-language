# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **Cobra Programming Language** compiler, originally targeting .NET/Mono, with an **in-progress port to a Zig backend** (currently on the `zig_backend` branch). Cobra is a self-hosted compiler written entirely in Cobra, combining features from Python, C#, Objective-C, and Eiffel with contracts, nil tracking, and quality-focused design.

The compiler is bootstrapped using a snapshot compiler in `Source/Snapshot/` and generates intermediate code (currently C#, moving to Zig) which is then compiled to executables.

## Building and Testing

### Building the Compiler

From the `Source/` directory:

**Unix/Mac:**
```bash
bin/build              # Build with snapshot compiler
bin/build -turbo       # Optimized build without contracts
```

**Windows:**
```cmd
bin\build.bat
bin\build.bat -turbo
```

The build script uses the snapshot compiler at `Source/Snapshot/cobra.exe` to compile `cobra.cobra` with all files listed in `files-to-compile.text`.

### Running Tests

**Full test suite:**
```bash
bin/testify                    # Run all tests
bin/testify ../Tests/100-basics   # Run specific test directory
```

**Windows:**
```cmd
bin\testify.bat
bin\testify.bat ..\Tests\100-basics
```

Test directories in `Tests/` are numbered by category (100-basics, 120-classes, 240-generics, etc.). Tests use Cobra's built-in unit test framework (test methods).

### Building the Standard Library

```bash
cobra -build-standard-library     # Creates Cobra.Core.dll
cobra -bsl -turbo                 # Optimized build
```

### Running Cobra Programs

```bash
cobra MyProgram.cobra         # Compile and run
cobra -c MyProgram            # Compile only
mono --debug MyProgram.exe    # Run with debugging (Unix/Mac)
```

## Architecture

### Compiler Phases

The compiler operates in sequential phases (in `Source/Phases/`). The main phases are:

1. **Command line processing** - Parse options and input files
2. **Tokenize** - Convert source text to tokens (`CobraTokenizer.cobra`)
3. **Parse** - Build abstract syntax tree (`CobraParser.cobra`)
4. **Bind run-time library** - Load and bind the Cobra runtime
5. **Read libraries** - Load referenced assemblies/libraries
6. **Bind use** - Resolve `use` directives to namespaces
7. **Bind inheritance** - Resolve class/interface inheritance
8. **Bind interface** - Resolve member signatures
9. **Bind mixins** - Resolve mixin declarations
10. **Bind implementation** - Resolve method bodies and expressions
11. **Identify main** - Find the program entry point
12. **Code generation** - Generate backend code (C#/Zig)
13. **Compilation** - Invoke native compiler
14. **Run** - Execute the resulting program

Each phase can halt on errors. Phases are implemented as `Phase` subclasses. Additional phases like `ComputeMatchingBaseMembersPhase`, `CountNodesPhase`, `ShowSharedDataPhase`, and `SuggestDefaultNumberPhase` handle specific compiler analyses.

### Core Components

**Main Compiler Files:**
- `Compiler.cobra` - Central compiler orchestrator, type provider
- `CommandLine.cobra` - Argument parsing and option handling
- `Node.cobra` - Base AST node interfaces (`INode`, `ISyntaxNode`)

**Parsing:**
- `Tokenizer.cobra` / `CobraTokenizer.cobra` - Lexical analysis
- `Parser.cobra` / `CobraParser.cobra` - Recursive descent parser
- `Expr.cobra` - Expression nodes
- `Statements.cobra` - Statement nodes

**Type System:**
- `Types.cobra` - Type hierarchy (`IType`, `CobraType`, primitive types)
- `TypeProxies.cobra` - Forward type references (`ITypeProxy`, type identifiers)
- `Boxes.cobra` - Classes, interfaces, structs (collectively "boxes")
- `Container.cobra` - Generic base for nodes containing declarations
- `NameSpace.cobra` - Namespace management with unified/non-unified handling

**Backend Architecture:**
- `BackEnd.cobra` - Abstract backend interface
- `BackEndClr/` - .NET/Mono backend (C# code generation)
  - `SharpGenerator.cobra` - C# code generator
  - `ScanClrType.cobra` - DLL scanning and type loading
- `BackEndZig/` - **Work in progress** Zig backend
  - `ZigGenerator.cobra` - Zig code generator (incomplete)
  - `ScanZigType.cobra` - Zig type scanning
- `BackEndCommon/` - Shared utilities (`CurlyWriter`, `CurlyGenerator`)

**Runtime Library:**
- `Source/Cobra.Core/` - Standard library compiled to `Cobra.Core.dll`
- `Source/Cobra.Core/Native.cs` - Native C# support functions for runtime

### Key Concepts

**Boxes:** The compiler uses "box" as a collective term for classes, interfaces, and structs (anything that inherits `Box`). These are the primary containers of members.

**Type Proxies:** Since Cobra allows forward references and circular dependencies, the parser creates `ITypeProxy` objects (like `AbstractTypeIdentifier`) that resolve to actual `IType` objects later during binding phases.

**Namespaces:** Namespaces can span multiple files. Each file's namespace instance tracks its own `use` directives (non-unified), but declarations are merged into a unified namespace in the compiler's global namespace (`.globalNS`).

**Members and Overloads:** Members are tracked in boxes via dictionaries. Overloaded members are wrapped in `MemberOverload` containers. Use `.declForName` for declared-only lookup (no inheritance) and `.memberForName` for inherited lookup.

**Self-Hosting:** The compiler is written in Cobra. The `Source/Snapshot/` directory contains the stable compiler used to build new versions. Use `bin/make-snapshot` to update the snapshot after successful builds and tests.

## Zig Backend Port (WIP)

**Current State:** The Zig backend is in **very early stages** in `Source/BackEndZig/`. The existing code is largely a skeleton copied from the CLR backend with minimal modifications. Most functionality is still delegating to CLR/.NET types and the Sharp code generator.

**Critical Issue:** The `ZigBackEnd.makePhases` method still adds `GenerateSharpCodePhase` and `CompileSharpCodePhase` instead of the Zig equivalents, meaning the Zig code generation path is not yet wired up.

**What Exists:**
- Basic file structure (`ZigBackEnd.cobra`, `ZigGenerator.cobra`, `ScanZigType.cobra`)
- Stub phase classes (`GenerateZigCodePhase`, `CompileZigCodePhase`) that aren't used yet
- Type mapping table from Cobra types to System types (still CLR-based)

**What Needs Work (Major Effort Required):**
- Wire up Zig phases in `ZigBackEnd.makePhases`
- Implement actual Zig code generation in `ZigGenerator.cobra` (currently has CLR references)
- Replace all CLR type scanning with Zig type system (`ScanZigType.cobra`)
- Create `Native.zig` runtime library (equivalent of `Source/Cobra.Core/Native.cs`)
- Reimplement `Cobra.Core` standard library for Zig
- Replace all `.zigReadAssembly`, `.scanNativeTypeZig` etc. methods with Zig implementations

## Development Workflow

### Making Changes to the Compiler

1. Make code changes in `Source/`
2. Build: `bin/build`
3. Test with a simple program: `cobra hello` (uses `hello.cobra` in the Source directory)
4. Build standard library: `cobra -bsl`
5. Run test suite: `bin/testify` (note: some platform-specific test failures are expected)
6. For self-compilation test: `bin/make-trial` then compile the compiler

### Debugging the Compiler

**Detailed stack traces:**
```bash
bin/build -dst    # Compile with detailed stack trace support
```

**Keep intermediate files:**
```bash
cobra -keep-intermediate-files -c foo.cobra    # Keep generated .cs files
cobra -kif -c -v=2 foo.cobra                   # Keep files + show C# compile command
```

**Selective debugging output:**
In compiler code, filter by token location:
```cobra
v = .token.fileName.contains('foo') and .token.lineNum == 38
if v, trace this, x, y
```

**Interactive GUI exploration (Windows):**
```bash
bin/build-winforms-compiler.bat
cobra-win foo
```

### Self-Hosting and Snapshots

The compiler uses `Source/Snapshot/cobra.exe` to build itself. To update the snapshot:

1. Ensure all tests pass: `bin/testify`
2. Create trial: `bin/make-trial` (copies `cobra.exe` to `cobra-trial.exe`)
3. Test self-compilation: compile the compiler with `cobra-trial.exe`
4. Run tests again with the newly compiled compiler
5. Create snapshot: `bin/make-snapshot`

## Common Patterns

**Backend-Specific Code:**
- Avoid storing "sharp" (C#) values during binding phases
- Access `.sharpRef` and other backend properties only during code generation
- Backend-specific methods often have suffixes: `.scanNativeTypeZig`, `.prepSystemObjectClassClr`

**Error Recording:**
```cobra
.compiler.recordError(node, 'Error message')
.recordError('Error message')  # From within a node
```

**Type Resolution:**
```cobra
type = typeProxy.realType      # Resolve proxy to actual type
if type implements IBox        # Check type category
box.memberForName('foo')       # Lookup with inheritance
box.declForName('foo')         # Lookup without inheritance
```

## File Organization

- `Source/` - Compiler source code
- `Source/Cobra.Core/` - Standard library
- `Source/Phases/` - Compiler phase implementations
- `Source/BackEndClr/` - C# backend
- `Source/BackEndZig/` - Zig backend (WIP)
- `Source/bin/` - Build and test scripts
- `Source/Snapshot/` - Bootstrap compiler
- `Tests/` - Test suite organized by category
- `HowTo/` - Tutorial examples
- `Samples/` - Sample programs
- `Developer/` - Developer documentation (see `ImplementationNotes.text`)

## Notes

- The compiler requires .NET 4.0+ or Mono 2.10+ for the CLR backend
- Set `COBRA_IS_DEV_MACHINE=1` environment variable when developing
- The `files-to-compile.text` file lists all source files for compilation in dependency order
- Contract checking and tests can be disabled with `-turbo` for faster compilation
- The main branch is `master`, but Zig work is on `zig_backend`
