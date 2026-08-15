#ifndef TAPQ_AUDIO_CAPTURE_BRIDGE_H
#define TAPQ_AUDIO_CAPTURE_BRIDGE_H

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class TapQAudioPlaybackEngine;

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

/// Experimental. When YES, `TapQAudioCaptureEngineStart` turns Apple's voice-processing
/// IO (echo cancellation plus AGC) on for the input node *before* it reads that node's
/// format and installs the tap — the only order AVFAudio accepts, because enabling the
/// unit republishes the node's format. NO (the default) leaves the capture path exactly
/// as it was before the flag existed.
@property(nonatomic) BOOL voiceProcessingEnabled;

/// Whether a tap is currently installed on the input node. Readable so a caller — in
/// practice a test — can prove that a failed voice-processing transition aborted the
/// start before anything was attached to the node.
@property(nonatomic, readonly) BOOL tapInstalled;

/// The playback engine whose player node is currently hosted on this capture engine, or
/// nil when none is. See `TapQAudioCaptureEngineHostPlaybackPlayer`.
@property(nonatomic, strong, readonly, nullable) TapQAudioPlaybackEngine *hostedPlayback;

- (instancetype)init;

/// Turns voice processing on for this engine's input node when `voiceProcessingEnabled`
/// is set; a no-op returning YES when it is not.
///
/// `TapQAudioCaptureEngineStart` calls this as its very first step, before it so much as
/// resolves the input node for itself. Owning the node lookup is what lets a test
/// substitute the whole step: enabling the unit needs a live audio unit, and an unsigned
/// test host that reaches for one stalls on the microphone permission check.
- (BOOL)enableVoiceProcessingIfRequestedWithError:(NSError * _Nullable * _Nullable)error;

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

// MARK: - Shared-engine hosting (experimental)

/// Moves `playback`'s player node off its own engine and onto `capture`'s engine,
/// connected to that engine's main mixer in the given PCM format.
///
/// Voice-processing IO cancels echo only against output it can see. With capture and
/// playback on separate engines the input unit has no reference signal at all, so a
/// spike that wants real echo cancellation has to put the player node on the engine
/// whose input node carries the voice-processing unit. Purely optional: leaving this
/// uncalled keeps the two-engine audio path unchanged.
///
/// Replaces any previously hosted player. `TapQAudioCaptureEngineStop` releases the
/// hosted node before it tears the capture graph down.
FOUNDATION_EXPORT BOOL TapQAudioCaptureEngineHostPlaybackPlayer(
    TapQAudioCaptureEngine *capture,
    TapQAudioPlaybackEngine *playback,
    double sampleRate,
    AVAudioChannelCount channels,
    NSError * _Nullable * _Nullable error
);

/// Returns a hosted player node to the playback engine that owns it. Best-effort and
/// idempotent: releasing when nothing is hosted succeeds without touching either engine.
FOUNDATION_EXPORT BOOL TapQAudioCaptureEngineReleasePlaybackPlayer(
    TapQAudioCaptureEngine *capture,
    NSError * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END

#endif
