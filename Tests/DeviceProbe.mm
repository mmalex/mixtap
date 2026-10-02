#import "../Sources/Audio/AudioBridge.h"
#import <Foundation/Foundation.h>
int main() {
    @autoreleasepool {
        printf("Default input UID: %s\n", [MTAudioRecorder defaultInputUID].UTF8String);
        auto devices = [MTAudioRecorder inputDevices];
        for (MTInputDevice* device in devices) printf("Input %u: %s\n", device.deviceID, device.name.UTF8String);
        printf("%lu input devices found. No capture was started.\n", (unsigned long)devices.count);
        return devices.count ? 0 : 1;
    }
}
