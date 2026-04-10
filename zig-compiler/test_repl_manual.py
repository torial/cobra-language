import sys
sys.path.insert(0, '.')
from pathlib import Path

script = Path('zebra-repl.py').read_text()
# Just test building the program
repl_code = """
import sys
sys.path.insert(0, '.')
from zebra_repl import ZebraREPL

repl = ZebraREPL()
repl.accumulated = ['var greeting = "World"']
program = repl.build_program("greeting", wrap_with_print=True)
print("Generated program:")
print(repr(program))
print("\nActual program:")
print(program)
"""
exec(repl_code)
