with open('tweak/Sources/Shared/AudioEffects/AudioEffectsFiles.m', 'r', encoding='utf-8') as f:
    text = f.read()

target1 = """#import <os/lock.h>
#import "Core/SGCore.h"
#import "AudioEffects.h"
#import "AudioEffectsApply.h" """

replacement1 = """#import <os/lock.h>
#import "Core/SGCore.h"
#import "AudioEffects.h"
#import "AudioEffectsApply.h"
#import "SGDSPLiveprog.h" """

target1 = target1.strip()
replacement1 = replacement1.strip()
assert target1 in text, "target1 not found"
text = text.replace(target1, replacement1)

target2 = """    if (kind == SGDSPFileDDC) return [text containsString:@"SR_44100"] && [text containsString:@"SR_48000"];
    return [text containsString:@"@sample"];"""

replacement2 = """    if (kind == SGDSPFileDDC) return [text containsString:@"SR_44100"] && [text containsString:@"SR_48000"];
    return [text localizedCaseInsensitiveContainsString:@"@sample"] || [text localizedCaseInsensitiveContainsString:@"@init"] || [text containsString:@"spl0"] || [text containsString:@"slider"];"""

assert target2 in text, "target2 not found"
text = text.replace(target2, replacement2)

target3 = """BOOL SGDSPDeleteFile(SGDSPFileKind kind, NSString *name) {
    if (!name.length || ![name.lastPathComponent isEqualToString:name] || [name hasPrefix:@"."]) return NO;
    NSString *path = [SGDSPLibraryDirectory(kind) stringByAppendingPathComponent:name];
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:path error:&error]) {
        SGLog(@"dsp: %@ could not be deleted: %@", name, error);
        return NO;
    }
    SGLog(@"dsp: %@ deleted from the %@ library", name, libraryName(kind));
    // The effect using it lets it go (and says the file is gone).
    if ([SGDSPString(fileKey(kind)) isEqualToString:name]) SGDSPApply(SGDSPEffectOf(fileKey(kind)));
    return YES;
}"""

replacement3 = """BOOL SGDSPDeleteFile(SGDSPFileKind kind, NSString *name) {
    if (!name.length || ![name.lastPathComponent isEqualToString:name] || [name hasPrefix:@"."]) return NO;
    NSString *path = [SGDSPLibraryDirectory(kind) stringByAppendingPathComponent:name];
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:path error:&error]) {
        SGLog(@"dsp: %@ could not be deleted: %@", name, error);
        return NO;
    }
    SGLog(@"dsp: %@ deleted from the %@ library", name, libraryName(kind));
    // The effect using it lets it go (and says the file is gone).
    if ([SGDSPString(fileKey(kind)) isEqualToString:name]) SGDSPApply(SGDSPEffectOf(fileKey(kind)));
    return YES;
}

NSArray<SGDSPLiveprogSlider *> *SGDSPLiveprogCurrentSliders(void) {
    NSString *fileName = SGDSPString(SGKeyDSPLiveprogFile);
    if (!fileName.length) return @[];
    NSString *directory = SGDSPLibraryDirectory(SGDSPFileLiveprog);
    NSString *path = [directory stringByAppendingPathComponent:fileName];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return @[];
    return SGDSPLiveprogParseSliders(fileName, data.bytes);
}"""

assert target3 in text, "target3 not found"
text = text.replace(target3, replacement3)

with open('tweak/Sources/Shared/AudioEffects/AudioEffectsFiles.m', 'w', encoding='utf-8') as f:
    f.write(text)

print("Updated AudioEffectsFiles.m successfully!")
