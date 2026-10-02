#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include "AudioCore.hpp"

namespace mixtap {
// The mixer emits plain interleaved stereo frames. This is its first sink;
// a shared-memory publisher can consume the same frames for the HAL device.
class WaveWriter {
    ExtAudioFileRef file = nullptr;
public:
    OSStatus open(CFURLRef url) {
        if (file) return kAudio_ParamError;
        AudioStreamBasicDescription format{};
        format.mSampleRate = outputRate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        format.mBytesPerPacket = format.mBytesPerFrame = sizeof(Stereo);
        format.mFramesPerPacket = 1;
        format.mChannelsPerFrame = 2;
        format.mBitsPerChannel = 32;
        // No erase flag: an existing recording must never be silently overwritten.
        return ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &format, nullptr, 0, &file);
    }
    OSStatus write(const Stereo* samples, uint32_t frames) {
        if (!file) return kAudio_ParamError;
        AudioBufferList buffers = {1, {{2, static_cast<UInt32>(frames * sizeof(Stereo)), const_cast<Stereo*>(samples)}}};
        return ExtAudioFileWrite(file, frames, &buffers);
    }
    OSStatus close() {
        if (!file) return noErr;
        auto old = file;
        file = nullptr;
        return ExtAudioFileDispose(old);
    }
    ~WaveWriter() { close(); }
    WaveWriter() = default;
    WaveWriter(const WaveWriter&) = delete;
    WaveWriter& operator=(const WaveWriter&) = delete;
};
}
