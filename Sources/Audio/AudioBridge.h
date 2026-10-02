#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface MTInputDevice : NSObject
@property(nonatomic, readonly) uint32_t deviceID;
@property(nonatomic, readonly) NSString *uid;
@property(nonatomic, readonly) NSString *name;
@end

@interface MTAudioRecorder : NSObject
+ (NSArray<MTInputDevice *> *)inputDevices;
+ (NSString *)defaultInputUID;
@property(nonatomic) float desktopDB;
@property(nonatomic) float microphoneDB;
@property(nonatomic) BOOL desktopMuted;
@property(nonatomic) BOOL microphoneMuted;
@property(nonatomic, readonly) float desktopPeak;
@property(nonatomic, readonly) float microphonePeak;
@property(nonatomic, readonly) float mixPeak;
@property(nonatomic, readonly) double duration;
@property(nonatomic, readonly) uint64_t droppedPackets;
@property(nonatomic, readonly) uint64_t microphoneMissingFrames;
@property(nonatomic, readonly) uint64_t desktopMissingFrames;
@property(nonatomic, readonly) BOOL desktopReceiving;
@property(nonatomic, readonly) BOOL microphoneReceiving;
@property(nonatomic, readonly, nullable) NSString *failure;
- (BOOL)startWithInput:(uint32_t)deviceID URL:(NSURL *)url error:(NSError **)error;
- (nullable NSString *)stop;
@end
NS_ASSUME_NONNULL_END
