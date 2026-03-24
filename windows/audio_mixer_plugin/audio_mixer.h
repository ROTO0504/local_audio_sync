#pragma once

#include <stdint.h>

// Maximum number of simultaneous audio clients
#define MAX_CLIENTS 16

// Ring buffer size in frames: 1 second at 48 kHz
#define RING_BUFFER_FRAMES 48000

// DLL export/import annotations
#ifdef _WIN32
  #ifdef AUDIO_MIXER_PLUGIN_EXPORTS
    #define MIXER_API __declspec(dllexport)
  #else
    #define MIXER_API __declspec(dllimport)
  #endif
#else
  #define MIXER_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/**
 * mixer_init
 *
 * Initializes the miniaudio playback device:
 *   - Sample rate : 48 000 Hz
 *   - Format      : float32 (ma_format_f32)
 *   - Channels    : 2 (stereo)
 *   - Period      : 512 frames
 *
 * Must be called once before any other mixer function.
 */
MIXER_API void mixer_init(void);

/**
 * mixer_push_frames
 *
 * Pushes decoded float32 PCM data into the ring buffer that belongs to
 * the given client.  The data must be interleaved stereo (L, R, L, R, …).
 *
 * @param clientId   Identifier in the range [0, MAX_CLIENTS).
 * @param pcm        Pointer to interleaved stereo float32 samples.
 * @param frameCount Number of frames (each frame = 2 floats for stereo).
 *
 * Frames are silently dropped when the ring buffer is full (overflow
 * protection — the audio callback always has priority).
 */
MIXER_API void mixer_push_frames(uint16_t clientId, const float* pcm, int frameCount);

/**
 * mixer_set_volume
 *
 * Sets the per-client linear volume scalar.
 *
 * @param clientId Identifier in the range [0, MAX_CLIENTS).
 * @param volume   Value in [0.0, 1.0].  Values outside this range are clamped
 *                 by the audio callback.
 */
MIXER_API void mixer_set_volume(uint16_t clientId, float volume);

/**
 * mixer_remove_client
 *
 * Marks the client slot as inactive and clears its ring buffer so that
 * stale audio does not bleed into future playback.
 *
 * @param clientId Identifier in the range [0, MAX_CLIENTS).
 */
MIXER_API void mixer_remove_client(uint16_t clientId);

/**
 * mixer_destroy
 *
 * Stops and uninitializes the miniaudio device.  Call this when the
 * application is shutting down.  After this call, mixer_init() must be
 * invoked again before any other function may be used.
 */
MIXER_API void mixer_destroy(void);

#ifdef __cplusplus
} // extern "C"
#endif
