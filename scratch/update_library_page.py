with open('tweak/Sources/Shared/AudioEffects/AudioEffectsLibraryPage.m', 'rb') as f:
    raw = f.read()

content = raw.decode('utf-8')
crlf_mode = b'\r\n' in raw

start_marker = "@implementation SGDSPFilesPage {"
end_marker = "    [self presentViewController:picker animated:YES completion:nil];\n}"

replacement = """@implementation SGDSPFilesPage {
    SGDSPFileKind _kind;
    NSArray<NSString *> *_files;
    NSArray<SGDSPLiveprogSlider *> *_sliders;
    UIView *_footer;
}

- (instancetype)initWithKind:(SGDSPFileKind)kind {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _kind = kind;
    self.errorKey = switchKeyOf(kind);
    self.title = kind == SGDSPFileImpulseResponse ? @"Impulse responses" : kind == SGDSPFileDDC ? @"DDC files" : @"Scripts";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _footer = SGNote(@"Choosing a file uses it straight away. Swipe left on one to delete it.");
    self.tableView.tableFooterView = _footer;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _footer, 16, 24);
}

- (void)viewWillAppear:(BOOL)animated {
    _files = SGDSPLibraryFiles(_kind);
    if (_kind == SGDSPFileLiveprog) _sliders = SGDSPLiveprogCurrentSliders();
    [super viewWillAppear:animated];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    if (_kind == SGDSPFileLiveprog && _sliders.count > 0) return 4;
    return 3;
}

- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    if (_kind == SGDSPFileLiveprog && _sliders.count > 0 && section == 2) {
        return @"Parameters";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return [self errorRows];
    if (section == 1) return MAX((NSInteger)_files.count, 1);
    if (_kind == SGDSPFileLiveprog && _sliders.count > 0) {
        if (section == 2) return (NSInteger)_sliders.count;
        if (section == 3) return 1;
    }
    return 1;
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    if (_kind == SGDSPFileLiveprog && _sliders.count > 0 && path.section == 2) {
        return 74;
    }
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 0) return [self errorCellIn:table];
    if (_kind == SGDSPFileLiveprog && _sliders.count > 0 && path.section == 2) {
        SGDSPLiveprogSlider *slider = _sliders[(NSUInteger)path.row];
        SGDSPSliderCell *cell = [table dequeueReusableCellWithIdentifier:@"slider"]
            ?: [[SGDSPSliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"slider"];
        cell.backgroundColor = SGCardBackground();
        [cell showSlider:slider.label key:slider.key unit:@"" tag:slider.index];
        return cell;
    }
    BOOL isImport = (_kind == SGDSPFileLiveprog && _sliders.count > 0) ? (path.section == 3) : (path.section == 2);
    if (isImport) {
        NSString *subtitle = [NSString stringWithFormat:@"A %@ file from Files", extensionList(_kind)];
        return tiledCell(table, @"Import file…", subtitle, @"square.and.arrow.down", nil);
    }
    UITableViewCell *cell = SGDequeueCell(table, @"file");
    if (!_files.count) {
        SGFillCell(cell, @"No files yet", nil, SGGrey(), nil);
        cell.accessibilityTraits = UIAccessibilityTraitNone;
        return cell;
    }
    NSString *name = _files[(NSUInteger)path.row];
    BOOL chosen = [name isEqualToString:SGDSPString(fileKeyOf(_kind))];
    SGFillCell(cell, name, nil, nil, nil);
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (chosen) {
        UIImageView *tick = SGSymbolView(@"checkmark", 13, UIImageSymbolWeightSemibold, 16);
        tick.tintColor = SGGreen();
        cell.accessoryView = tick;
    }
    cell.accessibilityTraits = chosen ? UIAccessibilityTraitButton | UIAccessibilityTraitSelected : UIAccessibilityTraitButton;
    return cell;
}

- (BOOL)tableView:(UITableView *)table shouldHighlightRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 0) return NO;
    if (_kind == SGDSPFileLiveprog && _sliders.count > 0 && path.section == 2) return NO;
    BOOL isImport = (_kind == SGDSPFileLiveprog && _sliders.count > 0) ? (path.section == 3) : (path.section == 2);
    return isImport || (path.section == 1 && _files.count);
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    BOOL isImport = (_kind == SGDSPFileLiveprog && _sliders.count > 0) ? (path.section == 3) : (path.section == 2);
    if (isImport) {
        [self pickFile];
        return;
    }
    if (path.section != 1 || !_files.count) return;
    SGDSPSetString(fileKeyOf(_kind), _files[(NSUInteger)path.row]);
    if (_kind == SGDSPFileLiveprog) {
        _sliders = SGDSPLiveprogCurrentSliders();
        [self.tableView reloadData];
    } else {
        [table reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)table trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section != 1 || !_files.count) return nil;
    NSString *name = _files[(NSUInteger)path.row];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
            [self deleteFile:name at:path];
            done(YES);
        }];
    delete.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

// The chosen file going leaves the effect with none, rather than naming a file that is not there.
- (void)deleteFile:(NSString *)name at:(NSIndexPath *)path {
    if (!SGDSPDeleteFile(_kind, name)) {
        showAlert(self, @"Could not delete the file", nil);
        return;
    }
    if ([name isEqualToString:SGDSPString(fileKeyOf(_kind))]) {
        SGDSPSetString(fileKeyOf(_kind), @"");
        if (_kind == SGDSPFileLiveprog) _sliders = @[];
    }
    _files = SGDSPLibraryFiles(_kind);
    [self.tableView reloadData];
}

- (void)pickFile {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}"""

content_lf = content.replace('\r\n', '\n')
p1 = content_lf.find(start_marker)
p2 = content_lf.find(end_marker)
if p1 != -1 and p2 != -1:
    p2 += len(end_marker)
    new_content_lf = content_lf[:p1] + replacement + content_lf[p2:]
    out_bytes = new_content_lf.replace('\n', '\r\n').encode('utf-8') if crlf_mode else new_content_lf.encode('utf-8')
    with open('tweak/Sources/Shared/AudioEffects/AudioEffectsLibraryPage.m', 'wb') as f:
        f.write(out_bytes)
    print("SUCCESS: AudioEffectsLibraryPage.m successfully updated!")
else:
    print(f"FAILED: p1={p1}, p2={p2}")
