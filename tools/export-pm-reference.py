#!/usr/bin/env python3
"""Export the original PixelMath GUI's function/operator reference verbatim."""
from pathlib import Path
import ast
import json
import re
import sys

source = Path(sys.argv[1]) / "src/gui-gtk4/pixelmath.c"
text = source.read_text()
entries = []
quoted = r'"(?:\\.|[^"\\])*"'
pattern = r'\{\s*(' + quoted + r')\s*,\s*(' + quoted + r')\s*,\s*N_\(\s*((?:' + quoted + r'\s*)+)\)\s*\}'
for name, group in [("functions", "函数"), ("image_functions", "图像统计"), ("operators", "运算符")]:
    match = re.search(r"static const _pm_op_func " + name + r"\[\] = \{(.*?)\n\};", text, re.S)
    assert match
    table = re.findall(pattern, match[1], re.S)
    assert table
    for symbol, prototype, definition in table:
        help_text = "".join(ast.literal_eval(s) for s in re.findall(quoted, definition))
        entries.append(dict(name=ast.literal_eval(symbol), prototype=ast.literal_eval(prototype),
                            help=re.sub(r"</?[^>]+>", "", help_text), group=group))
Path("app/Resources/PixelMathReference.json").write_text(json.dumps(entries, ensure_ascii=False, indent=2) + "\n")
print(f"Exported {len(entries)} original function/operator entries")
