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

/// Test-only capture that substitutes the whole voice-processing step of the start path.
/// Enabling Apple's voice-processing unit needs a live input audio unit — and an unsigned
/// xctest host that reaches for one stalls on the microphone permission check — so the
/// ordering guarantee (voice processing settles before anything else in the start does)
/// is proved against this stub instead.
@interface TapQStubbedVoiceProcessingCaptureEngine : TapQAudioCaptureEngine

/// When YES the stub reports a `voice_processing`-stage failure instead of succeeding.
@property(nonatomic) BOOL failsVoiceProcessing;

@property(nonatomic, readonly) NSUInteger voiceProcessingCallCount;

/// `tapInstalled` sampled at the moment the stub ran. Must be NO: nothing may be attached
/// to the input node before the voice-processing transition has settled.
@property(nonatomic, readonly) BOOL tapWasInstalledWhenApplied;

@end

NS_ASSUME_NONNULL_END

#endif
