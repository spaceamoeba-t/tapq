#ifndef TAPQ_AUDIO_CAPTURE_BRIDGE_H
#define TAPQ_AUDIO_CAPTURE_BRIDGE_H

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const TapQAudioCaptureErrorDomain;
FOUNDATION_EXPORT NSString * const TapQAudioCaptureFailureStageKey;

FOUNDATION_EXPORT BOOL TapQAudioInputFormatIsUsable(
    double sampleRate,
    AVAudioChannelCount channelCount
);

/// Owns one fresh AVAudioEngine and its exact tapped input node. All operations that
/// may raise an AVFAudio NSException are performed by the typed Objective-C functions
/// below, so an exception never unwinds through a Swift frame.
@interface TapQAudioCaptureEngine : NSObject

@property(nonatomic, strong, readonly) AVAudioEngine *engine;

- (instancetype)init;

@end

FOUNDATION_EXPORT BOOL TapQAudioCaptureEngineStart(
    TapQAudioCaptureEngine *capture,
    AVAudioFrameCount bufferSize,
    AVAudioNodeTapBlock tapBlock,
    NSError * _Nullable * _Nullable error
);

/// Best-effort and idempotent. Stop, tap removal, and reset each have an independent
/// Objective-C exception boundary so cleanup continues if one operation fails.
FOUNDATION_EXPORT BOOL TapQAudioCaptureEngineStop(
    TapQAudioCaptureEngine *capture,
    NSError * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END

#endif
