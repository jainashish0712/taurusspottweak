#include "SGSingDSP.h"
#include <math.h>

static const double kLevelRampSeconds = 0.030, kBypassRampSeconds = 0.120;
static const float kVoiceWidth = 0.5f, kVoiceDelay = 0.00065f, kVoiceShadow = 0.35f;
static const float kTau = 6.28318530718f, kPiQuarter = 0.78539816339f, kSqrtTwo = 1.41421356237f;

static float gain(float level) { return SGSingClampLevel(level); }
static void ramp(SGSingMixer *m, float to, double seconds) {
    m->targetGain = to;
    m->remaining = (uint32_t)fmax(1, m->sampleRate * seconds);
    m->step = (to - m->gain) / m->remaining;
}
void SGSingMixerInit(SGSingMixer *m, double rate, float level) {
    *m = (SGSingMixer){.gain = gain(level), .targetGain = gain(level),
                      .sampleRate = isfinite(rate) && rate >= 8000 && rate <= 192000 ? rate : 44100,
                      .directGain = 1, .targetDirectGain = 1, .width = 1, .targetWidth = 1};
}
void SGSingMixerSetLevel(SGSingMixer *m, float level) {
    float target = gain(level);
    if (target != m->targetGain) ramp(m, target, kLevelRampSeconds);
}
void SGSingMixerBypass(SGSingMixer *m) { ramp(m, 0.5f, kBypassRampSeconds); }
void SGSingMixerSetVoiceAngle(SGSingMixer *m, float radians) {
    m->targetVoiceAngle = isfinite(radians) ? remainderf(radians, kTau) : 0;
}
void SGSingMixerSetSpatial(SGSingMixer *m, bool on, float distance, float room, float width) {
    if (!on) {
        m->targetDirectGain = 1;
        m->targetSendGain = 0;
        m->targetWidth = 1;
        return;
    }
    distance = isfinite(distance) ? fminf(6.5f, fmaxf(1, distance)) : 1.5f;
    room = isfinite(room) ? fminf(1, fmaxf(0, room)) : 0.25f;
    m->targetDirectGain = sqrtf(1 / distance);
    m->targetSendGain = room * (0.5f + 0.5f * (distance - 1) / 5.5f);
    m->targetWidth = isfinite(width) ? fminf(2, fmaxf(0, width)) : 1.1f;
}

void SGSingMixerProcess(SGSingMixer *m, const float *original, const float *vocals, float *out, uint32_t frames) {
    const float glide = 1 - expf(-1 / (0.05f * (float)m->sampleRate));
    bool spatial = m->directGain != 1 || m->targetDirectGain != 1 ||
                   m->sendGain != 0 || m->targetSendGain != 0 ||
                   m->width != 1 || m->targetWidth != 1 ||
                   m->voiceAngle != 0 || m->targetVoiceAngle != 0;
    for (uint32_t i = 0; i < frames; i++) {
        if (m->remaining) {
            m->gain += m->step;
            if (!--m->remaining) m->gain = m->targetGain;
        }
        size_t at = (size_t)i * 2;
        float left = isfinite(original[at]) ? original[at] : 0;
        float right = isfinite(original[at + 1]) ? original[at + 1] : 0;
        float vocalLeft = isfinite(vocals[at]) ? vocals[at] : 0;
        float vocalRight = isfinite(vocals[at + 1]) ? vocals[at + 1] : 0;
        if (!spatial) {
            float instrumentMix = m->gain <= 0.5f ? 1 : 2 * (1 - m->gain);
            float voiceMix = m->gain < 0.5f ? 2 * m->gain : 1;
            float instrumentalLeft = left - vocalLeft, instrumentalRight = right - vocalRight;
            out[at] = fmaxf(-1, fminf(1, instrumentMix * instrumentalLeft + voiceMix * vocalLeft));
            out[at + 1] = fmaxf(-1, fminf(1, instrumentMix * instrumentalRight + voiceMix * vocalRight));
            m->roomSend = 0;
            continue;
        }
        m->voiceAngle += remainderf(m->targetVoiceAngle - m->voiceAngle, kTau) * glide;
        m->directGain += (m->targetDirectGain - m->directGain) * glide;
        m->sendGain += (m->targetSendGain - m->sendGain) * glide;
        m->width += (m->targetWidth - m->width) * glide;

        float middle = (vocalLeft + vocalRight) * 0.5f;
        float side = (vocalLeft - vocalRight) * 0.5f;
        m->middle[m->middleAt] = middle;
        float rightward = sinf(m->voiceAngle), far = fabsf(rightward);
        float pan = (kVoiceWidth * rightward + 1) * kPiQuarter;
        float gainLeft = kSqrtTwo * cosf(pan), gainRight = kSqrtTwo * sinf(pan);
        float delay = far * kVoiceDelay * (float)m->sampleRate;
        uint32_t whole = (uint32_t)delay;
        float part = delay - whole;
        uint32_t recent = (m->middleAt - whole) & 63;
        uint32_t older = (recent - (whole < 63)) & 63;
        float delayed = m->middle[recent] * (1 - part) + m->middle[older] * part;
        float shadow = 1 - far * (1 - kVoiceShadow);
        m->shadowLeft += (rightward > 0 ? shadow : 1) * (delayed - m->shadowLeft);
        m->shadowRight += (rightward < 0 ? shadow : 1) * (delayed - m->shadowRight);
        m->middleAt = (m->middleAt + 1) & 63;

        float instrumentalLeft = left - vocalLeft;
        float instrumentalRight = right - vocalRight;
        float instrumentMix = m->gain <= 0.5f ? 1 : 2 * (1 - m->gain);
        float voiceMix = m->gain < 0.5f ? 2 * m->gain : 1;
        float instrumentalSide = (instrumentalLeft - instrumentalRight) * 0.5f;
        instrumentalLeft += (m->width - 1) * instrumentalSide;
        instrumentalRight -= (m->width - 1) * instrumentalSide;
        float placedLeft = gainLeft * m->shadowLeft + side;
        float placedRight = gainRight * m->shadowRight - side;
        m->roomSend = voiceMix * m->sendGain * middle;
        out[at] = fmaxf(-1, fminf(1, instrumentMix * instrumentalLeft + voiceMix * m->directGain * placedLeft));
        out[at + 1] = fmaxf(-1, fminf(1, instrumentMix * instrumentalRight + voiceMix * m->directGain * placedRight));
    }
}

void SG4StemMixerInit(SG4StemMixer *m, double rate) {
    if (!m) return;
    m->gainVocals = m->targetGainVocals = 1.0f;
    m->gainDrums = m->targetGainDrums = 1.0f;
    m->gainBass = m->targetGainBass = 1.0f;
    m->gainOther = m->targetGainOther = 1.0f;
    m->stepVocals = m->stepDrums = m->stepBass = m->stepOther = 0.0f;
    m->remaining = 0;
    m->sampleRate = isfinite(rate) && rate >= 8000 && rate <= 192000 ? rate : 44100;
}

void SG4StemMixerSetGains(SG4StemMixer *m, float vocals, float drums, float bass, float other) {
    if (!m) return;
    m->targetGainVocals = fmaxf(0.0f, fminf(1.0f, vocals));
    m->targetGainDrums = fmaxf(0.0f, fminf(1.0f, drums));
    m->targetGainBass = fmaxf(0.0f, fminf(1.0f, bass));
    m->targetGainOther = fmaxf(0.0f, fminf(1.0f, other));
    uint32_t frames = (uint32_t)fmax(1, m->sampleRate * 0.030); // 30ms linear gain ramp
    m->remaining = frames;
    m->stepVocals = (m->targetGainVocals - m->gainVocals) / frames;
    m->stepDrums = (m->targetGainDrums - m->gainDrums) / frames;
    m->stepBass = (m->targetGainBass - m->gainBass) / frames;
    m->stepOther = (m->targetGainOther - m->gainOther) / frames;
}

void SG4StemMixerProcess(SG4StemMixer *m,
                         const float *original,
                         const float *vocals,
                         const float *drums,
                         const float *bass,
                         const float *other,
                         float *output,
                         uint32_t frames) {
    if (!m || !output || !frames) return;
    for (uint32_t i = 0; i < frames; i++) {
        if (m->remaining) {
            m->gainVocals += m->stepVocals;
            m->gainDrums += m->stepDrums;
            m->gainBass += m->stepBass;
            m->gainOther += m->stepOther;
            if (!--m->remaining) {
                m->gainVocals = m->targetGainVocals;
                m->gainDrums = m->targetGainDrums;
                m->gainBass = m->targetGainBass;
                m->gainOther = m->targetGainOther;
            }
        }
        size_t at = (size_t)i * 2;
        for (size_t c = 0; c < 2; c++) {
            size_t idx = at + c;
            float v = vocals && isfinite(vocals[idx]) ? vocals[idx] : 0.0f;
            float d = drums && isfinite(drums[idx]) ? drums[idx] : 0.0f;
            float b = bass && isfinite(bass[idx]) ? bass[idx] : 0.0f;
            float o = other && isfinite(other[idx]) ? other[idx] : 0.0f;
            
            // If drums and bass are not provided (e.g. 2-stem fallback), use original - vocals
            if (!drums && !bass) {
                float orig = original && isfinite(original[idx]) ? original[idx] : 0.0f;
                float inst = orig - v;
                output[idx] = fmaxf(-1.0f, fminf(1.0f, inst * m->gainOther + v * m->gainVocals));
            } else {
                float sum = (v * m->gainVocals) + (d * m->gainDrums) + (b * m->gainBass) + (o * m->gainOther);
                output[idx] = fmaxf(-1.0f, fminf(1.0f, sum));
            }
        }
    }
}


static SG4StemMixer sg_globalStemMixer;
static bool sg_stemMixerInited = false;

void SGSingSet4StemGains(float vocals, float drums, float bass, float other) {
    if (!sg_stemMixerInited) {
        SG4StemMixerInit(&sg_globalStemMixer, 44100.0);
        sg_stemMixerInited = true;
    }
    SG4StemMixerSetGains(&sg_globalStemMixer, vocals, drums, bass, other);
}

void SGSingGet4StemGains(float *vocals, float *drums, float *bass, float *other) {
    if (!sg_stemMixerInited) {
        SG4StemMixerInit(&sg_globalStemMixer, 44100.0);
        sg_stemMixerInited = true;
    }
    if (vocals) *vocals = sg_globalStemMixer.targetGainVocals;
    if (drums) *drums = sg_globalStemMixer.targetGainDrums;
    if (bass) *bass = sg_globalStemMixer.targetGainBass;
    if (other) *other = sg_globalStemMixer.targetGainOther;
}
