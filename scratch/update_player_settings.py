path = r'D:\apps\taurus\tweak\Sources\Redesigned\Player\PlayerSettings.m'
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()

# Add import
import_target = '#import "Player.h"'
import_repl = '#import "Player.h"\n#import "SGRStemsViewController.h"'
if import_target in text and '#import "SGRStemsViewController.h"' not in text:
    text = text.replace(import_target, import_repl, 1)

# Add section
section_target = 'SGNotedSection(@"Controls",'
section_repl = '''SGNotedSection(@"Stem Separation & DSP", @[
            SGActionRow(@"Stem Separation & Nagare DSP", @"Open 4-stem mixer, upscaler and real-time DSP suite", ^{
                [SGRStemsViewController presentFromCurrentPlayer];
            })
        ], @"Isolate Vocals, Drums, Bass, and Instruments with real-time HPSS and spectral processing."),
        SGNotedSection(@"Controls",'''

if section_target in text:
    text = text.replace(section_target, section_repl, 1)

with open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(text)
print('Updated PlayerSettings.m')
