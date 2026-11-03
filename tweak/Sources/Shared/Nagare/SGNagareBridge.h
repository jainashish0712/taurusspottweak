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
void SGNagareInit(double sampleRate);
void SGNagareSetSampleRate(double sampleRate);
void SGNagareReset(void);
const SGAudioProcessor *SGNagareGetAudioProcessor(void);

// ============================================================================
// 4-Stem Source Separation (Vocals, Drums, Bass, Other)
// ============================================================================
void SGNagareSetStemsEnabled(BOOL enabled);
BOOL SGNagareIsStemsEnabled(void);
BOOL SGNagareIsSpleeterReady(void);
BOOL SGNagareIsSCNetReady(void);
void SGNagareReloadSpleeter(void);

// Stem levels are linear multipliers [0.0, 2.0], where 1.0 = original volume
void SGNagareSetStemLevels(float vocals, float drums, float bass, float other);
void SGNagareGetStemLevels(float *vocals, float *drums, float *bass, float *other);
void SGNagareGetStemMeters(float *vocals, float *drums, float *bass, float *other);

// 0=Normal, 1=Karaoke, 2=VocalsOnly, 3=BassBoost, 4=DrumsEmphasis, 5=Instrumental, 6=Custom
void SGNagareSetSeparationMode(int mode);
int SGNagareGetSeparationMode(void);

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
void SGNagareSetVirtualBass(BOOL enabled, float amount, float freq);
void SGNagareSetSubharmonic(BOOL enabled, float amount);
void SGNagareSetTubeWarmth(BOOL enabled, float amount, float drive);
void SGNagareSetExciter(BOOL enabled, float amount, float freq);
void SGNagareSetAirBand(BOOL enabled, float amount);
void SGNagareSetStereoWidth(BOOL enabled, float width);
void SGNagareSetCrossfeed(BOOL enabled, float amount);
void SGNagareSetReverb(BOOL enabled, float roomSize, float damping, float wet, float dry, float width);
void SGNagareSetTransientShaper(BOOL enabled, float attack, float sustain);
void SGNagareSetLoudnessComp(BOOL enabled, float amount);
void SGNagareSetEQEnabled(BOOL enabled);
void SGNagareSetEQBands(const float *gains10);
void SGNagareSetDeviceProfile(int profileId);
void SGNagareGetFFTMagnitudes(float *output, int fftSize);

#ifdef __cplusplus
}
#endif
