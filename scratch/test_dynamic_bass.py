with open('t Dynamic bass and reverb!!!.eel', 'r', encoding='latin1') as f:
    text = f.read()

sliders = []
lines = text.splitlines()
nextSeq = 1
for line in lines:
    line_s = line.strip()
    if line_s.startswith('@'): break
    p = line_s
    if p.startswith('//'): p = p[2:].strip()
    if ':' not in p or '<' not in p or '>' not in p: continue
    colon = p.find(':')
    lt = p.find('<')
    gt = p.rfind('>')
    if not (colon < lt and lt < gt): continue
    idStr = p[:colon].strip()
    rest = p[colon+1:]
    lt_in_rest = rest.find('<')
    gt_in_rest = rest.rfind('>')
    num = 0
    alias = None
    varName = None
    if idStr.startswith('slider') and idStr[6:].isdigit():
        num = int(idStr[6:])
        alias = f'slider{num}'
        eq = rest.find('=')
        if eq != -1 and eq < lt_in_rest:
            varName = rest[:eq].strip()
            rest = rest[eq+1:]
            lt_in_rest = rest.find('<')
            gt_in_rest = rest.rfind('>')
        else:
            varName = f'slider{num}'
            alias = None
    elif idStr.isidentifier():
        varName = idStr
        num = nextSeq
        alias = f'slider{num}'
        nextSeq += 1
    else:
        continue
    defVal = float(rest[:lt_in_rest].strip())
    boundsStr = rest[lt_in_rest+1:gt_in_rest].strip()
    label = rest[gt_in_rest+1:].strip() or varName
    opts = None
    if '{' in boundsStr and boundsStr.endswith('}'):
        b_part, opt_part = boundsStr[:-1].split('{', 1)
        opts = [o.strip() for o in opt_part.split(',')]
        parts = [b.strip() for b in b_part.split(',') if b.strip()]
    else:
        parts = [b.strip() for b in boundsStr.split(',') if b.strip()]
    minVal = float(parts[0])
    maxVal = float(parts[1])
    stepVal = float(parts[2]) if len(parts) > 2 else 1.0
    sliders.append({
        'index': num,
        'var': varName,
        'alias': alias,
        'default': defVal,
        'min': minVal,
        'max': maxVal,
        'step': stepVal,
        'opts': opts,
        'label': label,
        'key': f'spotifyglass.dsp.liveprog.slider.t Dynamic bass and reverb!!!.{num}'
    })
    nextSeq = max(nextSeq, num + 1)

print(f'Total sliders parsed from t Dynamic bass and reverb!!!.eel: {len(sliders)}')
for s in sliders:
    print(f"  [{s['index']}] {s['label']}: def={s['default']}, min={s['min']}, max={s['max']}, step={s['step']} (var={s['var']})")
assert len(sliders) == 7, 'Expected 7 sliders!'
print('ALL 7 SLIDERS VERIFIED!')
