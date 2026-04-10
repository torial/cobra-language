#!/usr/bin/env python3
import sys
from pathlib import Path

# Import the REPL class directly
exec(Path('zebra-repl.py').read_text().split('\nif __name__')[0])

repl = ZebraREPL()

# Simulate user inputs
inputs = [
    'var greeting = "World"',
    'greeting',
]

for inp in inputs:
    kind, content = repl.classify_input(inp)
    is_var_def = kind == 'var_def'
    print(f"\n=== Input: {inp} ===")
    print(f"Kind: {kind}, Content: {content}")
    print(f"Is var def: {is_var_def}")
    
    program = repl.build_program(content, wrap_with_print=not is_var_def)
    print(f"\nGenerated program:")
    for i, line in enumerate(program.split('\n'), 1):
        print(f"{i}: {repr(line)}")
    
    print(f"\nAccumulated before: {repl.accumulated}")
    
    exit_code, stderr = repl.run_program(program)
    print(f"Exit code: {exit_code}")
    if stderr:
        print(f"Stderr:\n{stderr}")
    
    if exit_code == 0 and is_var_def:
        repl.accumulated.append(content)
        print(f"Accumulated after: {repl.accumulated}")
