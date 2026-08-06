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

// MARK: - Playback engine

FOUNDATION_EXPORT NSString * const TapQAudioPlaybackErrorDomain;
FOUNDATION_EXPORT NSString * const TapQAudioPlaybackFailureStageKey;

/// Owns one `AVAudioEngine` + `AVAudioPlayerNode` for backend response playback. All
/// operations that may raise an AVFAudio NSException are performed by the typed Objective-C
/// functions below, so an exception never unwinds through a Swift frame.
@interface TapQAudioPlaybackEngine : NSObject

@property(nonatomic, strong, readonly) AVAudioEngine *engine;
@property(nonatomic, strong, readonly) AVAudioPlayerNode *player;

- (instancetype)init;

@end

/// Starts the engine and prepares the player node for the given PCM format.
///
/// The engine connects the player node to the main mixer in the declared format.
/// Returns NO and sets `*error` on failure (both NSError from `startAndReturnError:`
/// and NSException from any AVFAudio call).
FOUNDATION_EXPORT BOOL TapQAudioPlaybackEngineStart(
    TapQAudioPlaybackEngine *playback,
    double sampleRate,
    AVAudioChannelCount channels,
    NSError * _Nullable * _Nullable error
);

/// Schedules an `AVAudioPCMBuffer` on the player node with a completion handler.
///
/// The completion fires on an internal AVAudioEngine thread; the Swift caller must hop
/// to @MainActor before touching shared state.
FOUNDATION_EXPORT BOOL TapQAudioPlaybackEngineSchedule(
    TapQAudioPlaybackEngine *playback,
    AVAudioPCMBuffer *buffer,
    void (^_Nullable completion)(void),
    NSError * _Nullable * _Nullable error
);

/// Stops the player node and the engine. Best-effort and idempotent: stop, reset, and
/// engine stop each have an independent exception boundary so cleanup continues if one
/// operation fails.
FOUNDATION_EXPORT BOOL TapQAudioPlaybackEngineStop(
    TapQAudioPlaybackEngine *playback,
    NSError * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END

#endif
