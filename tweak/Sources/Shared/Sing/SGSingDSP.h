#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "SGSingLevel.h"

typedef struct {
    float gain, targetGain, step;
    uint32_t remaining;
    double sampleRate;
    float voiceAngle, targetVoiceAngle;
    float directGain, targetDirectGain, sendGain, targetSendGain, width, targetWidth;
    float shadowLeft, shadowRight, middle[64], roomSend;
    uint32_t middleAt;
} SGSingMixer;
// One render-thread owner. Control requests must be delivered atomically by the caller.
void SGSingMixerInit(SGSingMixer *mixer, double sampleRate, float level);
void SGSingMixerSetLevel(SGSingMixer *mixer, float level); // a 30 ms ramp to the new level
void SGSingMixerSetVoiceAngle(SGSingMixer *mixer, float radians);
void SGSingMixerSetSpatial(SGSingMixer *mixer, bool on, float distance, float room, float width);
// Stereo interleaved. Original and vocals must have identical generation, format and source index.
// Instrumental = original - vocals; a unity instrumental gain preserves the original balance.
void SGSingMixerProcess(SGSingMixer *mixer, const float *original, const float *vocals, float *output, uint32_t frames);
// A 120 ms ramp to the aligned original, no clock change: SGSingReserveFrames at 44.1 kHz.
void SGSingMixerBypass(SGSingMixer *mixer);

typedef struct {
    float gainVocals, targetGainVocals;
    float gainDrums, targetGainDrums;
    float gainBass, targetGainBass;
    float gainOther, targetGainOther;
    float stepVocals, stepDrums, stepBass, stepOther;
    uint32_t remaining;
    double sampleRate;
} SG4StemMixer;

void SG4StemMixerInit(SG4StemMixer *mixer, double sampleRate);
void SG4StemMixerSetGains(SG4StemMixer *mixer, float vocals, float drums, float bass, float other);
void SG4StemMixerProcess(SG4StemMixer *mixer,
                         const float *original,
                         const float *vocals,
                         const float *drums,
                         const float *bass,
                         const float *other,
                         float *output,
                         uint32_t frames);

void SGSingSet4StemGains(float vocals, float drums, float bass, float other);
void SGSingGet4StemGains(float *vocals, float *drums, float *bass, float *other);
