#ifndef TAPQ_AUDIO_CAPTURE_BRIDGE_TEST_SUPPORT_H
#define TAPQ_AUDIO_CAPTURE_BRIDGE_TEST_SUPPORT_H

#import "TapQAudioCaptureBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Test-only capture whose AVAudioEngine raises from route-sensitive accessors.
/// It proves the production bridge catches NSException before returning to Swift.
@interface TapQThrowingAudioCaptureEngine : TapQAudioCaptureEngine

@property(nonatomic, readonly) NSUInteger inputNodeCallCount;
@property(nonatomic, readonly) NSUInteger runningCallCount;
@property(nonatomic, readonly) NSUInteger resetCallCount;

@end

NS_ASSUME_NONNULL_END

#endif
