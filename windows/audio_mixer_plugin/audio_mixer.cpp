// TODO: Download miniaudio.h from https://raw.githubusercontent.com/mackron/miniaudio/master/miniaudio.h
//       and place it in this directory (windows/audio_mixer_plugin/miniaudio.h) before building.

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include "audio_mixer.h"

#include <array>
#include <atomic>
#include <algorithm>
#include <cstring>
#include <cstdint>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

static constexpr int    kSampleRate    = 48000;
static constexpr int    kChannels      = 2;
static constexpr int    kPeriodFrames  = 512;
// Total number of *samples* (floats) per ring buffer (stereo × 1 s)
static constexpr size_t kRingBufSamples = static_cast<size_t>(RING_BUFFER_FRAMES) * kChannels;

// ---------------------------------------------------------------------------
// Per-client state
// ---------------------------------------------------------------------------

struct ClientState {
    // Interleaved stereo ring buffer: index 0 = L sample of frame 0,
    // index 1 = R sample of frame 0, etc.
    std::array<float, kRingBufSamples> buf{};

    // Write head: advanced by mixer_push_frames (producer thread).
    // Read head : advanced by the audio callback (consumer thread).
    // Both indices are in *samples* (not frames).
    std::atomic<size_t> writeHead{0};
    std::atomic<size_t> readHead{0};

    // Per-client linear volume in [0.0, 1.0].
    std::atomic<float> volume{1.0f};

    // Whether this slot is currently in use.
    std::atomic<bool> active{false};
};

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static ClientState  g_clients[MAX_CLIENTS];
static ma_device    g_device;
static bool         g_deviceInitialized = false;

// ---------------------------------------------------------------------------
// Ring-buffer helpers
// ---------------------------------------------------------------------------

// Returns the number of samples currently available to read.
static inline size_t rb_available_read(const ClientState& c) {
    size_t w = c.writeHead.load(std::memory_order_acquire);
    size_t r = c.readHead.load(std::memory_order_relaxed);
    return (w - r + kRingBufSamples) % kRingBufSamples;
}

// Returns the number of free sample slots (i.e. available for writing).
static inline size_t rb_available_write(const ClientState& c) {
    // Keep one slot empty to distinguish full from empty.
    size_t avail_read = rb_available_read(c);
    if (avail_read >= kRingBufSamples - 1) return 0;
    return (kRingBufSamples - 1) - avail_read;
}

// ---------------------------------------------------------------------------
// miniaudio data callback (audio thread)
// ---------------------------------------------------------------------------

static void data_callback(
    ma_device*  pDevice,
    void*       pOutput,
    const void* /*pInput*/,
    ma_uint32   frameCount)
{
    (void)pDevice;

    float* out = static_cast<float*>(pOutput);
    const size_t totalSamples = static_cast<size_t>(frameCount) * kChannels;

    // Zero-fill the output buffer so we can safely accumulate into it.
    std::memset(out, 0, totalSamples * sizeof(float));

    for (int ci = 0; ci < MAX_CLIENTS; ++ci) {
        ClientState& c = g_clients[ci];
        if (!c.active.load(std::memory_order_acquire)) continue;

        float vol = c.volume.load(std::memory_order_relaxed);
        size_t available = rb_available_read(c);
        size_t toRead = std::min(available, totalSamples);

        size_t r = c.readHead.load(std::memory_order_relaxed);

        for (size_t i = 0; i < toRead; ++i) {
            out[i] += c.buf[r % kRingBufSamples] * vol;
            ++r;
        }

        c.readHead.store(r % kRingBufSamples, std::memory_order_release);
    }

    // Clip the mixed output to [-1.0, 1.0] to prevent distortion.
    for (size_t i = 0; i < totalSamples; ++i) {
        if      (out[i] >  1.0f) out[i] =  1.0f;
        else if (out[i] < -1.0f) out[i] = -1.0f;
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

extern "C" {

void mixer_init(void) {
    if (g_deviceInitialized) return;

    // Zero-initialise all client state.
    for (int i = 0; i < MAX_CLIENTS; ++i) {
        g_clients[i].buf.fill(0.0f);
        g_clients[i].writeHead.store(0, std::memory_order_relaxed);
        g_clients[i].readHead.store(0, std::memory_order_relaxed);
        g_clients[i].volume.store(1.0f, std::memory_order_relaxed);
        g_clients[i].active.store(false, std::memory_order_relaxed);
    }

    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format   = ma_format_f32;
    config.playback.channels = static_cast<ma_uint32>(kChannels);
    config.sampleRate        = static_cast<ma_uint32>(kSampleRate);
    config.periodSizeInFrames = static_cast<ma_uint32>(kPeriodFrames);
    config.dataCallback      = data_callback;
    config.pUserData         = nullptr;

    if (ma_device_init(nullptr, &config, &g_device) != MA_SUCCESS) {
        return; // Initialisation failed; remain uninitialised.
    }

    if (ma_device_start(&g_device) != MA_SUCCESS) {
        ma_device_uninit(&g_device);
        return;
    }

    g_deviceInitialized = true;
}

void mixer_push_frames(uint16_t clientId, const float* pcm, int frameCount) {
    if (clientId >= MAX_CLIENTS) return;
    if (pcm == nullptr || frameCount <= 0) return;

    ClientState& c = g_clients[clientId];

    // Mark the slot as active the first time data arrives.
    c.active.store(true, std::memory_order_release);

    const size_t totalSamples = static_cast<size_t>(frameCount) * kChannels;
    size_t available = rb_available_write(c);

    // Drop frames that would overflow the ring buffer.
    size_t toWrite = std::min(available, totalSamples);

    size_t w = c.writeHead.load(std::memory_order_relaxed);

    for (size_t i = 0; i < toWrite; ++i) {
        c.buf[w % kRingBufSamples] = pcm[i];
        ++w;
    }

    c.writeHead.store(w % kRingBufSamples, std::memory_order_release);
}

void mixer_set_volume(uint16_t clientId, float volume) {
    if (clientId >= MAX_CLIENTS) return;
    // Clamp to [0.0, 1.0].
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    g_clients[clientId].volume.store(volume, std::memory_order_relaxed);
}

void mixer_remove_client(uint16_t clientId) {
    if (clientId >= MAX_CLIENTS) return;

    ClientState& c = g_clients[clientId];

    // Deactivate first so the audio callback skips this slot immediately.
    c.active.store(false, std::memory_order_release);

    // Clear the ring buffer and reset heads.
    c.buf.fill(0.0f);
    c.writeHead.store(0, std::memory_order_relaxed);
    c.readHead.store(0, std::memory_order_relaxed);
    c.volume.store(1.0f, std::memory_order_relaxed);
}

void mixer_destroy(void) {
    if (!g_deviceInitialized) return;

    ma_device_stop(&g_device);
    ma_device_uninit(&g_device);
    g_deviceInitialized = false;
}

} // extern "C"
