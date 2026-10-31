with open('t Dynamic bass and reverb!!!.eel', 'r') as f:
    content = f.read()
import re
m = re.search(r'importFLTFromStr\("([^"]+)"', content)
if m:
    nums = [float(x) for x in m.group(1).split(',')]
    print(f'Total numbers parsed: {len(nums)}')
    print(f'First 5: {nums[:5]}')
    print(f'Last 5: {nums[-5:]}')
else:
    print('Pattern not matched')
