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
extern NSNotificationName const SGStemsSettingsDidChangeNotification;

// ============================================================================
// Lifecycle & Pipeline
// ============================================================================
void SGStemsInit(double sampleRate);
void SGStemsSetSampleRate(double sampleRate);
void SGStemsReset(void);
const SGAudioProcessor *SGStemsGetAudioProcessor(void);

// ============================================================================
// 4-Stem Source Separation (Vocals, Drums, Bass, Other)
// ============================================================================
void SGStemsSetEnabled(BOOL enabled);
BOOL SGStemsIsEnabled(void);
BOOL SGStemsIsSpleeterReady(void);
BOOL SGStemsIsSCNetReady(void);
void SGStemsReloadSpleeter(void);

// Stem levels are linear multipliers [0.0, 2.0], where 1.0 = original volume
void SGStemsSetStemLevels(float vocals, float drums, float bass, float other);
void SGStemsGetStemLevels(float *vocals, float *drums, float *bass, float *other);
void SGStemsGetStemMeters(float *vocals, float *drums, float *bass, float *other);

// 0=Normal, 1=Karaoke, 2=VocalsOnly, 3=BassBoost, 4=DrumsEmphasis, 5=Instrumental, 6=Custom
void SGStemsSetSeparationMode(int mode);
int SGStemsGetSeparationMode(void);

#ifdef __cplusplus
}
#endif
