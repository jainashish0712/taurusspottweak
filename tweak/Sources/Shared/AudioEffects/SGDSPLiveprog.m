#import "SGDSPLiveprog.h"
#import "AudioEffects.h"
#import <ctype.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import "ns-eel.h"

@implementation SGDSPLiveprogSlider
@end

// A script's memory, all of it given up front: past it, reads and writes land in EEL2's spare slot.
enum { kMemory = 1 << 20 };

typedef enum { SectionInit, SectionSlider, SectionBlock, SectionSample, SectionCount } Section;

struct SGDSPLiveprog {
    NSEEL_VMCTX vm;
    NSEEL_CODEHANDLE code[SectionCount];
    EEL_F *spl0, *spl1, *samplesblock;
    void *gram;
    NSArray<SGDSPLiveprogSlider *> *sliders;
    char **strings;
    int stringCount;
    int stringCap;
};

static pthread_mutex_t sg_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(pthread_t) sg_renderThread;

static bool rendering(void) {
    return pthread_equal(pthread_self(), atomic_load_explicit(&sg_renderThread, memory_order_relaxed));
}

__attribute__((visibility("hidden"))) void NSEEL_HOSTSTUB_EnterMutex(void) {
    if (!rendering()) pthread_mutex_lock(&sg_lock);
}

__attribute__((visibility("hidden"))) void NSEEL_HOSTSTUB_LeaveMutex(void) {
    if (!rendering()) pthread_mutex_unlock(&sg_lock);
}

static void *gmemCalloc(size_t count, size_t size) {
    return rendering() ? NULL : calloc(count, size);
}

static void start(void) {
    nseel_gmem_calloc = gmemCalloc;
    NSEEL_init();
}

static void copyError(char *error, size_t size, const char *text) {
    if (error && size) snprintf(error, size, "%s", text);
}

static EEL_F onString(void *caller_this, struct eelStringSegmentRec *list) {
    SGDSPLiveprog *lp = (SGDSPLiveprog *)caller_this;
    if (!lp) return 0;
    int len = nseel_stringsegments_tobuf(NULL, 0, list);
    if (len < 0) len = 0;
    char *buf = malloc((size_t)len + 1);
    if (!buf) return 0;
    nseel_stringsegments_tobuf(buf, len + 1, list);
    buf[len] = 0;
    for (int i = 0; i < lp->stringCount; i++) {
        if (!strcmp(lp->strings[i], buf)) {
            free(buf);
            return (EEL_F)i;
        }
    }
    if (lp->stringCount >= lp->stringCap) {
        int newCap = lp->stringCap ? lp->stringCap * 2 : 16;
        char **newStrings = realloc(lp->strings, (size_t)newCap * sizeof(char *));
        if (!newStrings) { free(buf); return 0; }
        lp->strings = newStrings;
        lp->stringCap = newCap;
    }
    int id = lp->stringCount++;
    lp->strings[id] = buf;
    return (EEL_F)id;
}

static EEL_F onNamedString(void *caller_this, const char *name) {
    SGDSPLiveprog *lp = (SGDSPLiveprog *)caller_this;
    if (!lp) return 0;
    if (!name) name = "";
    for (int i = 0; i < lp->stringCount; i++) {
        if (!strcmp(lp->strings[i], name)) return (EEL_F)i;
    }
    if (lp->stringCount >= lp->stringCap) {
        int newCap = lp->stringCap ? lp->stringCap * 2 : 16;
        char **newStrings = realloc(lp->strings, (size_t)newCap * sizeof(char *));
        if (!newStrings) return 0;
        lp->strings = newStrings;
        lp->stringCap = newCap;
    }
    int id = lp->stringCount++;
    lp->strings[id] = strdup(name);
    return (EEL_F)id;
}

static bool hasCode(const char *p, const char *end) {
    if (!p) return false;
    while (p < end) {
        while (p < end && ((unsigned char)*p <= ' ' || *p == ';')) p++;
        if (p >= end) return false;
        if (*p == '/' && p + 1 < end) {
            if (p[1] == '/') {
                p += 2;
                while (p < end && *p != '\n') p++;
                continue;
            } else if (p[1] == '*') {
                p += 2;
                while (p + 1 < end && !(p[0] == '*' && p[1] == '/')) p++;
                if (p + 1 < end) p += 2;
                continue;
            }
        }
        return true;
    }
    return false;
}

NSArray<SGDSPLiveprogSlider *> *SGDSPLiveprogParseSliders(NSString *scriptName, const char *script) {
    if (!script) return @[];
    NSString *cleanName = scriptName.lastPathComponent.stringByDeletingPathExtension ?: @"default";
    NSMutableArray<SGDSPLiveprogSlider *> *sliders = [NSMutableArray array];
    NSInteger nextSequential = 1;

    for (const char *line = script; *line;) {
        const char *end = strchr(line, '\n');
        if (!end) end = line + strlen(line);
        const char *p = line;
        while (p < end && (*p == ' ' || *p == '\t')) p++;

        // Stop if a section marker like @init or @sample begins
        if (*p == '@') break;

        bool isComment = false;
        if (p + 1 < end && p[0] == '/' && p[1] == '/') {
            isComment = true;
            p += 2;
            while (p < end && (*p == ' ' || *p == '\t')) p++;
        }

        // Check for slider declaration: sliderN:... or name:...
        NSInteger num = 0;
        char varName[64] = {0};
        char aliasName[64] = {0};

        if (!strncmp(p, "slider", 6) && isdigit((unsigned char)p[6])) {
            const char *digits = p + 6;
            while (digits < end && isdigit((unsigned char)*digits)) num = num * 10 + (*digits++ - '0');
            if (digits < end && *digits == ':') {
                snprintf(aliasName, sizeof aliasName, "slider%ld", (long)num);
                p = digits + 1;
                while (p < end && (*p == ' ' || *p == '\t')) p++;
                // Check for optional var= after sliderN:
                const char *eq = memchr(p, '=', (size_t)(end - p));
                const char *lt = memchr(p, '<', (size_t)(end - p));
                if (eq && (!lt || eq < lt) && eq - p < (long)sizeof varName) {
                    size_t len = (size_t)(eq - p);
                    memcpy(varName, p, len);
                    varName[len] = 0;
                    p = eq + 1;
                } else {
                    snprintf(varName, sizeof varName, "slider%ld", (long)num);
                    aliasName[0] = 0;
                }
            } else {
                num = 0;
            }
        } else if (isComment && isalpha((unsigned char)*p)) {
            // Comment slider: //name:default<min,max,step>Label
            const char *colon = memchr(p, ':', (size_t)(end - p));
            const char *lt = memchr(p, '<', (size_t)(end - p));
            if (colon && lt && colon < lt && colon - p < (long)sizeof varName) {
                size_t len = (size_t)(colon - p);
                memcpy(varName, p, len);
                varName[len] = 0;
                num = nextSequential++;
                snprintf(aliasName, sizeof aliasName, "slider%ld", (long)num);
                p = colon + 1;
            }
        }

        if (varName[0]) {
            while (p < end && (*p == ' ' || *p == '\t')) p++;
            char *afterVal = NULL;
            double defVal = strtod(p, &afterVal);
            if (afterVal != p && afterVal < end && *afterVal == '<') {
                p = afterVal + 1;
                while (p < end && (*p == ' ' || *p == '\t')) p++;
                double minVal = strtod(p, &afterVal);
                if (afterVal != p && afterVal < end && *afterVal == ',') {
                    p = afterVal + 1;
                    while (p < end && (*p == ' ' || *p == '\t')) p++;
                    double maxVal = strtod(p, &afterVal);
                    double stepVal = 1.0;
                    NSMutableArray<NSString *> *options = nil;
                    p = afterVal;
                    while (p < end && (*p == ' ' || *p == '\t')) p++;
                    if (p < end && *p == ',') {
                        p++;
                        while (p < end && (*p == ' ' || *p == '\t')) p++;
                        char *afterStep = NULL;
                        double parsedStep = strtod(p, &afterStep);
                        if (afterStep != p) {
                            stepVal = parsedStep;
                            p = afterStep;
                        }
                        while (p < end && (*p == ' ' || *p == '\t')) p++;
                        if (p < end && *p == '{') {
                            p++;
                            const char *brace = memchr(p, '}', (size_t)(end - p));
                            if (brace) {
                                options = [NSMutableArray array];
                                const char *cur = p;
                                while (cur < brace) {
                                    const char *comma = memchr(cur, ',', (size_t)(brace - cur));
                                    size_t optLen = comma ? (size_t)(comma - cur) : (size_t)(brace - cur);
                                    NSString *opt = [[NSString alloc] initWithBytes:cur length:optLen encoding:NSUTF8StringEncoding];
                                    opt = [opt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                                    if (opt.length) [options addObject:opt];
                                    cur = comma ? comma + 1 : brace;
                                }
                                p = brace + 1;
                            }
                        }
                    }
                    const char *angle = memchr(p, '>', (size_t)(end - p));
                    if (angle) {
                        p = angle + 1;
                        while (p < end && (*p == ' ' || *p == '\t')) p++;
                        const char *labelEnd = end;
                        while (labelEnd > p && ((unsigned char)labelEnd[-1] <= ' ' || labelEnd[-1] == '\r')) labelEnd--;
                        NSString *label = labelEnd > p ? [[NSString alloc] initWithBytes:p length:(size_t)(labelEnd - p) encoding:NSUTF8StringEncoding] : nil;
                        if (!label.length) label = [NSString stringWithUTF8String:varName];

                        SGDSPLiveprogSlider *slider = [SGDSPLiveprogSlider new];
                        slider.index = num ? num : nextSequential++;
                        slider.name = [NSString stringWithUTF8String:varName];
                        if (aliasName[0] && strcmp(varName, aliasName) != 0) slider.alias = [NSString stringWithUTF8String:aliasName];
                        slider.defaultValue = defVal;
                        slider.minValue = minVal;
                        slider.maxValue = maxVal;
                        slider.step = stepVal > 0 ? stepVal : 1.0;
                        slider.options = options;
                        slider.label = label;
                        slider.key = [NSString stringWithFormat:@"spotifyglass.dsp.liveprog.slider.%@.%ld", cleanName, (long)slider.index];

                        SGDSPRegisterRange(slider.key, (SGDSPRange){minVal, maxVal, slider.step, defVal});
                        [sliders addObject:slider];
                        if (num >= nextSequential) nextSequential = num + 1;
                    }
                }
            }
        }
        line = *end ? end + 1 : end;
    }
    return sliders;
}

static bool compile(SGDSPLiveprog *liveprog, const char *script, const char *scriptName, char *error, size_t errorSize) {
    static const char *markers[SectionCount] = {"@init", "@slider", "@block", "@sample"};
    const char *starts[SectionCount] = {0}, *ends[SectionCount] = {0};
    int lines[SectionCount] = {0};
    int current = -1, number = 0;
    const char *preCodeStart = NULL, *preCodeEnd = NULL;

    for (const char *line = script; *line;) {
        const char *end = strchr(line, '\n');
        if (!end) end = line + strlen(line);
        number++;
        const char *text = line;
        while (text < end && (*text == ' ' || *text == '\t')) text++;
        if (*text == '@') {
            if (current >= 0) ends[current] = line;
            else if (preCodeStart) preCodeEnd = line;
            current = -1;
            for (int s = 0; s < SectionCount; s++) {
                size_t length = strlen(markers[s]);
                if (!strncmp(text, markers[s], length) && (text + length == end || isspace((unsigned char)text[length]))) current = s;
            }
            if (current >= 0) {
                starts[current] = *end ? end + 1 : end;
                lines[current] = number;
            }
        } else if (current < 0 && !preCodeStart && hasCode(text, end) && strncmp(text, "slider", 6) != 0) {
            preCodeStart = line;
        }
        line = *end ? end + 1 : end;
    }
    if (current >= 0) ends[current] = script + strlen(script);
    else if (preCodeStart && !preCodeEnd) preCodeEnd = script + strlen(script);

    // If no sections were marked at all, the entire script is the @sample block
    if (!starts[SectionInit] && !starts[SectionSlider] && !starts[SectionBlock] && !starts[SectionSample]) {
        starts[SectionSample] = script;
        ends[SectionSample] = script + strlen(script);
        lines[SectionSample] = 1;
    }

    if (!starts[SectionSample] || !hasCode(starts[SectionSample], ends[SectionSample])) {
        copyError(error, errorSize, "No @sample section: Liveprog runs a script's @sample on every sample");
        return false;
    }

    // Parse and register sliders
    NSString *nameStr = scriptName ? [NSString stringWithUTF8String:scriptName] : @"default";
    liveprog->sliders = SGDSPLiveprogParseSliders(nameStr, script);
    for (SGDSPLiveprogSlider *s in liveprog->sliders) {
        double val = SGDSPNumber(s.key);
        *NSEEL_VM_regvar(liveprog->vm, s.name.UTF8String) = val;
        if (s.alias.length) *NSEEL_VM_regvar(liveprog->vm, s.alias.UTF8String) = val;
    }

    for (int s = 0; s < SectionCount; s++) {
        if (!starts[s] || !hasCode(starts[s], ends[s])) continue;
        size_t length = (size_t)(ends[s] - starts[s]);
        size_t preLen = (s == SectionInit && preCodeStart && preCodeEnd > preCodeStart) ? (size_t)(preCodeEnd - preCodeStart) : 0;
        char *code = malloc(preLen + length + 2);
        if (!code) {
            copyError(error, errorSize, "Not enough memory for the script");
            return false;
        }
        if (preLen) {
            memcpy(code, preCodeStart, preLen);
            code[preLen] = '\n';
            memcpy(code + preLen + 1, starts[s], length);
            code[preLen + 1 + length] = 0;
        } else {
            memcpy(code, starts[s], length);
            code[length] = 0;
        }

        liveprog->code[s] = NSEEL_code_compile_ex(liveprog->vm, code, lines[s], NSEEL_CODE_COMPILE_FLAG_COMMONFUNCS);
        free(code);
        if (!liveprog->code[s]) {
            const char *message = NSEEL_code_getcodeerror(liveprog->vm);
            int line = 0, used = 0;
            char text[300];
            if (message && sscanf(message, "%d: %n", &line, &used) == 1 && used > 0) {
                snprintf(text, sizeof text, "Line %d: %s", line, message + used);
            } else {
                snprintf(text, sizeof text, "%s: %s", markers[s], message && *message ? message : "does not compile");
            }
            copyError(error, errorSize, text);
            return false;
        }
    }
    return true;
}

SGDSPLiveprog *SGDSPLiveprogCreate(const char *script, const char *scriptName, double rate, char *error, size_t errorSize) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, start);
    SGDSPLiveprog *liveprog = calloc(1, sizeof *liveprog);
    if (!liveprog || !(liveprog->vm = NSEEL_VM_alloc())) {
        free(liveprog);
        copyError(error, errorSize, "Not enough memory for the script");
        return NULL;
    }
    NSEEL_VM_SetStringFunc(liveprog->vm, onString, onNamedString);
    NSEEL_VM_SetGRAM(liveprog->vm, &liveprog->gram);
    NSEEL_VM_setramsize(liveprog->vm, kMemory);
    liveprog->spl0 = NSEEL_VM_regvar(liveprog->vm, "spl0");
    liveprog->spl1 = NSEEL_VM_regvar(liveprog->vm, "spl1");
    liveprog->samplesblock = NSEEL_VM_regvar(liveprog->vm, "samplesblock");
    *NSEEL_VM_regvar(liveprog->vm, "srate") = rate;
    *NSEEL_VM_regvar(liveprog->vm, "num_ch") = 2;
    *liveprog->samplesblock = kSGDSPEffectMaxFrames;
    if (!script) copyError(error, errorSize, "The script could not be read");
    if (!script || !compile(liveprog, script, scriptName, error, errorSize)) {
        SGDSPLiveprogFree(liveprog);
        return NULL;
    }
    NSEEL_VM_preallocram(liveprog->vm, -1);
    if (liveprog->code[SectionInit]) NSEEL_code_execute(liveprog->code[SectionInit]);
    if (liveprog->code[SectionSlider]) NSEEL_code_execute(liveprog->code[SectionSlider]);
    return liveprog;
}

void SGDSPLiveprogSetSlider(SGDSPLiveprog *liveprog, int index, double value) {
    if (!liveprog || !liveprog->vm) return;
    for (SGDSPLiveprogSlider *s in liveprog->sliders) {
        if (s.index == index) {
            *NSEEL_VM_regvar(liveprog->vm, s.name.UTF8String) = value;
            if (s.alias.length) *NSEEL_VM_regvar(liveprog->vm, s.alias.UTF8String) = value;
            break;
        }
    }
    if (liveprog->code[SectionSlider]) NSEEL_code_execute(liveprog->code[SectionSlider]);
}

NSArray<SGDSPLiveprogSlider *> *SGDSPLiveprogGetSliders(SGDSPLiveprog *liveprog) {
    return liveprog ? liveprog->sliders : @[];
}

void SGDSPLiveprogRun(void *state, float *left, float *right, uint32_t frames) {
    SGDSPLiveprog *liveprog = state;
    atomic_store_explicit(&sg_renderThread, pthread_self(), memory_order_relaxed);
    if (liveprog->code[SectionBlock]) {
        *liveprog->samplesblock = frames;
        NSEEL_code_execute(liveprog->code[SectionBlock]);
    }
    NSEEL_CODEHANDLE sample = liveprog->code[SectionSample];
    EEL_F *spl0 = liveprog->spl0, *spl1 = liveprog->spl1;
    for (uint32_t i = 0; i < frames; i++) {
        *spl0 = left[i];
        *spl1 = right[i];
        NSEEL_code_execute(sample);
        left[i] = (float)*spl0;
        right[i] = (float)*spl1;
    }
    atomic_store_explicit(&sg_renderThread, (pthread_t)NULL, memory_order_relaxed);
}

void SGDSPLiveprogFree(void *state) {
    SGDSPLiveprog *liveprog = state;
    if (!liveprog) return;
    for (int s = 0; s < SectionCount; s++) {
        if (liveprog->code[s]) NSEEL_code_free(liveprog->code[s]);
    }
    for (int i = 0; i < liveprog->stringCount; i++) {
        free(liveprog->strings[i]);
    }
    free(liveprog->strings);
    if (liveprog->vm) NSEEL_VM_free(liveprog->vm);
    NSEEL_VM_FreeGRAM(&liveprog->gram);
    free(liveprog);
}
