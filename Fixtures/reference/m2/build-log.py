#!/usr/bin/python3
"""Build a scratch C object and number the compiler's include trace for the shell log fixture."""
from pathlib import Path
import subprocess
import sys

first, last = map(int, sys.argv[1:] or ["1", "1030"])
source = Path("compile.c")
output = Path("compile.o")
headers = []
for number in range(first, last + 1):
    path = Path("units/café/界/e\u0301")
    if number % 128 == 0:
        path /= "long-dependency/with/nested-source-folders"
    path /= f"unit-{number:04}.h"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"enum {{ unit_{number} = {number} }};\n", encoding="utf8")
    headers.append(path)

source.write_text("".join(f'#include "{p}"\n' for p in headers)
                  + f"int build_result(void) {{ return unit_{last}; }}\n", encoding="utf8")
output.unlink(missing_ok=True)

# The only includes in this translation unit are the fixture's own headers.
# -H traces the preprocessor's real file visits, in order, to stderr.
process = subprocess.Popen(["/usr/bin/clang", "-H", "-c", source, "-o", output],
                           stderr=subprocess.PIPE, text=True, encoding="utf8")
expected = set(headers)
visits = []
for line in process.stderr:
    if not line.startswith(". "):
        print(line.rstrip(), file=sys.stderr, flush=True)
        continue
    header = Path(line[2:].rstrip())
    if header not in expected:
        continue
    visits.append(header)
    number = first + len(visits) - 1
    print(f"\x1b[32m{number:04}\x1b[0m  compile {header}", flush=True)
if process.wait() != 0 or visits != headers or not output.is_file() or output.stat().st_size == 0:
    sys.exit("The compiler did not build the object and visit every expected header in order.")
