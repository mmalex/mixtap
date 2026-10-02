#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>

namespace mixtap {
constexpr uint32_t maxFrames = 8192;
constexpr uint32_t packetCount = 128;
constexpr double outputRate = 48000.0;
constexpr uint32_t renderFrames = 480;

inline float gainFromDB(double db) { return static_cast<float>(std::pow(10.0, db / 20.0)); }
struct Stereo { float left = 0, right = 0; };
struct Packet {
    double time = 0;
    double rate = outputRate;
    uint32_t frames = 0;
    std::array<Stereo, maxFrames> samples;
};

// One real-time producer, one worker consumer. All storage is allocated before IO starts.
// The producer never waits, allocates, logs, or touches a file.
class Timeline {
    std::unique_ptr<Packet[]> packets = std::make_unique<Packet[]>(packetCount);
    alignas(64) std::atomic<uint64_t> written{0};
    alignas(64) std::atomic<uint64_t> consumed{0};
public:
    std::atomic<uint64_t> dropped{0};
    Packet* beginWrite() {
        auto w = written.load(std::memory_order_relaxed);
        if (w - consumed.load(std::memory_order_acquire) >= packetCount) {
            dropped.fetch_add(1, std::memory_order_relaxed);
            return nullptr;
        }
        return &packets[w % packetCount];
    }
    void endWrite() { written.fetch_add(1, std::memory_order_release); }

    // Host timestamps, rather than callback arrival times, align independent device clocks.
    // Adjacent block timestamps also provide the effective rate (including clock drift).
    // Linear interpolation is deliberate for this diagnostic prototype; a band-limited
    // asynchronous SRC belongs here before release as a production virtual device.
    bool sample(double time, Stereo& out) {
        out = {};
        auto r = consumed.load(std::memory_order_relaxed);
        const auto w = written.load(std::memory_order_acquire);
        while (r < w) {
            const auto& p = packets[r % packetCount];
            const Packet* next = r + 1 < w ? &packets[(r + 1) % packetCount] : nullptr;
            if (next && time >= next->time) {
                consumed.store(++r, std::memory_order_release);
                continue;
            }
            if (time < p.time || !p.frames) return false;
            double duration = p.frames / p.rate;
            bool adjacent = next && std::abs((next->time - p.time) / duration - 1.0) < 0.02;
            if (adjacent) duration = next->time - p.time;
            double position = (time - p.time) * p.frames / duration;
            if (position >= p.frames) return false;
            auto i = static_cast<uint32_t>(position);
            auto a = p.samples[i];
            auto b = i + 1 < p.frames ? p.samples[i + 1] : (adjacent ? next->samples[0] : a);
            float f = static_cast<float>(position - i);
            out = {a.left + f * (b.left - a.left), a.right + f * (b.right - a.right)};
            return true;
        }
        return false;
    }
};

struct MixStats {
    float desktopPeak = 0, micPeak = 0, mixPeak = 0;
    uint64_t desktopMissing = 0, micMissing = 0;
};
class Mixer {
    float desktopGain = gainFromDB(-6), micGain = gainFromDB(-6);
public:
    MixStats render(Timeline& desktop, Timeline& mic, double startTime, uint64_t firstFrame,
                   uint32_t count, float desktopTarget, float micTarget, Stereo* output) {
        MixStats stats;
        // A short gain ramp avoids clicks when moving a slider or muting a source.
        const float desktopStep = (desktopTarget - desktopGain) / count;
        const float micStep = (micTarget - micGain) / count;
        for (uint32_t i = 0; i < count; ++i) {
            const double time = startTime + (firstFrame + i) / outputRate;
            Stereo d, m;
            if (!desktop.sample(time, d)) ++stats.desktopMissing;
            if (!mic.sample(time, m)) ++stats.micMissing;
            desktopGain += desktopStep;
            micGain += micStep;
            d.left *= desktopGain; d.right *= desktopGain;
            m.left *= micGain; m.right *= micGain;
            output[i] = {d.left + m.left, d.right + m.right};
            stats.desktopPeak = std::max(stats.desktopPeak, std::max(std::abs(d.left), std::abs(d.right)));
            stats.micPeak = std::max(stats.micPeak, std::max(std::abs(m.left), std::abs(m.right)));
            stats.mixPeak = std::max(stats.mixPeak, std::max(std::abs(output[i].left), std::abs(output[i].right)));
        }
        desktopGain = desktopTarget;
        micGain = micTarget;
        return stats;
    }
};
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(sizeof(Stereo) == 2 * sizeof(float));
} // namespace mixtap
