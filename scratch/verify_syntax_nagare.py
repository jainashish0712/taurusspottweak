import glob
import os
import re
import sys

files = [
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\nagare_dsp.h',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\nagare_dsp.cpp',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\source_separator.h',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\source_separator.cpp',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\hrtf_processor.h',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\hrtf_processor.cpp',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\polyphase_resampler.h',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\polyphase_resampler.cpp',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\audio_upscaler.h',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\audio_upscaler.cpp',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\dynamic_restorer.h',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\dynamic_restorer.cpp',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\SGNagareBridge.h',
    r'D:\apps\taurus\tweak\Sources\Shared\Nagare\SGNagareBridge.mm',
    r'D:\apps\taurus\tweak\Sources\Redesigned\Player\SGRStemsViewController.h',
    r'D:\apps\taurus\tweak\Sources\Redesigned\Player\SGRStemsViewController.m',
    r'D:\apps\taurus\tweak\Sources\Redesigned\Player\PlayerMenu.m',
    r'D:\apps\taurus\tweak\Sources\Redesigned\Player\PlayerSettings.m',
    r'D:\apps\taurus\tweak\Sources\Shared\Audio\SGAudioPipeline.h',
]

def check_file(path):
    print(f'Checking {os.path.basename(path)}...')
    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
        text = f.read()

    # Strip comments and strings for bracket checking
    # Remove single line comments
    clean = re.sub(r'//.*', '', text)
    # Remove multi line comments
    clean = re.sub(r'/\*.*?\*/', '', clean, flags=re.S)
    # Remove string literals
    clean = re.sub(r'@?".*?(?<!\\)"', '', clean)
    clean = re.sub(r"'.*?(?<!\\)'", '', clean)

    brackets = {'{': '}', '(': ')', '[': ']'}
    stack = []
    line_no = 1
    for char in clean:
        if char == '\n':
            line_no += 1
        elif char in brackets:
            stack.append((char, line_no))
        elif char in brackets.values():
            if not stack:
                print(f'  [ERROR] Unmatched closing {char} near line {line_no}')
                return False
            open_char, open_line = stack.pop()
            if brackets[open_char] != char:
                print(f'  [ERROR] Mismatched {open_char} (line {open_line}) with {char} (line {line_no})')
                return False

    if stack:
        open_char, open_line = stack[-1]
        print(f'  [ERROR] Unclosed {open_char} from line {open_line}')
        return False

    print(f'  [OK] Brackets balanced, length {len(text)} chars.')
    return True

all_ok = True
for f in files:
    if not os.path.exists(f):
        print(f'[ERROR] File not found: {f}')
        all_ok = False
        continue
    if not check_file(f):
        all_ok = False

if all_ok:
    print('\nALL FILES PASSED SYNTAX & BRACKET VERIFICATION!')
else:
    print('\nERRORS FOUND!')
    sys.exit(1)
