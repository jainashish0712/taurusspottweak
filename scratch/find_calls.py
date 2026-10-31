import re

with open('t Dynamic bass and reverb!!!.eel', 'r') as f:
    lines = f.readlines()

user_funcs = set()
for line in lines:
    m = re.match(r'^\s*function\s+([A-Za-z0-9_]+)', line)
    if m:
        user_funcs.add(m.group(1))

calls = set()
for line_no, line in enumerate(lines, 1):
    # strip comments
    c = line.split('//')[0]
    for m in re.finditer(r'([A-Za-z0-9_.]+)\s*\(', c):
        func = m.group(1)
        if func not in ('if', 'while', 'loop') and not func.startswith('function'):
            calls.add((func, line_no))

print("User defined functions:", user_funcs)
print("\nAll function calls:")
for func, line_no in sorted(calls, key=lambda x: x[1]):
    print(f"Line {line_no:3d}: {func}")
