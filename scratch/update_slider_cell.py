with open('tweak/Sources/Shared/AudioEffects/AudioEffectsPage.m', 'rb') as f:
    raw = f.read()

# Normalize to LF for matching
content = raw.decode('utf-8')
crlf_mode = b'\r\n' in raw

start_str = "// The title and the value over a slider in the accent colour, storing each step as the thumb reaches it.\n@interface SGDSPSliderCell : UITableViewCell"
end_str = "- (void)released {\n    [_slider setValue:(float)_shown animated:YES];\n}\n\n@end"

replacement = """// The title and the value over a slider in the accent colour, storing each step as the thumb reaches it.
@implementation SGDSPSliderCell {
    SGDSPRow *_row;
    NSString *_key;
    NSString *_unit;
    NSInteger _tag;
    UILabel *_title, *_value;
    SGDSPSlider *_slider;
    double _shown;
    BOOL _detents;   // few enough steps that the thumb jumps between them as it is dragged
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:identifier])) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _title = [UILabel new];
    _title.textColor = UIColor.whiteColor;
    _title.isAccessibilityElement = NO;
    _value = [UILabel new];
    _value.textColor = SGGrey();
    _value.textAlignment = NSTextAlignmentRight;
    _value.isAccessibilityElement = NO;
    _slider = [SGDSPSlider new];
    _slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.16];
    [_slider addTarget:self action:@selector(moved) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(released) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    for (UIView *view in @[_title, _value, _slider]) [self.contentView addSubview:view];
    return self;
}

- (void)showSlider:(NSString *)title key:(NSString *)key unit:(NSString *)unit tag:(NSInteger)tag {
    _key = key;
    _unit = unit ?: @"";
    _tag = tag;
    SGDSPRange range = SGDSPRangeFor(key);
    NSInteger count = range.step > 0 ? (NSInteger)lround((range.max - range.min) / range.step) : 0;
    _detents = count > 0 && count <= 24;
    _title.font = SGTitleFont();
    _value.font = tabular(SGTitleFont());
    _title.text = title;
    _slider.minimumTrackTintColor = SGGreen();
    _slider.minimumValue = (float)range.min;
    _slider.maximumValue = (float)range.max;
    _slider.spokenStep = (float)(count > 0 && count <= 40 ? range.step : snapped(key, range.min + (range.max - range.min) / 20) - range.min);
    _shown = SGDSPNumber(key);
    _slider.value = (float)_shown;
    _slider.accessibilityLabel = title;
    [self showValue];
}

- (void)showRow:(SGDSPRow *)row {
    _row = row;
    [self showSlider:row.title key:row.key unit:row.unit tag:row.tag];
}

- (void)showValue {
    if (_row) {
        _value.text = numberText(_row, _shown);
    } else {
        SGDSPRange range = SGDSPRangeFor(_key);
        double step = range.step;
        int decimals = step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3;
        if (fabs(_shown - round(_shown)) < 1e-6) decimals = 0;
        NSString *number = [NSString stringWithFormat:@"%.*f", decimals, fabs(_shown)];
        NSString *sign = number.doubleValue == 0 ? @"" : _shown < 0 ? @"−" : range.min < 0 && range.max > 0 ? @"+" : @"";
        _value.text = [NSString stringWithFormat:@"%@%@%@", sign, number, _unit ?: @""];
    }
    _slider.accessibilityValue = _value.text;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width, side = 16;
    [_value sizeToFit];
    CGFloat valueWidth = MAX(_value.bounds.size.width, 44);
    _value.frame = CGRectMake(width - side - valueWidth, 12, valueWidth, 18);
    _title.frame = CGRectMake(side, 12, CGRectGetMinX(_value.frame) - side - 8, 18);
    _slider.frame = CGRectMake(side, 36, width - 2 * side, 28);
}

- (void)moved {
    NSString *key = _row ? _row.key : _key;
    NSInteger tag = _row ? _row.tag : _tag;
    double value = snapped(key, _slider.value);
    if (_detents) _slider.value = (float)value;
    if (value == _shown) return;
    _shown = value;
    SGDSPSetNumber(key, value);
    if ([key hasPrefix:SGKeyDSPLiveprogSliderPrefix]) {
        SGDSPSetLiveprogSlider((int)tag, value);
    }
    [self showValue];
}

- (void)released {
    [_slider setValue:(float)_shown animated:YES];
}

@end"""

content_lf = content.replace('\r\n', '\n')
p1 = content_lf.find(start_str)
p2 = content_lf.find(end_str)
if p1 != -1 and p2 != -1:
    p2 += len(end_str)
    new_content_lf = content_lf[:p1] + replacement + content_lf[p2:]
    out_bytes = new_content_lf.replace('\n', '\r\n').encode('utf-8') if crlf_mode else new_content_lf.encode('utf-8')
    with open('tweak/Sources/Shared/AudioEffects/AudioEffectsPage.m', 'wb') as f:
        f.write(out_bytes)
    print("SUCCESS: AudioEffectsPage.m successfully updated!")
else:
    print(f"FAILED: p1={p1}, p2={p2}")
