with open('tweak/Sources/Shared/AudioEffects/AudioEffectsPage.m', 'r', encoding='utf-8') as f:
    text = f.read()

target1 = """@property (nonatomic, copy) NSArray<NSString *> *names;   // a choice's, or what a slider's steps read as
@property (nonatomic) double scale;                        // what a slider's stored number is shown times"""

replacement1 = """@property (nonatomic, copy) NSArray<NSString *> *names;   // a choice's, or what a slider's steps read as
@property (nonatomic) double scale;                        // what a slider's stored number is shown times
@property (nonatomic) NSInteger tag;"""

assert target1 in text, "target1 not found"
text = text.replace(target1, replacement1)

target2 = """        effect(SGKeyDSPLiveprog, @"Liveprog", @"Effects written as EEL scripts", @"chevron.left.forwardslash.chevron.right", @[
            fileRow(@"Script", SGDSPFileLiveprog),
        ]),"""

replacement2 = """        effect(SGKeyDSPLiveprog, @"Liveprog", @"Effects written as EEL scripts", @"chevron.left.forwardslash.chevron.right", liveprogRows()),"""

assert target2 in text, "target2 not found"
text = text.replace(target2, replacement2)

target3 = """static SGDSPEffect *effect(NSString *key, NSString *title, NSString *subtitle, NSString *symbol, NSArray<SGDSPRow *> *rows) {"""

replacement3 = """static NSArray<SGDSPRow *> *liveprogRows(void) {
    NSMutableArray<SGDSPRow *> *rows = [NSMutableArray arrayWithObject:fileRow(@"Script", SGDSPFileLiveprog)];
    NSArray<SGDSPLiveprogSlider *> *sliders = SGDSPLiveprogCurrentSliders();
    for (SGDSPLiveprogSlider *s in sliders) {
        if (s.options.count > 0) {
            SGDSPRow *r = choice(s.label, s.key, s.options);
            r.tag = s.index;
            [rows addObject:r];
        } else {
            SGDSPRow *r = slider(s.label, s.key, @"");
            r.tag = s.index;
            [rows addObject:r];
        }
    }
    return rows;
}

static SGDSPEffect *effect(NSString *key, NSString *title, NSString *subtitle, NSString *symbol, NSArray<SGDSPRow *> *rows) {"""

assert target3 in text, "target3 not found"
text = text.replace(target3, replacement3)

target4 = """- (void)readState {
    [_open removeAllObjects];
    [_errors removeAllObjects];
    for (SGDSPEffect *e in _effects) {
        if (!e.key || SGDSPSwitch(e.key)) [_open addObject:e.key ?: @""];
        if (e.key && SGDSPSwitch(e.key) && [reportingEffects() containsObject:e.key]) _errors[e.key] = SGDSPError(e.key);
    }
}"""

replacement4 = """- (void)readState {
    [_open removeAllObjects];
    [_errors removeAllObjects];
    for (SGDSPEffect *e in _effects) {
        if ([e.key isEqualToString:SGKeyDSPLiveprog]) e.rows = liveprogRows();
        if (!e.key || SGDSPSwitch(e.key)) [_open addObject:e.key ?: @""];
        if (e.key && SGDSPSwitch(e.key) && [reportingEffects() containsObject:e.key]) _errors[e.key] = SGDSPError(e.key);
    }
}"""

assert target4 in text, "target4 not found"
text = text.replace(target4, replacement4)

target5 = """- (void)moved {
    double value = snapped(_row.key, _slider.value);
    if (_detents) _slider.value = (float)value;
    if (value == _shown) return;
    _shown = value;
    SGDSPSetNumber(_row.key, value);
    [self showValue];
}"""

replacement5 = """- (void)moved {
    double value = snapped(_row.key, _slider.value);
    if (_detents) _slider.value = (float)value;
    if (value == _shown) return;
    _shown = value;
    SGDSPSetNumber(_row.key, value);
    if ([_row.key hasPrefix:SGKeyDSPLiveprogSliderPrefix]) {
        SGDSPSetLiveprogSlider((int)_row.tag, value);
    }
    [self showValue];
}"""

assert target5 in text, "target5 not found"
text = text.replace(target5, replacement5)

target6 = """- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    SGDSPSetNumber(_row.key, path.row);
    [table reloadRowsAtIndexPaths:table.indexPathsForVisibleRows withRowAnimation:UITableViewRowAnimationNone];
}"""

replacement6 = """- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    SGDSPSetNumber(_row.key, path.row);
    if ([_row.key hasPrefix:SGKeyDSPLiveprogSliderPrefix]) {
        SGDSPSetLiveprogSlider((int)_row.tag, path.row);
    }
    [table reloadRowsAtIndexPaths:table.indexPathsForVisibleRows withRowAnimation:UITableViewRowAnimationNone];
}"""

assert target6 in text, "target6 not found"
text = text.replace(target6, replacement6)

target7 = """    int decimals = step >= 1 ? 0 : step >= 0.1 ? 1 : 2;"""
replacement7 = """    int decimals = step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3;"""
assert target7 in text, "target7 not found"
text = text.replace(target7, replacement7)

with open('tweak/Sources/Shared/AudioEffects/AudioEffectsPage.m', 'w', encoding='utf-8') as f:
    f.write(text)

print("Updated AudioEffectsPage.m successfully!")
