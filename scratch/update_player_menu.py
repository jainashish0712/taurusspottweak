path = r'D:\apps\taurus\tweak\Sources\Redesigned\Player\PlayerMenu.m'
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()

target = """static NSArray<UIMenuElement *> *playerItems(void) {
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    UIAction *sound = soundMenu();
    if (sound) [items addObject:sound];
    [items addObject:lockScreenStyleMenu()];
    [items addObject:backgroundStyleMenu()];
    return items;
}"""

replacement = """static UIAction *stemsMenuItem(void) {
    return [UIAction actionWithTitle:@"Stem Separation & DSP"
                               image:symbol(@"waveform.badge.magnifyingglass")
                          identifier:nil
                             handler:^(UIAction *action) {
        [SGRStemsViewController presentFromCurrentPlayer];
    }];
}

static NSArray<UIMenuElement *> *playerItems(void) {
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    UIAction *sound = soundMenu();
    if (sound) [items addObject:sound];
    [items addObject:stemsMenuItem()];
    [items addObject:lockScreenStyleMenu()];
    [items addObject:backgroundStyleMenu()];
    return items;
}"""

if target in text:
    text = text.replace(target, replacement, 1)
else:
    target_crlf = target.replace('\n', '\r\n')
    replacement_crlf = replacement.replace('\n', '\r\n')
    text = text.replace(target_crlf, replacement_crlf, 1)

with open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(text)
print('Updated PlayerMenu.m')
