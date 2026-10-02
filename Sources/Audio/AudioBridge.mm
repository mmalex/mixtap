#import "AudioBridge.h"
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <unistd.h>
#include "AudioCore.hpp"
#include "WaveWriter.hpp"
#include <chrono>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace mixtap;
namespace {
AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}
template<class T> OSStatus property(AudioObjectID object, AudioObjectPropertySelector selector,
                                    T& value, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    auto a = address(selector, scope);
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(object, &a, 0, nullptr, &size, &value);
}
NSString* stringProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    CFStringRef value = nullptr;
    if (property(object, selector, value) != noErr || !value) return @"";
    return CFBridgingRelease(value);
}
NSString* statusMessage(NSString* operation, OSStatus status) {
    return [NSString stringWithFormat:@"%@ (Core Audio error %d).", operation, (int)status];
}
bool report(OSStatus status, NSString* operation, NSError** error) {
    if (status == noErr) return true;
    if (error) *error = [NSError errorWithDomain:@"MixTap" code:status
                                      userInfo:@{NSLocalizedDescriptionKey:statusMessage(operation, status)}];
    return false;
}
double tickSeconds() {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return double(info.numer) / double(info.denom) / 1e9;
}
const double secondsPerTick = tickSeconds();
double nowSeconds() { return mach_absolute_time() * secondsPerTick; }

struct Source {
    AudioDeviceID device = 0;
    AudioDeviceIOProcID proc = nullptr;
    AudioStreamBasicDescription format{};
    bool mono = false;
    bool started = false;
    Timeline timeline;
    std::atomic<uint64_t> callbacks{0};
    std::atomic<double> lastCallbackTime{0};
    std::atomic<bool> invalid{false};

    static OSStatus callback(AudioDeviceID, const AudioTimeStamp*, const AudioBufferList* input,
                             const AudioTimeStamp* inputTime, AudioBufferList*, const AudioTimeStamp*, void* context) {
        auto& self = *static_cast<Source*>(context);
        if (!input || input->mNumberBuffers == 0) return noErr;
        if (!(inputTime->mFlags & kAudioTimeStampHostTimeValid)) {
            self.invalid.store(true, std::memory_order_relaxed);
            return noErr;
        }
        const auto& first = input->mBuffers[0];
        if (!first.mNumberChannels || !first.mData || !first.mDataByteSize) return noErr;
        UInt32 frames = first.mDataByteSize / (sizeof(float) * first.mNumberChannels);
        if (frames == 0) return noErr;
        if (frames > maxFrames) {
            self.invalid.store(true, std::memory_order_relaxed);
            return noErr;
        }
        const float* left = static_cast<const float*>(first.mData);
        const float* right = left;
        UInt32 leftStride = first.mNumberChannels, rightStride = leftStride;
        if (!self.mono) {
            if (first.mNumberChannels >= 2) right = left + 1;
            else if (input->mNumberBuffers > 1) {
                const auto& second = input->mBuffers[1];
                if (!second.mData || !second.mNumberChannels ||
                    second.mDataByteSize < frames * sizeof(float) * second.mNumberChannels) {
                    self.invalid.store(true, std::memory_order_relaxed);
                    return noErr;
                }
                right = static_cast<const float*>(second.mData);
                rightStride = second.mNumberChannels;
            }
        }
        auto* packet = self.timeline.beginWrite();
        if (!packet) return noErr;
        packet->time = inputTime->mHostTime * secondsPerTick;
        packet->rate = self.format.mSampleRate;
        packet->frames = frames;
        for (UInt32 i = 0; i < frames; ++i) {
            float l = left[i * leftStride], r = right[i * rightStride];
            packet->samples[i] = {std::isfinite(l) ? l : 0, std::isfinite(r) ? r : 0};
        }
        self.timeline.endWrite();
        self.lastCallbackTime.store(packet->time, std::memory_order_relaxed);
        self.callbacks.fetch_add(1, std::memory_order_relaxed);
        return noErr;
    }
    bool prepare(AudioDeviceID id, bool asMono, NSError** error) {
        device = id;
        mono = asMono;
        if (!report(property(device, kAudioDevicePropertyStreamFormat, format, kAudioObjectPropertyScopeInput),
                    @"Could not read the input format", error)) return false;
        if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat) ||
            (format.mFormatFlags & kAudioFormatFlagIsBigEndian) || format.mBitsPerChannel != 32 ||
            format.mSampleRate < 8000 || format.mSampleRate > 192000 || format.mChannelsPerFrame < 1) {
            if (error) *error = [NSError errorWithDomain:@"MixTap" code:-1 userInfo:@{NSLocalizedDescriptionKey:
                @"This prototype needs a native 32-bit float input between 8 and 192 kHz. Choose another input device."}];
            return false;
        }
        return report(AudioDeviceCreateIOProcID(device, callback, this, &proc), @"Could not create the capture callback", error);
    }
    bool start(NSError** error) {
        if (!report(AudioDeviceStart(device, proc), @"Could not start audio capture. Check Microphone and Screen & System Audio Recording permissions in System Settings", error)) return false;
        started = true;
        return true;
    }
    void stop() {
        if (started) AudioDeviceStop(device, proc);
        if (proc) AudioDeviceDestroyIOProcID(device, proc);
        proc = nullptr;
        started = false;
    }
    bool unchanged() {
        UInt32 alive = 0;
        AudioStreamBasicDescription current{};
        return property(device, kAudioDevicePropertyDeviceIsAlive, alive) == noErr && alive &&
            property(device, kAudioDevicePropertyStreamFormat, current, kAudioObjectPropertyScopeInput) == noErr &&
            current.mSampleRate == format.mSampleRate && current.mFormatID == format.mFormatID &&
            current.mFormatFlags == format.mFormatFlags && current.mChannelsPerFrame == format.mChannelsPerFrame &&
            current.mBitsPerChannel == format.mBitsPerChannel;
    }
    ~Source() { stop(); }
};

struct Recorder {
    Source desktop, mic;
    Mixer mixer;
    AudioObjectID tap = 0;
    AudioDeviceID aggregate = 0, originalOutput = 0;
    WaveWriter file;
    std::thread worker;
    std::atomic<bool> stopping{false};
    std::atomic<double> endTime{0};
    std::atomic<float> desktopDB{-6}, micDB{-6};
    std::atomic<bool> desktopMuted{false}, micMuted{false};
    std::atomic<float> desktopPeak{0}, micPeak{0}, mixPeak{0};
    std::atomic<uint64_t> framesWritten{0}, desktopMissing{0}, micMissing{0};
    double startTime = 0;
    std::mutex errorMutex;
    std::string error;

    void fail(NSString* message) {
        std::lock_guard<std::mutex> guard(errorMutex);
        if (error.empty()) error = message.UTF8String;
    }
    NSString* failure() {
        std::lock_guard<std::mutex> guard(errorMutex);
        return error.empty() ? nil : [NSString stringWithUTF8String:error.c_str()];
    }
    void run() {
        @autoreleasepool {
            std::array<Stereo, renderFrames> output;
            uint64_t frame = 0, healthCounter = 0;
            while (true) {
                const bool finish = stopping.load(std::memory_order_acquire);
                const double availableUntil = finish ? endTime.load() : nowSeconds() - 0.15;
                // Never silently turn a long worker stall into a huge run of missing audio.
                if (availableUntil - (startTime + frame / outputRate) > 1.0) {
                    fail(@"Recording stopped because the audio writer fell behind. The partial WAV has been saved.");
                    break;
                }
                auto available = static_cast<int64_t>(std::floor((availableUntil - startTime) * outputRate)) - static_cast<int64_t>(frame);
                if (available < renderFrames && !finish) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(5));
                    continue;
                }
                if (available <= 0 && finish) break;
                const uint32_t count = static_cast<uint32_t>(std::min<int64_t>(available, renderFrames));
                auto stats = mixer.render(desktop.timeline, mic.timeline, startTime, frame, count,
                    desktopMuted.load() ? 0 : gainFromDB(desktopDB.load()),
                    micMuted.load() ? 0 : gainFromDB(micDB.load()), output.data());
                OSStatus status = file.write(output.data(), count);
                if (status != noErr) {
                    fail(statusMessage(@"Could not write the WAV. Check free disk space", status));
                    break;
                }
                frame += count;
                framesWritten.store(frame);
                desktopPeak.store(std::max(stats.desktopPeak, desktopPeak.load() * 0.94f));
                micPeak.store(std::max(stats.micPeak, micPeak.load() * 0.94f));
                mixPeak.store(std::max(stats.mixPeak, mixPeak.load() * 0.94f));
                desktopMissing.fetch_add(stats.desktopMissing);
                micMissing.fetch_add(stats.micMissing);
                if (frame * sizeof(Stereo) > 3'800'000'000ULL) {
                    fail(@"Recording stopped before the WAV size limit (about 2 hours 45 minutes). Start a new recording to continue.");
                    break;
                }
                if (++healthCounter % 100 == 0 && !finish) {
                    AudioDeviceID outputDevice = 0;
                    property(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, outputDevice);
                    if (!mic.unchanged() || !desktop.unchanged() || outputDevice != originalOutput ||
                        mic.invalid.load() || desktop.invalid.load()) {
                        fail(@"An audio device, format, or output route changed. The WAV has been saved. Check your devices and start a new recording.");
                        break;
                    }
                    if (frame > outputRate * 3 && nowSeconds() - mic.lastCallbackTime.load() > 2.0) {
                        fail(@"The microphone delivered no audio. Check its connection and Microphone permission in System Settings.");
                        break;
                    }
                }
            }
        }
    }
    NSString* stop() {
        // Capture the endpoint before stopping IO. Join before destroying any ring or file.
        if (worker.joinable()) {
            endTime.store(nowSeconds());
            desktop.stop();
            mic.stop();
            stopping.store(true, std::memory_order_release);
            worker.join();
        } else {
            desktop.stop();
            mic.stop();
        }
        auto status = file.close();
        if (status != noErr) fail(statusMessage(@"Could not finalize the WAV", status));
        if (aggregate) { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0; }
        if (tap) { AudioHardwareDestroyProcessTap(tap); tap = 0; }
        return failure();
    }
    ~Recorder() { stop(); }
};
}

@implementation MTInputDevice
- (instancetype)initWithID:(AudioDeviceID)device {
    if ((self = [super init])) {
        _deviceID = device;
        _uid = stringProperty(device, kAudioDevicePropertyDeviceUID);
        _name = stringProperty(device, kAudioObjectPropertyName);
    }
    return self;
}
@end

@implementation MTAudioRecorder {
    std::unique_ptr<Recorder> _recorder;
}
- (instancetype)init {
    if ((self = [super init])) _recorder = std::make_unique<Recorder>();
    return self;
}
+ (NSArray<MTInputDevice*>*)inputDevices {
    auto a = address(kAudioHardwarePropertyDevices);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size) != noErr) return @[];
    std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data()) != noErr) return @[];
    NSMutableArray* devices = [NSMutableArray array];
    for (auto id : ids) {
        auto config = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput);
        UInt32 bytes = 0;
        if (AudioObjectGetPropertyDataSize(id, &config, 0, nullptr, &bytes) != noErr || !bytes) continue;
        std::vector<uint8_t> storage(bytes);
        auto* list = reinterpret_cast<AudioBufferList*>(storage.data());
        if (AudioObjectGetPropertyData(id, &config, 0, nullptr, &bytes, list) != noErr) continue;
        UInt32 channels = 0;
        for (UInt32 i = 0; i < list->mNumberBuffers; ++i) channels += list->mBuffers[i].mNumberChannels;
        if (channels) [devices addObject:[[MTInputDevice alloc] initWithID:id]];
    }
    return [devices sortedArrayUsingComparator:^NSComparisonResult(MTInputDevice* a, MTInputDevice* b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}
+ (NSString*)defaultInputUID {
    AudioDeviceID id = 0;
    property(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice, id);
    return stringProperty(id, kAudioDevicePropertyDeviceUID);
}
- (float)desktopDB { return _recorder->desktopDB.load(); }
- (void)setDesktopDB:(float)value { _recorder->desktopDB.store(std::clamp(value, -60.0f, 12.0f)); }
- (float)microphoneDB { return _recorder->micDB.load(); }
- (void)setMicrophoneDB:(float)value { _recorder->micDB.store(std::clamp(value, -60.0f, 12.0f)); }
- (BOOL)desktopMuted { return _recorder->desktopMuted.load(); }
- (void)setDesktopMuted:(BOOL)value { _recorder->desktopMuted.store(value); }
- (BOOL)microphoneMuted { return _recorder->micMuted.load(); }
- (void)setMicrophoneMuted:(BOOL)value { _recorder->micMuted.store(value); }
- (float)desktopPeak { return _recorder->desktopPeak.load(); }
- (float)microphonePeak { return _recorder->micPeak.load(); }
- (float)mixPeak { return _recorder->mixPeak.load(); }
- (double)duration { return _recorder->framesWritten.load() / outputRate; }
- (uint64_t)droppedPackets { return _recorder->desktop.timeline.dropped.load() + _recorder->mic.timeline.dropped.load(); }
- (uint64_t)microphoneMissingFrames { return _recorder->micMissing.load(); }
- (uint64_t)desktopMissingFrames { return _recorder->desktopMissing.load(); }
- (BOOL)desktopReceiving { return _recorder->desktop.callbacks.load() > 0; }
- (BOOL)microphoneReceiving { return _recorder->mic.callbacks.load() > 0; }
- (NSString*)failure { return _recorder->failure(); }
- (BOOL)startWithInput:(uint32_t)deviceID URL:(NSURL*)url error:(NSError**)error {
    auto& r = *_recorder;
    if (r.worker.joinable()) return report(-1, @"A recording is already running", error);
    property(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, r.originalOutput);
    auto* description = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    description.name = @"MixTap Desktop";
    description.privateTap = YES;
    description.muteBehavior = CATapUnmuted;
    // Exclude our own process, ready for any future in-app audition feature.
    pid_t pid = getpid();
    AudioObjectID process = 0;
    auto pidAddress = address(kAudioHardwarePropertyTranslatePIDToProcessObject);
    UInt32 processSize = sizeof(process);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &pidAddress, sizeof(pid), &pid, &processSize, &process) == noErr && process)
        description.processes = @[@(process)];
    if (!report(AudioHardwareCreateProcessTap(description, &r.tap), @"Could not create the desktop audio tap", error)) return NO;
    NSString* tapUID = stringProperty(r.tap, kAudioTapPropertyUID);
    NSDictionary* config = @{
        @kAudioAggregateDeviceNameKey: @"MixTap Private Capture",
        @kAudioAggregateDeviceUIDKey: [@"dev.mixtap.capture." stringByAppendingString:NSUUID.UUID.UUIDString],
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceTapAutoStartKey: @NO,
        @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: tapUID,
                                             @kAudioSubTapDriftCompensationKey: @YES}],
        @kAudioAggregateDeviceSubDeviceListKey: @[]
    };
    if (!report(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config, &r.aggregate),
                @"Could not create the private desktop capture device", error)) { r.stop(); return NO; }
    if (!r.desktop.prepare(r.aggregate, false, error) || !r.mic.prepare(deviceID, true, error)) { r.stop(); return NO; }
    // Do not overwrite an existing file, even if the save panel allowed replacement.
    if (!report(r.file.open((__bridge CFURLRef)url),
                @"Could not create the WAV. Choose a new filename in a writable folder", error)) { r.stop(); return NO; }
    if (!r.desktop.start(error) || !r.mic.start(error)) { r.stop(); return NO; }
    r.startTime = nowSeconds();
    r.worker = std::thread([&r] { r.run(); });
    return YES;
}
- (NSString*)stop { return _recorder->stop(); }
@end
