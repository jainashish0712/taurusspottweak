with open('tweak/Sources/Shared/AudioEffects/AudioEffectsPage.m', 'r', encoding='utf-8') as f:
    text = f.read()

target = """- (void)effectToggled:(UISwitch *)toggle {
    NSInteger section = toggle.tag;
    SGDSPEffect *e = [self effectIn:section];
    if (!e.key) return;
    SGDSPSetSwitch(e.key, toggle.on);"""

replacement = """- (void)effectToggled:(UISwitch *)toggle {
    NSInteger section = toggle.tag;
    SGDSPEffect *e = [self effectIn:section];
    if (!e.key) return;
    if ([e.key isEqualToString:SGKeyDSPLiveprog]) e.rows = liveprogRows();
    SGDSPSetSwitch(e.key, toggle.on);"""

assert target in text, "target not found in AudioEffectsPage.m"
text = text.replace(target, replacement)
with open('tweak/Sources/Shared/AudioEffects/AudioEffectsPage.m', 'w', encoding='utf-8') as f:
    f.write(text)

print("Updated AudioEffectsPage.m successfully!")
