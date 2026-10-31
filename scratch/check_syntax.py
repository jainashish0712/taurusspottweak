import os, sys

files = [
    'vendor/audio/wdl/eel2/nseel-eval.c',
    'vendor/audio/wdl/eel2/nseel-compiler.c',
    'vendor/audio/eel2-parser/nseel-parse.c',
    'tweak/Sources/Shared/AudioEffects/SGDSPLiveprog.m',
    'tweak/Sources/Shared/AudioEffects/SGDSPEffects.h',
    'tweak/Sources/Shared/AudioEffects/SGDSPEngine.h',
    'tweak/Sources/Shared/AudioEffects/SGDSPEngine.m',
    'tweak/Sources/Shared/AudioEffects/AudioEffects.h',
    'tweak/Sources/Shared/AudioEffects/AudioEffectsSettings.m',
    'tweak/Sources/Shared/AudioEffects/AudioEffectsFiles.m',
    'tweak/Sources/Shared/AudioEffects/AudioEffects.x',
    'tweak/Sources/Shared/AudioEffects/AudioEffectsPage.m'
]

def check_file(path):
    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
    
    stack = []
    in_line_comment = False
    in_block_comment = False
    in_str = None
    i = 0
    line = 1
    col = 1
    while i < len(content):
        c = content[i]
        if c == '\n':
            line += 1
            col = 1
            in_line_comment = False
            i += 1
            continue
        col += 1
        if in_line_comment:
            i += 1
            continue
        if in_block_comment:
            if c == '*' and i + 1 < len(content) and content[i+1] == '/':
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == in_str:
                in_str = None
            i += 1
            continue
        if c == '/' and i + 1 < len(content):
            if content[i+1] == '/':
                in_line_comment = True
                i += 2
                continue
            if content[i+1] == '*':
                in_block_comment = True
                i += 2
                continue
        if c in ('"', "'"):
            in_str = c
            i += 1
            continue
        if c in '{[(':
            stack.append((c, line, col))
        elif c in '}])':
            if not stack:
                print(f"Error: unmatched {c} at {path}:{line}:{col}")
                return False
            top, tl, tc = stack.pop()
            expected = {'{': '}', '[': ']', '(': ')'}[top]
            if c != expected:
                print(f"Error: mismatched {top} from line {tl} with {c} at {path}:{line}:{col}")
                return False
        i += 1
    if stack:
        print(f"Error: unclosed {stack[-1]} in {path}")
        return False
    return True

all_ok = True
for f in files:
    if not check_file(f):
        all_ok = False
    else:
        print(f"OK: {f}")

if all_ok:
    print("ALL FILES HAVE BALANCED SYNTAX!")
else:
    sys.exit(1)
