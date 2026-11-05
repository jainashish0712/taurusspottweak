#pragma once
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "Shared/Audio/SGAudioPipeline.h"

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Notifications
// ============================================================================
extern NSNotificationName const SGNagareSettingsDidChangeNotification;

// ============================================================================
// Lifecycle & Pipeline
// ============================================================================
void SGNagareDSPInit(double sampleRate);
void SGNagareDSPSetSampleRate(double sampleRate);
void SGNagareDSPReset(void);
const SGAudioProcessor *SGNagareDSPGetAudioProcessor(void);

// Aliases for compatibility
#define SGNagareInit           SGNagareDSPInit
#define SGNagareSetSampleRate  SGNagareDSPSetSampleRate
#define SGNagareReset          SGNagareDSPReset
#define SGNagareGetAudioProcessor SGNagareDSPGetAudioProcessor

// ============================================================================
// Audio Upscaler (SBR / DSEE Spectral Extension)
// ============================================================================
void SGNagareSetUpscalerEnabled(BOOL enabled);
BOOL SGNagareIsUpscalerEnabled(void);
void SGNagareSetUpscalerIntensity(float intensity); // 0.0 - 1.0
float SGNagareGetUpscalerIntensity(void);
void SGNagareSetUpscalerCutoff(float cutoffHz);
int SGNagareGetDetectedSourceQuality(void); // 0=low, 1=medium, 2=high

// ============================================================================
// Dynamic Restorer (Anti-Loudness Wars Multi-Band Expander)
// ============================================================================
void SGNagareSetRestorerEnabled(BOOL enabled);
BOOL SGNagareIsRestorerEnabled(void);
void SGNagareSetRestorerIntensity(float intensity); // 0.0 - 1.0
float SGNagareGetRestorerIntensity(void);
void SGNagareSetRestorerExpansion(float ratio);
void SGNagareSetRestorerTransient(float amount);

// ============================================================================
// Binaural Spatial HRTF (MIT KEMAR)
// ============================================================================
void SGNagareSetHRTFEnabled(BOOL enabled);
BOOL SGNagareIsHRTFEnabled(void);
void SGNagareSetHRTFAngle(float angleDegrees); // -90 to +90
float SGNagareGetHRTFAngle(void);
void SGNagareSetHRTFPreset(int preset); // 0=Generic, 1=Small head, 2=Large head
void SGNagareSetHRTFRoomSize(float size);
void SGNagareSetHRTFDistance(float meters);

// ============================================================================
// Core DSP Chain (10-Band EQ, Dynamics, Harmonics, Spatial)
// ============================================================================
void SGNagareSetCoreDSPEnabled(BOOL enabled);
BOOL SGNagareIsCoreDSPEnabled(void);

void SGNagareSetSmartEnhance(BOOL enabled, float intensity);
BOOL SGNagareIsSmartEnhanceEnabled(void);
float SGNagareGetSmartIntensity(void);

void SGNagareSetVirtualBass(BOOL enabled, float amount, float freq);
BOOL SGNagareIsVirtualBassEnabled(void);
float SGNagareGetVirtualBassIntensity(void);

void SGNagareSetSubharmonic(BOOL enabled, float amount);

void SGNagareSetTubeWarmth(BOOL enabled, float amount, float drive);
BOOL SGNagareIsTubeWarmthEnabled(void);
float SGNagareGetTubeWarmthIntensity(void);

void SGNagareSetExciter(BOOL enabled, float amount, float freq);
BOOL SGNagareIsExciterEnabled(void);
float SGNagareGetExciterIntensity(void);

void SGNagareSetAirBand(BOOL enabled, float amount);

void SGNagareSetStereoWidth(BOOL enabled, float width);
BOOL SGNagareIsStereoWidthEnabled(void);
float SGNagareGetStereoWidth(void);

void SGNagareSetCrossfeed(BOOL enabled, float amount);
BOOL SGNagareIsCrossfeedEnabled(void);
float SGNagareGetCrossfeedAmount(void);

void SGNagareSetReverb(BOOL enabled, float roomSize, float damping, float wet, float dry, float width);
BOOL SGNagareIsReverbEnabled(void);
float SGNagareGetReverbIntensity(void);

void SGNagareSetTransientShaper(BOOL enabled, float attack, float sustain);
void SGNagareSetLoudnessComp(BOOL enabled, float amount);

void SGNagareSetEQEnabled(BOOL enabled);
void SGNagareSetEQBands(const float *gains10);

void SGNagareSetDeviceProfile(int profileId);
void SGNagareGetFFTMagnitudes(float *output, int fftSize);

#ifdef __cplusplus
}
#endif
