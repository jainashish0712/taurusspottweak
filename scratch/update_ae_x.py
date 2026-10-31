with open('tweak/Sources/Shared/AudioEffects/AudioEffects.x', 'r', encoding='utf-8') as f:
    text = f.read()

target1 = """        if (on && !path) {
            SGDSPEngineSetLiveprog(engine, false, NULL, error, sizeof error);
            return;
        }
        NSData *script = on ? textFile(path) : nil;
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        ok = SGDSPEngineSetLiveprog(engine, on, script.bytes, error, sizeof error);"""

replacement1 = """        if (on && !path) {
            SGDSPEngineSetLiveprog(engine, false, NULL, NULL, error, sizeof error);
            return;
        }
        NSData *script = on ? textFile(path) : nil;
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        ok = SGDSPEngineSetLiveprog(engine, on, script.bytes, path.lastPathComponent.UTF8String, error, sizeof error);"""

assert target1 in text, "target1 not found in AudioEffects.x"
text = text.replace(target1, replacement1)

# Add SGDSPSetLiveprogSlider before end of file or after applyEffect
target2 = """void SGDSPApply(NSString *effect) {"""
replacement2 = """void SGDSPSetLiveprogSlider(int index, double value) {
    if (sg_engine) SGDSPEngineSetLiveprogSlider(sg_engine, index, value);
}

void SGDSPApply(NSString *effect) {"""

assert target2 in text, "target2 not found in AudioEffects.x"
text = text.replace(target2, replacement2)

with open('tweak/Sources/Shared/AudioEffects/AudioEffects.x', 'w', encoding='utf-8') as f:
    f.write(text)

print("Updated AudioEffects.x successfully!")
