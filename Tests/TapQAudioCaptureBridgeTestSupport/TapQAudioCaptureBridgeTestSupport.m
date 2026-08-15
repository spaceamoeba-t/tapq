#import "TapQAudioCaptureBridgeTestSupport.h"

@interface TapQThrowingAVAudioEngine : AVAudioEngine

@property(nonatomic) NSUInteger inputNodeCallCount;
@property(nonatomic) NSUInteger runningCallCount;
@property(nonatomic) NSUInteger resetCallCount;

@end

@implementation TapQThrowingAVAudioEngine

- (AVAudioInputNode *)inputNode {
    self.inputNodeCallCount += 1;
    [NSException raise:NSInternalInconsistencyException
                format:@"simulated input-node route exception"];
    return [super inputNode];
}

- (BOOL)isRunning {
    self.runningCallCount += 1;
    [NSException raise:NSInternalInconsistencyException
                format:@"simulated engine-running exception"];
    return NO;
}

- (void)reset {
    self.resetCallCount += 1;
    [NSException raise:NSInternalInconsistencyException
                format:@"simulated engine-reset exception"];
}

@end

@interface TapQThrowingAudioCaptureEngine ()

@property(nonatomic, strong) TapQThrowingAVAudioEngine *throwingEngine;

@end

@implementation TapQThrowingAudioCaptureEngine

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _throwingEngine = [[TapQThrowingAVAudioEngine alloc] init];
    }
    return self;
}

- (AVAudioEngine *)engine {
    return self.throwingEngine;
}

- (NSUInteger)inputNodeCallCount {
    return self.throwingEngine.inputNodeCallCount;
}

- (NSUInteger)runningCallCount {
    return self.throwingEngine.runningCallCount;
}

- (NSUInteger)resetCallCount {
    return self.throwingEngine.resetCallCount;
}

@end

@interface TapQStubbedVoiceProcessingCaptureEngine ()

@property(nonatomic, readwrite) NSUInteger voiceProcessingCallCount;
@property(nonatomic, readwrite) BOOL tapWasInstalledWhenApplied;

@end

@implementation TapQStubbedVoiceProcessingCaptureEngine

- (BOOL)enableVoiceProcessingIfRequestedWithError:(NSError * _Nullable * _Nullable)error {
    self.voiceProcessingCallCount += 1;
    self.tapWasInstalledWhenApplied = self.tapInstalled;
    if (!self.failsVoiceProcessing) {
        return YES;
    }
    if (error != NULL) {
        *error = [NSError errorWithDomain:TapQAudioCaptureErrorDomain
                                     code:1
                                 userInfo:@{
            NSLocalizedDescriptionKey: @"simulated voice-processing failure",
            TapQAudioCaptureFailureStageKey: @"voice_processing",
        }];
    }
    return NO;
}

@end
