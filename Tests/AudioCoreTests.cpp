#include "../Sources/Audio/AudioCore.hpp"
#include <cstdlib>
#include <iostream>
#include <thread>
#include <vector>
using namespace mixtap;
void check(bool condition, const char* message) {
    if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
void push(Timeline& timeline, double time, double rate, uint32_t count, float left, float right) {
    auto* p = timeline.beginWrite();
    check(p != nullptr, "ring unexpectedly full");
    p->time = time; p->rate = rate; p->frames = count;
    for (uint32_t i = 0; i < count; ++i) p->samples[i] = {left, right};
    timeline.endWrite();
}
void testMixAndMute() {
    Timeline desktop, mic;
    push(desktop, 10, 48000, 960, 0.2f, -0.4f);
    push(mic, 10, 48000, 960, 0.1f, 0.1f);
    Mixer mixer;
    Stereo output[480];
    auto stats = mixer.render(desktop, mic, 10, 0, 480, 1, 1, output);
    check(std::abs(output[479].left - 0.3f) < 0.00001f, "desktop and centered mic mix at unity");
    check(std::abs(output[479].right + 0.3f) < 0.00001f, "stereo is preserved");
    check(stats.micMissing == 0 && stats.desktopMissing == 0, "no missing samples in valid data");
    mixer.render(desktop, mic, 10, 480, 480, 0, 0, output);
    check(std::abs(output[479].left) < 0.00001f && std::abs(output[479].right) < 0.00001f, "mute ramps to silence");
    check(gainFromDB(0) == 1 && std::abs(gainFromDB(-6) - 0.501187f) < 0.00001f, "decibel conversion");
}
void testGapsAndOverflow() {
    Timeline timeline;
    Stereo sample{1, 1};
    check(!timeline.sample(0, sample) && sample.left == 0, "empty ring returns silence");
    push(timeline, 1, 48000, 480, 1, 1);
    push(timeline, 1.1, 48000, 480, 2, 2);
    check(!timeline.sample(0.9, sample), "future audio is not played early");
    check(timeline.sample(1.005, sample) && sample.left == 1, "packet audio");
    check(!timeline.sample(1.05, sample) && sample.left == 0, "gap is silence, not stretched audio");
    check(timeline.sample(1.105, sample) && sample.left == 2, "recovers after gap");
    Timeline full;
    for (uint32_t i = 0; i < packetCount; ++i) push(full, double(i), 48000, 1, float(i), float(i));
    check(full.beginWrite() == nullptr && full.dropped == 1, "overflow drops newest without blocking");
    check(full.sample(127, sample) && sample.left == 127, "consumer can catch up");
    push(full, 128, 48000, 1, 128, 128);
    check(full.sample(128, sample) && sample.left == 128, "ring wraps without corrupting data");
}
void testDrift(double nominal, double ppm) {
    Timeline timeline;
    constexpr uint32_t block = 441;
    const double actual = nominal * (1 + ppm / 1e6);
    const double origin = 12345.0;
    uint64_t sourceFrame = 0;
    double nextTime = origin;
    // Simulate 30 minutes at 48 kHz, checking every 79th output sample. Producer
    // timestamps use the drifting clock; packet.rate is only the nominal rate.
    for (uint64_t frame = 0; frame < 1800ULL * 48000; frame += 79) {
        double time = origin + frame / outputRate;
        while (nextTime < time + .05) {
            auto* p = timeline.beginWrite();
            check(p != nullptr, "drift simulation must remain bounded");
            p->time = nextTime; p->rate = nominal; p->frames = block;
            for (uint32_t i = 0; i < block; ++i) {
                double t = (sourceFrame + i) / actual;
                float signal = static_cast<float>(std::sin(2 * 3.141592653589793 * 37 * t));
                p->samples[i] = {signal, -signal};
            }
            timeline.endWrite();
            sourceFrame += block;
            nextTime = origin + sourceFrame / actual;
        }
        Stereo sample;
        check(timeline.sample(time, sample), "no drift-induced dropout");
        float expected = static_cast<float>(std::sin(2 * 3.141592653589793 * 37 * frame / outputRate));
        check(std::abs(sample.left - expected) < 0.00015, "timestamp alignment must not accumulate drift");
        check(sample.left == -sample.right, "channel alignment");
    }
    check(timeline.dropped == 0, "no drift-induced overflow");
}
void testConcurrentRing() {
    Timeline timeline;
    constexpr uint32_t count = 100000;
    std::atomic<bool> done{false};
    std::thread producer([&] {
        for (uint32_t i = 0; i < count; ++i) {
            Packet* p;
            while (!(p = timeline.beginWrite())) std::this_thread::yield();
            p->time = double(i); p->rate = 48000; p->frames = 1;
            p->samples[0] = {float(i), -float(i)};
            timeline.endWrite();
        }
        done.store(true);
    });
    Stereo sample;
    for (uint32_t i = 0; i < count; ++i) {
        while (!timeline.sample(double(i), sample)) std::this_thread::yield();
        check(sample.left == float(i) && sample.right == -float(i), "concurrent packet publication");
    }
    producer.join();
    check(done, "producer completed");
}
int main() {
    testMixAndMute();
    testGapsAndOverflow();
    testDrift(44100, 250);
    testDrift(48000, -250);
    testConcurrentRing();
    std::cout << "PASS: mixing, gain ramps, silence, gaps, overflow, wraparound, concurrent publication, and 2 × 30-minute clock-drift simulations\n";
}
