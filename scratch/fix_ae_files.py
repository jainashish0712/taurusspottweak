with open('tweak/Sources/Shared/AudioEffects/AudioEffectsFiles.m', 'r', encoding='utf-8') as f:
    text = f.read()

target1 = """#import "AudioEffectsApply.h"\n#import "SGDSPLiveprog.h\""""
target2 = """#import "AudioEffectsApply.h"\r\n#import "SGDSPLiveprog.h\""""
replacement = """#import "AudioEffectsApply.h\""""

if target1 in text:
    text = text.replace(target1, replacement)
elif target2 in text:
    text = text.replace(target2, replacement)
else:
    raise AssertionError("target not found in AudioEffectsFiles.m")

with open('tweak/Sources/Shared/AudioEffects/AudioEffectsFiles.m', 'w', encoding='utf-8') as f:
    f.write(text)

print("Updated AudioEffectsFiles.m successfully!")
