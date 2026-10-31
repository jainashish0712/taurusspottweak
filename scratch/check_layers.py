import os, re, sys

sources = 'tweak/Sources'
rules = [
    ('Core', r'Settings|Shared|Native|Redesigned|App'),
    ('Headers', r'Core|Settings|Shared|Native|Redesigned|App'),
    ('Diagnostics', r'Settings|Shared|Native|Redesigned|App'),
    ('Settings', r'Shared|Native|Redesigned|App'),
    ('Shared', r'Native|Redesigned|App'),
    ('Native', r'Redesigned|App'),
    ('Redesigned', r'Native|App'),
]

status = 0
for layer, pattern in rules:
    layer_dir = os.path.join(sources, layer)
    if not os.path.exists(layer_dir):
        continue
    regex = re.compile(r'#import\s+["<](' + pattern + r')/')
    for root, _, files in os.walk(layer_dir):
        for f in files:
            if f.endswith(('.x', '.m', '.h', '.swift')):
                path = os.path.join(root, f)
                with open(path, 'r', encoding='utf-8', errors='ignore') as fp:
                    for i, line in enumerate(fp, 1):
                        if regex.search(line):
                            print(f'{path}:{i}: forbidden import in {layer}: {line.strip()}')
                            status = 1

if status == 0:
    print('ALL LAYER CHECKS PASSED!')
sys.exit(status)
