#import "TapQAudioCaptureBridge.h"
#import <math.h>

NSString * const TapQAudioCaptureErrorDomain = @"ai.tapq.audio.capture";
NSString * const TapQAudioCaptureFailureStageKey = @"stage";

static NSString * const TapQInputFormatStage = @"input_format";
static NSString * const TapQAudioSetupStage = @"audio_setup";
static NSString * const TapQEngineStartStage = @"engine_start";
static NSString * const TapQAudioTeardownStage = @"audio_teardown";
static NSString * const TapQVoiceProcessingStage = @"voice_processing";
static NSString * const TapQPlayerHostingStage = @"player_hosting";

static NSError *TapQCaptureError(
    NSString *stage,
    NSString *description,
    NSError * _Nullable underlyingError
);

BOOL TapQAudioInputFormatIsUsable(
    double sampleRate,
    AVAudioChannelCount channelCount
) {
    return isfinite(sampleRate) && sampleRate > 0 && channelCount > 0;
}

@interface TapQAudioCaptureEngine ()

@property(nonatomic, strong, readwrite) AVAudioEngine *engine;
@property(nonatomic, strong, nullable) AVAudioInputNode *inputNode;
@property(nonatomic, readwrite) BOOL tapInstalled;
@property(nonatomic, strong, readwrite, nullable) TapQAudioPlaybackEngine *hostedPlayback;

@end

@implementation TapQAudioCaptureEngine

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _engine = [[AVAudioEngine alloc] init];
    }
    return self;
}

- (BOOL)enableVoiceProcessingIfRequestedWithError:(NSError * _Nullable * _Nullable)error {
    if (!self.voiceProcessingEnabled) {
        return YES;
    }
    AVAudioInputNode *input = self.engine.inputNode;
    NSError *voiceProcessingError = nil;
    if (![input setVoiceProcessingEnabled:YES error:&voiceProcessingError]) {
        if (error != NULL) {
            *error = TapQCaptureError(
                TapQVoiceProcessingStage,
                voiceProcessingError.localizedDescription
                    ?: @"voice processing could not be enabled on the input node",
                voiceProcessingError
            );
        }
        return NO;
    }
    return YES;
}

@end

static NSError *TapQCaptureError(
    NSString *stage,
    NSString *description,
    NSError * _Nullable underlyingError
) {
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey: description,
        TapQAudioCaptureFailureStageKey: stage,
    } mutableCopy];
    if (underlyingError != nil) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:TapQAudioCaptureErrorDomain
                               code:1
                           userInfo:userInfo];
}

static NSError *TapQExceptionError(NSString *stage, NSException *exception) {
    NSString *reason = exception.reason ?: @"AVFAudio raised an exception";
    return TapQCaptureError(
        stage,
        [NSString stringWithFormat:@"%@: %@", exception.name, reason],
        nil
    );
}

BOOL TapQAudioCaptureEngineStart(
    TapQAudioCaptureEngine *capture,
    AVAudioFrameCount bufferSize,
    AVAudioNodeTapBlock tapBlock,
    NSError * _Nullable * _Nullable error
) {
    @try {
        // Voice processing has to go on before the format read and the tap install:
        // enabling the unit republishes the input node's format, and a tap installed
        // against the pre-transition format is exactly what AVFAudio rejects.
        NSError *voiceProcessingError = nil;
        if (![capture enableVoiceProcessingIfRequestedWithError:&voiceProcessingError]) {
            if (error != NULL) {
                *error = voiceProcessingError ?: TapQCaptureError(
                    TapQVoiceProcessingStage,
                    @"voice processing could not be enabled on the input node",
                    nil
                );
            }
            return NO;
        }

        AVAudioInputNode *input = capture.engine.inputNode;
        AVAudioFormat *hardwareFormat = [input inputFormatForBus:0];
        double sampleRate = hardwareFormat.sampleRate;
        AVAudioChannelCount channelCount = hardwareFormat.channelCount;
        if (!TapQAudioInputFormatIsUsable(sampleRate, channelCount)) {
            if (error != NULL) {
                *error = TapQCaptureError(
                    TapQInputFormatStage,
                    [NSString stringWithFormat:
                        @"unavailable input (sample_rate=%g, channels=%u)",
                        sampleRate, (unsigned int)channelCount],
                    nil
                );
            }
            return NO;
        }

        capture.inputNode = input;
        // A nil tap format follows this fresh input node's native output format. A
        // nonnil stale client format is what makes AVFAudio reject a changed route.
        [input installTapOnBus:0
                   bufferSize:bufferSize
                       format:nil
                        block:tapBlock];
        capture.tapInstalled = YES;
        [capture.engine prepare];

        NSError *startError = nil;
        if (![capture.engine startAndReturnError:&startError]) {
            if (error != NULL) {
                *error = TapQCaptureError(
                    TapQEngineStartStage,
                    startError.localizedDescription ?: @"AVAudioEngine failed to start",
                    startError
                );
            }
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = TapQExceptionError(TapQAudioSetupStage, exception);
        }
        return NO;
    }
}

BOOL TapQAudioCaptureEngineStop(
    TapQAudioCaptureEngine *capture,
    NSError * _Nullable * _Nullable error
) {
    NSError *firstError = nil;

    // A hosted player node must go home before the graph is reset, so the playback
    // engine that owns it is never left holding a node attached to a dead engine.
    NSError *releaseError = nil;
    if (!TapQAudioCaptureEngineReleasePlaybackPlayer(capture, &releaseError)) {
        firstError = releaseError;
    }

    @try {
        if (capture.engine.running) {
            [capture.engine stop];
        }
    } @catch (NSException *exception) {
        if (firstError == nil) {
            firstError = TapQExceptionError(TapQAudioTeardownStage, exception);
        }
    }

    if (capture.tapInstalled && capture.inputNode != nil) {
        @try {
            [capture.inputNode removeTapOnBus:0];
        } @catch (NSException *exception) {
            if (firstError == nil) {
                firstError = TapQExceptionError(TapQAudioTeardownStage, exception);
            }
        }
    }

    @try {
        [capture.engine reset];
    } @catch (NSException *exception) {
        if (firstError == nil) {
            firstError = TapQExceptionError(TapQAudioTeardownStage, exception);
        }
    }

    capture.tapInstalled = NO;
    capture.inputNode = nil;
    if (error != NULL) {
        *error = firstError;
    }
    return firstError == nil;
}

// MARK: - Playback engine

NSString * const TapQAudioPlaybackErrorDomain = @"ai.tapq.audio.playback";
NSString * const TapQAudioPlaybackFailureStageKey = @"stage";

static NSString * const TapQPlaybackSetupStage = @"playback_setup";
static NSString * const TapQPlaybackEngineStartStage = @"playback_engine_start";
static NSString * const TapQPlaybackScheduleStage = @"playback_schedule";
static NSString * const TapQPlaybackTeardownStage = @"playback_teardown";

@interface TapQAudioPlaybackEngine ()

@property(nonatomic, strong, readwrite) AVAudioEngine *engine;
@property(nonatomic, strong, readwrite) AVAudioPlayerNode *player;

@end

@implementation TapQAudioPlaybackEngine

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _engine = [[AVAudioEngine alloc] init];
        _player = [[AVAudioPlayerNode alloc] init];
        [_engine attachNode:_player];
    }
    return self;
}

@end

static NSError *TapQPlaybackError(
    NSString *stage,
    NSString *description,
    NSError * _Nullable underlyingError
) {
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey: description,
        TapQAudioPlaybackFailureStageKey: stage,
    } mutableCopy];
    if (underlyingError != nil) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:TapQAudioPlaybackErrorDomain
                               code:1
                           userInfo:userInfo];
}

static NSError *TapQPlaybackExceptionError(NSString *stage, NSException *exception) {
    NSString *reason = exception.reason ?: @"AVFAudio raised an exception";
    return TapQPlaybackError(
        stage,
        [NSString stringWithFormat:@"%@: %@", exception.name, reason],
        nil
    );
}

BOOL TapQAudioPlaybackEngineStart(
    TapQAudioPlaybackEngine *playback,
    double sampleRate,
    AVAudioChannelCount channels,
    NSError * _Nullable * _Nullable error
) {
    @try {
        AVAudioFormat *format = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatInt16
                     sampleRate:sampleRate
                       channels:channels
                    interleaved:YES];
        if (format == nil) {
            if (error != NULL) {
                *error = TapQPlaybackError(
                    TapQPlaybackSetupStage,
                    [NSString stringWithFormat:
                        @"cannot create playback format (sample_rate=%g, channels=%u)",
                        sampleRate, (unsigned int)channels],
                    nil
                );
            }
            return NO;
        }

        [playback.engine connect:playback.player
                              to:playback.engine.mainMixerNode
                          format:format];
        [playback.engine prepare];

        NSError *startError = nil;
        if (![playback.engine startAndReturnError:&startError]) {
            if (error != NULL) {
                *error = TapQPlaybackError(
                    TapQPlaybackEngineStartStage,
                    startError.localizedDescription ?: @"AVAudioEngine failed to start",
                    startError
                );
            }
            return NO;
        }
        [playback.player play];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = TapQPlaybackExceptionError(TapQPlaybackSetupStage, exception);
        }
        return NO;
    }
}

BOOL TapQAudioPlaybackEngineSchedule(
    TapQAudioPlaybackEngine *playback,
    AVAudioPCMBuffer *buffer,
    void (^_Nullable completion)(void),
    NSError * _Nullable * _Nullable error
) {
    @try {
        if (completion != nil) {
            [playback.player scheduleBuffer:buffer completionHandler:completion];
        } else {
            [playback.player scheduleBuffer:buffer completionHandler:nil];
        }
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = TapQPlaybackExceptionError(TapQPlaybackScheduleStage, exception);
        }
        return NO;
    }
}

BOOL TapQAudioPlaybackEngineStop(
    TapQAudioPlaybackEngine *playback,
    NSError * _Nullable * _Nullable error
) {
    NSError *firstError = nil;

    @try {
        if (playback.player.isPlaying) {
            [playback.player stop];
        }
    } @catch (NSException *exception) {
        firstError = TapQPlaybackExceptionError(TapQPlaybackTeardownStage, exception);
    }

    @try {
        [playback.player reset];
    } @catch (NSException *exception) {
        if (firstError == nil) {
            firstError = TapQPlaybackExceptionError(TapQPlaybackTeardownStage, exception);
        }
    }

    @try {
        if (playback.engine.running) {
            [playback.engine stop];
        }
    } @catch (NSException *exception) {
        if (firstError == nil) {
            firstError = TapQPlaybackExceptionError(TapQPlaybackTeardownStage, exception);
        }
    }

    if (error != NULL) {
        *error = firstError;
    }
    return firstError == nil;
}

// MARK: - Shared-engine hosting (experimental)

BOOL TapQAudioCaptureEngineHostPlaybackPlayer(
    TapQAudioCaptureEngine *capture,
    TapQAudioPlaybackEngine *playback,
    double sampleRate,
    AVAudioChannelCount channels,
    NSError * _Nullable * _Nullable error
) {
    // Validate before moving anything: a node that has been detached from its own engine
    // and rejected by this one is a node nobody can play through.
    if (!TapQAudioInputFormatIsUsable(sampleRate, channels)) {
        if (error != NULL) {
            *error = TapQCaptureError(
                TapQPlayerHostingStage,
                [NSString stringWithFormat:
                    @"unusable hosted playback format (sample_rate=%g, channels=%u)",
                    sampleRate, (unsigned int)channels],
                nil
            );
        }
        return NO;
    }

    @try {
        AVAudioFormat *format = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatInt16
                      sampleRate:sampleRate
                        channels:channels
                     interleaved:YES];
        if (format == nil) {
            if (error != NULL) {
                *error = TapQCaptureError(
                    TapQPlayerHostingStage,
                    [NSString stringWithFormat:
                        @"cannot create hosted playback format (sample_rate=%g, channels=%u)",
                        sampleRate, (unsigned int)channels],
                    nil
                );
            }
            return NO;
        }

        AVAudioPlayerNode *player = playback.player;
        AVAudioEngine *owningEngine = player.engine;
        // A node belongs to exactly one engine. Detaching first is what makes moving it
        // legal; attaching an already-attached node is what AVFAudio raises on.
        if (owningEngine != nil && owningEngine != capture.engine) {
            [owningEngine detachNode:player];
        }
        if (player.engine != capture.engine) {
            [capture.engine attachNode:player];
        }
        [capture.engine connect:player
                             to:capture.engine.mainMixerNode
                         format:format];
        capture.hostedPlayback = playback;
        return YES;
    } @catch (NSException *exception) {
        // The move may already have happened when the connect raised. Put the node back
        // so a failed hosting attempt leaves the playback engine as it was.
        capture.hostedPlayback = nil;
        @try {
            AVAudioPlayerNode *player = playback.player;
            if (player.engine == capture.engine) {
                [capture.engine detachNode:player];
            }
            if (player.engine == nil) {
                [playback.engine attachNode:player];
            }
        } @catch (NSException *restoreException) {
            (void)restoreException;
        }
        if (error != NULL) {
            *error = TapQExceptionError(TapQPlayerHostingStage, exception);
        }
        return NO;
    }
}

BOOL TapQAudioCaptureEngineReleasePlaybackPlayer(
    TapQAudioCaptureEngine *capture,
    NSError * _Nullable * _Nullable error
) {
    TapQAudioPlaybackEngine *playback = capture.hostedPlayback;
    if (playback == nil) {
        if (error != NULL) {
            *error = nil;
        }
        return YES;
    }

    // Clear the reference first: whatever AVFAudio does with the node below, this capture
    // engine is no longer claiming to host it.
    capture.hostedPlayback = nil;

    @try {
        AVAudioPlayerNode *player = playback.player;
        if (player.engine == capture.engine) {
            [capture.engine detachNode:player];
        }
        if (player.engine == nil) {
            [playback.engine attachNode:player];
        }
        if (error != NULL) {
            *error = nil;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = TapQExceptionError(TapQPlayerHostingStage, exception);
        }
        return NO;
    }
}
