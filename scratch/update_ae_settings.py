with open('tweak/Sources/Shared/AudioEffects/AudioEffectsSettings.m', 'r', encoding='utf-8') as f:
    text = f.read()

target1 = """#import "Core/SGCore.h"
#import "AudioEffects.h"
#import "AudioEffectsApply.h" """

replacement1 = """#import <os/lock.h>
#import "Core/SGCore.h"
#import "AudioEffects.h"
#import "AudioEffectsApply.h" """

target1 = target1.strip()
replacement1 = replacement1.strip()

assert target1 in text, "target1 not found"
text = text.replace(target1, replacement1)

target2 = """SGDSPRange SGDSPRangeFor(NSString *key) {
    for (size_t i = 0; i < sizeof kNumbers / sizeof *kNumbers; i++) {
        if ([kNumbers[i].key isEqualToString:key]) return kNumbers[i].range;
    }
    return (SGDSPRange){0, 1, 0, 0};
}"""

replacement2 = """static NSMutableDictionary<NSString *, NSValue *> *sg_dynamicRanges;
static os_unfair_lock sg_rangeLock = OS_UNFAIR_LOCK_INIT;

void SGDSPRegisterRange(NSString *key, SGDSPRange range) {
    if (!key) return;
    os_unfair_lock_lock(&sg_rangeLock);
    if (!sg_dynamicRanges) sg_dynamicRanges = [NSMutableDictionary new];
    sg_dynamicRanges[key] = [NSValue valueWithBytes:&range objCType:@encode(SGDSPRange)];
    os_unfair_lock_unlock(&sg_rangeLock);
}

SGDSPRange SGDSPRangeFor(NSString *key) {
    for (size_t i = 0; i < sizeof kNumbers / sizeof *kNumbers; i++) {
        if ([kNumbers[i].key isEqualToString:key]) return kNumbers[i].range;
    }
    if (key) {
        os_unfair_lock_lock(&sg_rangeLock);
        NSValue *val = sg_dynamicRanges[key];
        os_unfair_lock_unlock(&sg_rangeLock);
        if (val) {
            SGDSPRange r;
            [val getValue:&r];
            return r;
        }
    }
    return (SGDSPRange){0, 1, 0, 0};
}"""

assert target2 in text, "target2 not found"
text = text.replace(target2, replacement2)

with open('tweak/Sources/Shared/AudioEffects/AudioEffectsSettings.m', 'w', encoding='utf-8') as f:
    f.write(text)

print("Updated AudioEffectsSettings.m successfully!")
