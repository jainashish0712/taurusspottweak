with open('tweak/Sources/Shared/AudioEffects/AudioEffects.h', 'r', encoding='utf-8') as f:
    text = f.read()

target1 = """#define SGKeyDSPLiveprog                @"spotifyglass.dsp.liveprog"
#define SGKeyDSPLiveprogFile            @"spotifyglass.dsp.liveprog.file" """

replacement1 = """#define SGKeyDSPLiveprog                @"spotifyglass.dsp.liveprog"
#define SGKeyDSPLiveprogFile            @"spotifyglass.dsp.liveprog.file"
#define SGKeyDSPLiveprogSliderPrefix    @"spotifyglass.dsp.liveprog.slider" """

# strip trailing space
target1 = target1.strip()
replacement1 = replacement1.strip()

assert target1 in text, "target1 not found"
text = text.replace(target1, replacement1)

target2 = "SGDSPRange SGDSPRangeFor(NSString *key);"
replacement2 = """SGDSPRange SGDSPRangeFor(NSString *key);
void SGDSPRegisterRange(NSString *key, SGDSPRange range);

@class SGDSPLiveprogSlider;
NSArray<SGDSPLiveprogSlider *> *SGDSPLiveprogCurrentSliders(void);
void SGDSPSetLiveprogSlider(int index, double value);"""

assert target2 in text, "target2 not found"
text = text.replace(target2, replacement2)

with open('tweak/Sources/Shared/AudioEffects/AudioEffects.h', 'w', encoding='utf-8') as f:
    f.write(text)

print("Updated AudioEffects.h successfully!")
