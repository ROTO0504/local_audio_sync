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

    // 再生中フラグ。false のときは「プリバッファ充填待ち」で、リングが
    // 目標深さ(g_prebufferFrames)に達するまで出力せず溜める。枯渇したら
    // false に戻して溜め直す(= アンダーランの連鎖を断つ)。
    std::atomic<bool> playing{false};

    // 診断カウンタ(フレーム単位、単調増加)。
    // underrun: 再生要求に対しリングが枯渇し無音で埋めた分。
    // overrun : 書き込み時にリングが満杯で捨てた分。
    std::atomic<uint64_t> underrunFrames{0};
    std::atomic<uint64_t> overrunFrames{0};
};

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static ClientState  g_clients[MAX_CLIENTS];
static ma_device    g_device;
static bool         g_deviceInitialized = false;

// プリバッファ / 目標再生バッファ深さ(オーディオフレーム)。再生開始前に
// この深さまで溜め、枯渇したら溜め直す。ジッタ耐性と遅延のトレードオフ。
// 既定 80ms。mixer_set_target_latency_ms で変更可能。
static std::atomic<int> g_prebufferFrames{ (kSampleRate / 1000) * 80 };

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

        size_t available = rb_available_read(c);

        // プリバッファゲート: 目標深さに達するまで再生を始めない。到着ジッタで
        // リングが一瞬枯れても細切れアンダーランを起こさないよう、先に溜める。
        if (!c.playing.load(std::memory_order_acquire)) {
            const size_t prebuf =
                static_cast<size_t>(g_prebufferFrames.load(std::memory_order_relaxed))
                * kChannels;
            if (available >= prebuf) {
                c.playing.store(true, std::memory_order_release);
            } else {
                // まだ充填待ち → 今回このクライアントは無音(出力は memset 済み)。
                continue;
            }
        }

        float vol = c.volume.load(std::memory_order_relaxed);
        size_t toRead = std::min(available, totalSamples);

        size_t r = c.readHead.load(std::memory_order_relaxed);

        for (size_t i = 0; i < toRead; ++i) {
            out[i] += c.buf[r % kRingBufSamples] * vol;
            ++r;
        }

        c.readHead.store(r % kRingBufSamples, std::memory_order_release);

        // リング枯渇分は無音のまま(memset 済み)。診断のため計上し、再生を
        // 止めてプリバッファから溜め直す(アンダーランの連鎖を断つ)。
        if (toRead < totalSamples) {
            c.underrunFrames.fetch_add(
                (totalSamples - toRead) / kChannels, std::memory_order_relaxed);
            c.playing.store(false, std::memory_order_release);
        }
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
        g_clients[i].playing.store(false, std::memory_order_relaxed);
        g_clients[i].underrunFrames.store(0, std::memory_order_relaxed);
        g_clients[i].overrunFrames.store(0, std::memory_order_relaxed);
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

    // 満杯で書けなかった分は overrun として計上する。
    if (toWrite < totalSamples) {
        c.overrunFrames.fetch_add(
            (totalSamples - toWrite) / kChannels, std::memory_order_relaxed);
    }
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
    c.playing.store(false, std::memory_order_relaxed);
    c.underrunFrames.store(0, std::memory_order_relaxed);
    c.overrunFrames.store(0, std::memory_order_relaxed);
}

void mixer_set_target_latency_ms(int ms) {
    if (ms < 20)  ms = 20;
    if (ms > 500) ms = 500;
    g_prebufferFrames.store(ms * (kSampleRate / 1000), std::memory_order_relaxed);
}

void mixer_stats(uint16_t clientId, int64_t* out, int outLen) {
    if (out == nullptr || outLen <= 0) return;
    // 呼び出し側が確保したスロットを 0 埋めしておく。
    for (int i = 0; i < outLen; ++i) out[i] = 0;
    if (clientId >= MAX_CLIENTS) return;

    ClientState& c = g_clients[clientId];
    const size_t depthSamples = rb_available_read(c);

    // out[0]=リング深さ(frames), [1]=underrun累計(frames),
    // [2]=overrun累計(frames), [3]=active(0/1)
    if (outLen > 0) out[0] = static_cast<int64_t>(depthSamples / kChannels);
    if (outLen > 1) out[1] = static_cast<int64_t>(c.underrunFrames.load(std::memory_order_relaxed));
    if (outLen > 2) out[2] = static_cast<int64_t>(c.overrunFrames.load(std::memory_order_relaxed));
    if (outLen > 3) out[3] = c.active.load(std::memory_order_relaxed) ? 1 : 0;
}

void mixer_destroy(void) {
    if (!g_deviceInitialized) return;

    ma_device_stop(&g_device);
    ma_device_uninit(&g_device);
    g_deviceInitialized = false;
}

// ===========================================================================
// Loopback (WASAPI loopback) implementation
// ===========================================================================

namespace loopback {

// Float→Int16 変換用クランプ
static inline int16_t to_int16(float v) {
    if (v > 1.0f) v = 1.0f;
    else if (v < -1.0f) v = -1.0f;
    return static_cast<int16_t>(v * 32767.0f);
}

static constexpr size_t kRingFrames   = LOOPBACK_RING_FRAMES;
static constexpr size_t kRingSamples  = kRingFrames * kChannels;

// SPSC リングバッファ(PCM16 ステレオ)。
struct LoopbackRing {
    std::array<int16_t, kRingSamples> buf{};
    std::atomic<size_t> writeHead{0};
    std::atomic<size_t> readHead{0};

    size_t availableRead() const {
        size_t w = writeHead.load(std::memory_order_acquire);
        size_t r = readHead.load(std::memory_order_relaxed);
        return (w - r + kRingSamples) % kRingSamples;
    }
    size_t availableWrite() const {
        size_t avail_read = availableRead();
        if (avail_read >= kRingSamples - 1) return 0;
        return (kRingSamples - 1) - avail_read;
    }
};

static LoopbackRing g_ring;
static ma_device    g_loopDevice;
static bool         g_loopInitialized = false;
static std::atomic<bool> g_loopRunning{false};

// miniaudio の loopback コールバック。Float32 ステレオで来る前提で書く。
static void loopback_data_callback(
    ma_device*  pDevice,
    void*       pOutput,
    const void* pInput,
    ma_uint32   frameCount)
{
    (void)pDevice;
    (void)pOutput;
    if (pInput == nullptr || frameCount == 0) return;

    const float* in = static_cast<const float*>(pInput);
    const size_t totalSamples = static_cast<size_t>(frameCount) * kChannels;

    size_t available = g_ring.availableWrite();
    size_t toWrite = std::min(available, totalSamples);

    size_t w = g_ring.writeHead.load(std::memory_order_relaxed);
    for (size_t i = 0; i < toWrite; ++i) {
        g_ring.buf[w % kRingSamples] = to_int16(in[i]);
        ++w;
    }
    g_ring.writeHead.store(w % kRingSamples, std::memory_order_release);
    // オーバーフロー分は黙って捨てる(送信側 pacing が壊れているとき以外発生しない)
}

} // namespace loopback

int loopback_start(void) {
    using namespace loopback;
    if (g_loopRunning.load()) return 1;

    ma_device_config config = ma_device_config_init(ma_device_type_loopback);
    config.capture.pDeviceID = nullptr;          // デフォルト出力デバイスをループバック
    config.capture.format    = ma_format_f32;    // miniaudio の loopback はネイティブで f32
    config.capture.channels  = kChannels;        // ステレオに揃える(SRC は miniaudio 任せ)
    config.sampleRate        = kSampleRate;      // 48 kHz
    config.dataCallback      = loopback_data_callback;
    config.pUserData         = nullptr;

    if (ma_device_init(nullptr, &config, &g_loopDevice) != MA_SUCCESS) {
        return 2;
    }
    g_loopInitialized = true;

    // バッファをクリア
    g_ring.writeHead.store(0);
    g_ring.readHead.store(0);

    if (ma_device_start(&g_loopDevice) != MA_SUCCESS) {
        ma_device_uninit(&g_loopDevice);
        g_loopInitialized = false;
        return 3;
    }
    g_loopRunning.store(true);
    return 0;
}

void loopback_stop(void) {
    using namespace loopback;
    if (!g_loopRunning.load() && !g_loopInitialized) return;

    if (g_loopInitialized) {
        ma_device_stop(&g_loopDevice);
        ma_device_uninit(&g_loopDevice);
        g_loopInitialized = false;
    }
    g_loopRunning.store(false);

    // バッファクリア
    g_ring.buf.fill(0);
    g_ring.writeHead.store(0);
    g_ring.readHead.store(0);
}

int loopback_read_pcm16(int16_t* buffer, int maxFrames) {
    using namespace loopback;
    if (buffer == nullptr || maxFrames <= 0) return 0;

    const size_t requestedSamples =
        static_cast<size_t>(maxFrames) * kChannels;
    const size_t availableSamples = g_ring.availableRead();
    const size_t toRead = std::min(requestedSamples, availableSamples);

    size_t r = g_ring.readHead.load(std::memory_order_relaxed);
    for (size_t i = 0; i < toRead; ++i) {
        buffer[i] = g_ring.buf[r % kRingSamples];
        ++r;
    }
    g_ring.readHead.store(r % kRingSamples, std::memory_order_release);

    return static_cast<int>(toRead / kChannels);
}

int loopback_pending_frames(void) {
    using namespace loopback;
    return static_cast<int>(g_ring.availableRead() / kChannels);
}

int loopback_is_running(void) {
    using namespace loopback;
    return g_loopRunning.load() ? 1 : 0;
}

} // extern "C"
