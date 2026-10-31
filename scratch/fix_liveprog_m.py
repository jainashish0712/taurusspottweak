with open('tweak/Sources/Shared/AudioEffects/SGDSPLiveprog.m', 'r', encoding='utf-8') as f:
    text = f.read()

target1 = """#import "SGDSPLiveprog.h"\n#import "AudioEffects.h\""""
target2 = """#import "SGDSPLiveprog.h"\r\n#import "AudioEffects.h\""""
replacement = """#import "AudioEffects.h"\n#import "SGDSPEffects.h\""""

if target1 in text:
    text = text.replace(target1, replacement)
elif target2 in text:
    text = text.replace(target2, replacement)
else:
    raise AssertionError("target not found in SGDSPLiveprog.m")

with open('tweak/Sources/Shared/AudioEffects/SGDSPLiveprog.m', 'w', encoding='utf-8') as f:
    f.write(text)

print("Updated SGDSPLiveprog.m successfully!")
