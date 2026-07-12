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

/**
 * mixer_stats
 *
 * Fills caller-provided int64 slots with per-client diagnostics:
 *   out[0] = current ring buffer depth in frames
 *   out[1] = cumulative underrun frames (ring starved on playback)
 *   out[2] = cumulative overrun frames (ring full on write, dropped)
 *   out[3] = active flag (0/1)
 *
 * @param clientId Identifier in the range [0, MAX_CLIENTS).
 * @param out      Caller-allocated array of at least `outLen` int64 slots.
 * @param outLen   Number of slots available in `out`.
 */
MIXER_API void mixer_stats(uint16_t clientId, int64_t* out, int outLen);

// ===========================================================================
// Loopback (system audio capture) API
// ===========================================================================
//
// Hub と分離した送信側用途の WASAPI loopback ベースキャプチャ。
// `loopback_start()` でデフォルト出力デバイスをループバックモードで開き、
// 別スレッドで動く data_callback が PCM16 ステレオ 48 kHz のリングバッファに
// 書き込む。Dart 側は `loopback_read_pcm16()` を polling して読み出す。

#define LOOPBACK_RING_FRAMES 96000  // 2 seconds @ 48 kHz

/**
 * loopback_start
 *
 * Initializes a WASAPI loopback device on the default playback endpoint and
 * begins streaming captured audio into an internal ring buffer in PCM16 stereo
 * 48 kHz interleaved format.
 *
 * @return 0 on success, non-zero error code on failure.
 *         (1: already started, 2: ma_device_init failed, 3: ma_device_start failed,
 *          4: format conversion not possible)
 */
MIXER_API int loopback_start(void);

/**
 * loopback_stop
 *
 * Stops the loopback device and clears the ring buffer.
 */
MIXER_API void loopback_stop(void);

/**
 * loopback_read_pcm16
 *
 * Read up to `maxFrames` stereo frames (each = 4 bytes interleaved L,R PCM16)
 * from the loopback ring buffer into the caller-provided buffer.
 *
 * @param buffer    Destination buffer of size at least maxFrames * 4 bytes.
 * @param maxFrames Maximum number of stereo frames to read.
 * @return Number of frames actually written. 0 if no data available.
 */
MIXER_API int loopback_read_pcm16(int16_t* buffer, int maxFrames);

/**
 * loopback_pending_frames
 *
 * Number of frames currently buffered (for diagnostics/UI).
 */
MIXER_API int loopback_pending_frames(void);

/**
 * loopback_is_running
 *
 * 1 if the loopback device is currently running, 0 otherwise.
 */
MIXER_API int loopback_is_running(void);

#ifdef __cplusplus
} // extern "C"
#endif
