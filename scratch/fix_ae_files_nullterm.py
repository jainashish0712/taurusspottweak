with open('tweak/Sources/Shared/AudioEffects/AudioEffectsFiles.m', 'r', encoding='utf-8') as f:
    text = f.read()

target = """NSArray<SGDSPLiveprogSlider *> *SGDSPLiveprogCurrentSliders(void) {
    NSString *fileName = SGDSPString(SGKeyDSPLiveprogFile);
    if (!fileName.length) return @[];
    NSString *directory = SGDSPLibraryDirectory(SGDSPFileLiveprog);
    NSString *path = [directory stringByAppendingPathComponent:fileName];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return @[];
    return SGDSPLiveprogParseSliders(fileName, data.bytes);
}"""

replacement = """NSArray<SGDSPLiveprogSlider *> *SGDSPLiveprogCurrentSliders(void) {
    NSString *fileName = SGDSPString(SGKeyDSPLiveprogFile);
    if (!fileName.length) return @[];
    NSString *directory = SGDSPLibraryDirectory(SGDSPFileLiveprog);
    NSString *path = [directory stringByAppendingPathComponent:fileName];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return @[];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                     ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!text.length) return @[];
    return SGDSPLiveprogParseSliders(fileName, text.UTF8String);
}"""

assert target in text, "target not found in AudioEffectsFiles.m"
text = text.replace(target, replacement)
with open('tweak/Sources/Shared/AudioEffects/AudioEffectsFiles.m', 'w', encoding='utf-8') as f:
    f.write(text)

print("Updated AudioEffectsFiles.m successfully!")
