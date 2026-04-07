#!/usr/bin/env python3
"""
Zebra REPL — Interactive interpreter for Zebra language.

Phase 0: Single-line expressions and variable definitions.
Reads lines from stdin, wraps them in valid Zebra programs,
calls the `zebra` compiler, and displays results.

When `sys.run()` and `System.readLine()` are implemented in Zebra,
this logic can be ported directly.
"""

import sys
import subprocess
import tempfile
import os
from pathlib import Path


class ZebraREPL:
    """Interactive REPL for Zebra expressions."""

    def __init__(self):
        self.accumulated = []  # List of var definition lines
        self.temp_dir = tempfile.gettempdir()
        self.zebra_binary = self._find_zebra_binary()

    def _find_zebra_binary(self) -> str:
        """
        Find the zebra binary in common locations:
        1. Same directory as this script (for dev)
        2. zig-out/bin/ (built from zig build)
        3. In PATH
        """
        script_dir = Path(__file__).parent
        candidates = [
            script_dir / "zig-out" / "bin" / "zebra.exe",
            script_dir / "zig-out" / "bin" / "zebra",
            script_dir / "zebra.exe",
            script_dir / "zebra",
            Path("zebra.exe"),
            Path("zebra"),
        ]

        for candidate in candidates:
            if candidate.exists():
                return str(candidate)

        # Try PATH
        return "zebra"

    def classify_input(self, line: str) -> tuple[str, str]:
        """
        Classify input as command, var definition, or expression.
        Returns (kind, content) where kind is one of:
            'command' — :quit, :help, :clear
            'var_def' — var x = ...
            'expression' — anything else
        """
        trimmed = line.strip()
        if trimmed.startswith(':'):
            return 'command', trimmed
        elif trimmed.startswith('var '):
            return 'var_def', trimmed
        else:
            return 'expression', trimmed

    def build_program(self, current_line: str, wrap_with_print: bool) -> str:
        """Build a valid Zebra program from accumulated state + current line."""
        lines = [
            "class Main",
            "    shared",
            "        def main",
        ]

        # Add accumulated var definitions
        for var_line in self.accumulated:
            lines.append(f"            {var_line}")

        # Add current line (wrapped with print if it's an expression)
        prefix = "print " if wrap_with_print else ""
        lines.append(f"            {prefix}{current_line}")

        return '\n'.join(lines) + '\n'

    def run_program(self, program: str) -> tuple[int, str]:
        """
        Execute a Zebra program.
        Returns (exit_code, stderr_output).
        """
        temp_file = Path(self.temp_dir) / ".repl_tmp.zbr"
        try:
            # Write temp file (use newline='' to avoid Windows line ending issues)
            with open(temp_file, 'w', newline='', encoding='utf-8') as f:
                f.write(program)

            # Run zebra binary
            result = subprocess.run(
                [self.zebra_binary, str(temp_file)],
                capture_output=True,
                text=True,
                timeout=10,
            )

            return result.returncode, result.stderr

        except subprocess.TimeoutExpired:
            return 1, "Error: Program execution timed out\n"
        except FileNotFoundError:
            return 1, "Error: zebra binary not found. Is it in PATH?\n"
        finally:
            # Clean up temp files
            temp_file.unlink(missing_ok=True)
            zig_file = temp_file.with_suffix('.zig')
            zig_file.unlink(missing_ok=True)

    def handle_command(self, cmd: str) -> bool:
        """
        Handle special commands.
        Returns True if REPL should continue, False if should exit.
        """
        if cmd in (':quit', ':exit'):
            return False
        elif cmd == ':clear':
            self.accumulated.clear()
            print("State cleared.")
        elif cmd == ':help':
            print("""\
Commands:
  :quit, :exit   - exit the REPL
  :clear         - clear all accumulated variables
  :help          - show this help

Input:
  var x = ...    - define a variable (stored in session)
  2 + 3          - evaluate an expression
  "hello".upper() - call methods
""")
        else:
            print(f"Unknown command: {cmd}")
        return True

    def process_line(self, line: str) -> bool:
        """
        Process one line of input.
        Returns True if REPL should continue, False if should exit.
        """
        kind, content = self.classify_input(line)

        if kind == 'command':
            return self.handle_command(content)

        # For var definitions and expressions
        is_var_def = kind == 'var_def'

        if is_var_def:
            # For var definitions, add directly to accumulated without verification
            # (Verification would fail due to "unused variable" errors)
            self.accumulated.append(content)
            # No output — var definitions are silent
        else:
            # For expressions: build program with accumulated vars and new expression
            program = self.build_program(content, wrap_with_print=True)
            exit_code, stderr = self.run_program(program)

            if exit_code == 0:
                # Success — print output
                if stderr:
                    print(stderr, end='')
            else:
                # Error — show error message (don't update state)
                if stderr:
                    print(stderr, end='')

        return True

    def run(self):
        """Main REPL loop."""
        print("Zebra REPL v0.1 (Phase 0: expressions + var definitions)")
        print("Type :help for commands, :quit to exit.\n")

        while True:
            try:
                line = input("zebra> ")
                if not line.strip():
                    continue
                if not self.process_line(line):
                    break
            except KeyboardInterrupt:
                print("\n(interrupted)")
                break
            except EOFError:
                break

        print("\nGoodbye!")


def main():
    """Entry point."""
    repl = ZebraREPL()
    repl.run()


if __name__ == '__main__':
    main()
