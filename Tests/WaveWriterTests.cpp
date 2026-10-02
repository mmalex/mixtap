#include "../Sources/Audio/WaveWriter.hpp"
#include <iostream>
#include <vector>
#include <unistd.h>
using namespace mixtap;
void check(bool condition, const char* message) {
    if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
int main() {
    const char* path = "build/tests/synthetic.wav";
    unlink(path);
    auto url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8*>(path), strlen(path), false);
    WaveWriter writer;
    check(writer.open(url) == noErr, "create WAV");
    WaveWriter duplicate;
    check(duplicate.open(url) != noErr, "refuse to overwrite WAV");
    std::vector<Stereo> signal(48000);
    for (size_t i = 0; i < signal.size(); ++i) signal[i] = {float(i) / 24000, -float(i) / 48000};
    // Values above full scale are intentionally preserved in float WAVs.
    for (size_t i = 0; i < signal.size(); i += 480) check(writer.write(signal.data() + i, 480) == noErr, "write frames");
    check(writer.close() == noErr && writer.close() == noErr, "finalize WAV, including repeated stop");
    check(writer.write(signal.data(), 480) != noErr, "reject writes after close");
    AudioFileID file = nullptr;
    check(AudioFileOpenURL(url, kAudioFileReadPermission, 0, &file) == noErr, "reopen finalized WAV");
    AudioStreamBasicDescription format{};
    UInt32 size = sizeof(format);
    check(AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr, "read WAV format");
    check(format.mSampleRate == 48000 && format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32 &&
        (format.mFormatFlags & kAudioFormatFlagIsFloat), "48 kHz stereo float WAV metadata");
    UInt64 bytes = 0; size = sizeof(bytes);
    check(AudioFileGetProperty(file, kAudioFilePropertyAudioDataByteCount, &size, &bytes) == noErr && bytes == signal.size() * sizeof(Stereo), "exact WAV length");
    std::vector<Stereo> readback(signal.size());
    size = static_cast<UInt32>(bytes);
    check(AudioFileReadBytes(file, false, 0, &size, readback.data()) == noErr, "read WAV audio");
    check(memcmp(readback.data(), signal.data(), bytes) == 0, "sample-exact stereo readback including overrange peaks");
    AudioFileClose(file);
    CFRelease(url);
    std::cout << "PASS: WAV format, exact duration, sample readback, overrange preservation, finalization, and overwrite protection\n";
}
