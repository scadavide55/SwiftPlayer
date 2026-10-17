#include "AudioGain.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>
#include <limits.h>

_Static_assert(__atomic_always_lock_free(sizeof(float), 0), "Audio gain must be lock-free");

struct SPAudioGain {
    _Atomic(float) value;
    atomic_bool limiter;
    atomic_bool normalize;
    atomic_uint owners;
};
typedef struct {
    SPAudioGain *gain;
    AudioStreamBasicDescription format;
    float previousGain;
    float normalization;
    float limiting;
} TapContext;

SPAudioGain *SPAudioGainCreate(float value) {
    SPAudioGain *gain = calloc(1, sizeof(*gain));
    if (!gain) return NULL;
    atomic_init(&gain->value, value);
    atomic_init(&gain->owners, 1);
    atomic_init(&gain->limiter, true);
    atomic_init(&gain->normalize, false);
    return gain;
}
void SPAudioGainRelease(SPAudioGain *gain) {
    if (atomic_fetch_sub_explicit(&gain->owners, 1, memory_order_acq_rel) == 1) free(gain);
}
void SPAudioGainSetProcessing(SPAudioGain *gain, bool limiter, bool normalize) {
    atomic_store_explicit(&gain->limiter, limiter, memory_order_relaxed);
    atomic_store_explicit(&gain->normalize, normalize, memory_order_relaxed);
}
void SPAudioGainSet(SPAudioGain *gain, float value) {
    if (isfinite(value)) atomic_store_explicit(&gain->value, fminf(fmaxf(value, 1), 4), memory_order_relaxed);
}
static void initialize(MTAudioProcessingTapRef tap, void *info, void **storage) { *storage = info; }
static void finalize(MTAudioProcessingTapRef tap) {
    TapContext *context = MTAudioProcessingTapGetStorage(tap);
    SPAudioGainRelease(context->gain);
    free(context);
}
static void prepare(MTAudioProcessingTapRef tap, CMItemCount frames, const AudioStreamBasicDescription *format) {
    TapContext *context = MTAudioProcessingTapGetStorage(tap);
    context->format = *format;
    context->normalization = 1;
    context->limiting = 1;
    context->previousGain = atomic_load_explicit(&context->gain->value, memory_order_relaxed);
}
static void unprepare(MTAudioProcessingTapRef tap) { }
static double readSample(const AudioBuffer *buffer, size_t index, AudioFormatFlags flags, UInt32 bytes) {
    if ((flags & kAudioFormatFlagIsFloat) && bytes == 4) return ((float *)buffer->mData)[index];
    if ((flags & kAudioFormatFlagIsFloat) && bytes == 8) return ((double *)buffer->mData)[index];
    if ((flags & kAudioFormatFlagIsSignedInteger) && bytes == 2) return ((int16_t *)buffer->mData)[index] / 32768.0;
    if ((flags & kAudioFormatFlagIsSignedInteger) && bytes == 4) return ((int32_t *)buffer->mData)[index] / 2147483648.0;
    return 0;
}
static float limited(float value) { return fminf(fmaxf(value, -1), 1); }
static void process(MTAudioProcessingTapRef tap, CMItemCount frames, MTAudioProcessingTapFlags flags,
                    AudioBufferList *buffers, CMItemCount *framesOut, MTAudioProcessingTapFlags *flagsOut) {
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, NULL, framesOut);
    if (status != noErr) { *framesOut = 0; return; }
    TapContext *context = MTAudioProcessingTapGetStorage(tap);
    float gain = atomic_load_explicit(&context->gain->value, memory_order_relaxed);
    float previous = context->previousGain;
    context->previousGain = gain;
    bool normalize = atomic_load_explicit(&context->gain->normalize, memory_order_relaxed);
    bool limiter = atomic_load_explicit(&context->gain->limiter, memory_order_relaxed);
    if (gain == 1 && previous == 1 && !limiter && !normalize && context->normalization == 1 && context->limiting == 1) return;
    AudioStreamBasicDescription format = context->format;
    // AVFoundation supplies native-endian PCM to the tap. Interleaved and
    // planar layouts both work: every buffer carries its own channel count.
    if (format.mFormatID != kAudioFormatLinearPCM || (format.mFormatFlags & kAudioFormatFlagIsBigEndian)) return;
    double peak = 0, energy = 0;
    size_t samplesCount = 0;
    UInt32 sampleBytes = format.mBitsPerChannel / 8;
    if (!sampleBytes || format.mSampleRate <= 0) return;
    // Measure all channels together so processing preserves stereo balance.
    for (UInt32 b = 0; b < buffers->mNumberBuffers; b++) {
        AudioBuffer buffer = buffers->mBuffers[b];
        if (!buffer.mData || !buffer.mNumberChannels) continue;
        size_t count = buffer.mDataByteSize / sampleBytes;
        size_t valid = (size_t)*framesOut * buffer.mNumberChannels;
        if (count > valid) count = valid;
        for (size_t i = 0; i < count; i++) {
            double sample = readSample(&buffer, i, format.mFormatFlags, sampleBytes);
            if (!isfinite(sample)) continue;
            peak = fmax(peak, fabs(sample));
            energy += sample * sample;
            samplesCount++;
        }
    }
    double seconds = *framesOut / format.mSampleRate;
    double rms = samplesCount ? sqrt(energy / samplesCount) : 0;
    // Optional level normalization targets -17 dBFS RMS. A -40 dBFS gate
    // avoids amplifying silence/noise; gain recovers gradually rather than pumping.
    float target = normalize && rms > 0.01 ? fmin(fmax(0.14 / rms, 0.1), 4) : 1;
    float oldNormalization = context->normalization;
    double recovery = target < oldNormalization ? 0.05 : 1.0;
    context->normalization += (target - oldNormalization) * (1 - exp(-seconds / recovery));
    if (fabsf(context->normalization - target) < 0.0001) context->normalization = target;
    float maximumGain = fmaxf(gain, previous) * fmaxf(oldNormalization, context->normalization);
    float requiredLimit = limiter && peak * maximumGain > 0.98 ? 0.98 / (peak * maximumGain) : 1;
    // The already-available source block provides peak lookahead without adding
    // latency. Immediate attack and a 250 ms release protect boosts smoothly.
    if (!limiter) context->limiting = 1;
    else context->limiting = fminf(requiredLimit, context->limiting + (1 - context->limiting) * (1 - exp(-seconds / 0.25)));
    if (1 - context->limiting < 0.0001) context->limiting = 1;
    for (UInt32 b = 0; b < buffers->mNumberBuffers; b++) {
        AudioBuffer buffer = buffers->mBuffers[b];
        if (!buffer.mData || !buffer.mNumberChannels) continue;
        UInt32 bytes = format.mBitsPerChannel / 8;
        if (!bytes) continue;
        size_t count = buffer.mDataByteSize / bytes;
        size_t valid = (size_t)*framesOut * buffer.mNumberChannels;
        if (count > valid) count = valid;
        // Smooth gain changes over the first 5 ms, without allocation or locks.
        double rampFrames = fmax(1, format.mSampleRate * 0.005);
        for (size_t i = 0; i < count; i++) {
            float mix = fminf(1, (float)((i / buffer.mNumberChannels + 1) / rampFrames));
            float frameProgress = fminf(1, (float)(i / buffer.mNumberChannels + 1) / fmaxf(1, (float)*framesOut));
            float normalization = oldNormalization + (context->normalization - oldNormalization) * frameProgress;
            float scale = (previous + (gain - previous) * mix) * normalization * context->limiting;
            if ((format.mFormatFlags & kAudioFormatFlagIsFloat) && bytes == 4) {
                float *samples = buffer.mData;
                samples[i] = limited(samples[i] * scale);
            } else if ((format.mFormatFlags & kAudioFormatFlagIsFloat) && bytes == 8) {
                double *samples = buffer.mData;
                samples[i] = fmin(fmax(samples[i] * scale, -1), 1);
            } else if ((format.mFormatFlags & kAudioFormatFlagIsSignedInteger) && bytes == 2) {
                int16_t *samples = buffer.mData;
                samples[i] = (int16_t)fminf(fmaxf(samples[i] * scale, INT16_MIN), INT16_MAX);
            } else if ((format.mFormatFlags & kAudioFormatFlagIsSignedInteger) && bytes == 4) {
                int32_t *samples = buffer.mData;
                samples[i] = (int32_t)fmin(fmax(samples[i] * (double)scale, INT32_MIN), INT32_MAX);
            }
        }
    }
}
MTAudioProcessingTapRef SPAudioGainMakeTap(SPAudioGain *gain) {
    TapContext *context = calloc(1, sizeof(*context));
    if (!context) return NULL;
    atomic_fetch_add_explicit(&gain->owners, 1, memory_order_relaxed);
    context->gain = gain;
    MTAudioProcessingTapCallbacks callbacks = { kMTAudioProcessingTapCallbacksVersion_0, context,
        initialize, finalize, prepare, unprepare, process };
    MTAudioProcessingTapRef tap = NULL;
    if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) != noErr) {
        SPAudioGainRelease(gain);
        free(context);
        return NULL;
    }
    return tap;
}
