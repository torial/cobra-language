# Zebra Project Environment Setup

This document explains how to set up global environment variables for the Zebra programming language project.

## Why Environment Variables?

The Zebra project spans multiple directories and tools (markdown, Pandoc, compiler, IDE, etc.). Using environment variables allows:
- Scripts to work from any directory
- Consistent paths across all tools
- Easy portability if the project moves to a different location

## Environment Variables

The following variables should be set:

| Variable | Value | Purpose |
|----------|-------|---------|
| `ZEBRA_PROJECT` | `C:\Projects\cobra-language` | Project root directory |
| `ZEBRA_BOOK` | `C:\Projects\cobra-language\zebra-book` | Book documentation directory |
| `ZEBRA_DIAGRAMS` | `C:\Projects\cobra-language\zebra-book\diagrams` | Diagram assets directory |

## Quick Setup (Windows)

### Option 1: Automatic Setup (Recommended)

1. **Right-click `setup-env.bat`** and select **"Run as Administrator"**
2. The script will set all three variables permanently
3. Restart any open terminals/PowerShell windows
4. Verify: `echo %ZEBRA_PROJECT%` should print `C:\Projects\cobra-language`

### Option 2: Manual Setup

1. Press **Windows Key + X**, select **"System"**
2. Click **"Advanced system settings"** on the left
3. Click **"Environment Variables..."** button
4. Under **"User variables"**, click **"New..."**
5. Add each variable:
   - **Variable name:** `ZEBRA_PROJECT`
   - **Variable value:** `C:\Projects\cobra-language`
   - Click OK
6. Repeat for `ZEBRA_BOOK` and `ZEBRA_DIAGRAMS`
7. Click **"OK"** to close all dialogs
8. Restart any open terminals/PowerShell windows

## Usage in Scripts

Once set, you can reference these variables in batch files:

```batch
@echo off
echo Project root: %ZEBRA_PROJECT%
echo Book directory: %ZEBRA_BOOK%
echo Diagrams: %ZEBRA_DIAGRAMS%
```

## Usage in Build Scripts

### PDF Generation

The `build-pdf.bat` script now uses these variables:

```batch
pandoc input.md ^
  --resource-path="%ZEBRA_BOOK%" ^
  -o output.pdf
```

This allows Pandoc to find diagrams referenced as `../diagrams/01-type-hierarchy.svg` in markdown files.

### Compiler

The Zebra compiler (when it supports environment variables) can be invoked as:

```batch
zebra --output="%ZEBRA_PROJECT%\zig-compiler\output" input.zbr
```

## Verification

To verify your environment variables are set correctly:

**In Command Prompt:**
```cmd
echo %ZEBRA_PROJECT%
echo %ZEBRA_BOOK%
echo %ZEBRA_DIAGRAMS%
```

**In PowerShell:**
```powershell
$env:ZEBRA_PROJECT
$env:ZEBRA_BOOK
$env:ZEBRA_DIAGRAMS
```

All three should print valid paths.

## If You Move the Project

If you ever move the project to a different location, simply:
1. Run `setup-env.bat` again (it will update the variables), or
2. Manually edit the environment variables with the new path

## Troubleshooting

**"Variable not found" errors in scripts:**
- Make sure you ran setup-env.bat (or manually set the variables)
- Restart your terminal/PowerShell window after setting variables
- Don't use quotes when referencing in batch: `%ZEBRA_PROJECT%` not `"%ZEBRA_PROJECT%"`

**PDF build still can't find diagrams:**
- Verify `build-pdf.bat` includes `--resource-path="%ZEBRA_BOOK%"`
- Check that `%ZEBRA_BOOK%\diagrams\` exists and contains SVG files
- Try running the build script from the `zebra-book` directory

## Files Involved

- `setup-env.bat` — Script to set environment variables automatically
- `ENVIRONMENT_SETUP.md` — This file
- `zebra-book/build-pdf.bat` — PDF builder (uses `%ZEBRA_PROJECT%` and `%ZEBRA_BOOK%`)
- `zig-compiler/` — Compiler source (may reference `%ZEBRA_PROJECT%` in future)
