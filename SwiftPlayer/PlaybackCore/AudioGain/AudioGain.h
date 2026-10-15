#ifndef SwiftPlayer_AudioGain_h
#define SwiftPlayer_AudioGain_h
#include <MediaToolbox/MediaToolbox.h>
#include <stdbool.h>

// Shared gain is lock-free; each tap retains it until its final callback.
typedef struct SPAudioGain SPAudioGain;
SPAudioGain * _Nullable SPAudioGainCreate(float gain);
void SPAudioGainRelease(SPAudioGain * _Nonnull gain);
void SPAudioGainSetProcessing(SPAudioGain * _Nonnull gain, bool limiter, bool normalize);
void SPAudioGainSet(SPAudioGain * _Nonnull gain, float value);
MTAudioProcessingTapRef _Nullable SPAudioGainMakeTap(SPAudioGain * _Nonnull gain) CF_RETURNS_RETAINED;
#endif
