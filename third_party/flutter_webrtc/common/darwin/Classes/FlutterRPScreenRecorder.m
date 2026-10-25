#import "FlutterRPScreenRecorder.h"
#if TARGET_OS_IPHONE
#import <ReplayKit/ReplayKit.h>
#import <math.h>

// ReplayKit has one recorder per process. Retain an operation until Apple's
// asynchronous start/stop finishes, including a cancelled permission prompt.
// A late callback must never stop or publish frames into a replacement session.
static FlutterRPScreenRecorder* activeReplayKitCapturer;
static NSString* const FlutterReplayKitErrorDomain = @"FlutterReplayKitCapture";

static NSError* CaptureError(NSInteger code, NSString* description) {
  return [NSError errorWithDomain:FlutterReplayKitErrorDomain
                            code:code
                        userInfo:@{NSLocalizedDescriptionKey : description}];
}

static NSInteger ConstraintInteger(NSDictionary* constraints, NSString* key,
                                   NSInteger fallback, NSInteger maximum) {
  id value = constraints[key];
  if (value == nil && [constraints[@"mandatory"] isKindOfClass:[NSDictionary class]]) {
    value = constraints[@"mandatory"][key];
  }
  if ([value isKindOfClass:[NSDictionary class]]) {
    value = value[@"max"] ?: value[@"ideal"] ?: value[@"exact"] ?: value[@"min"];
  }
  if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue])) {
    return fallback;
  }
  return MAX(1, MIN(maximum, [value integerValue]));
}

@implementation FlutterRPScreenRecorder {
  RPScreenRecorder* screenRecorder;
  RTCVideoSource* source;
  BOOL pendingStart;
  BOOL capturing;
  BOOL stopping;
  BOOL cancelled;
  BOOL acceptFrames;
  NSInteger targetLongSide;
  NSInteger targetShortSide;
  NSInteger targetFPS;
  int adaptedWidth;
  int adaptedHeight;
  int64_t nextFrameTimestampNs;
  NSUInteger generation;
  void (^startCompletion)(NSError*);
  NSMutableArray* stopCompletions;
}

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate {
  self = [super initWithDelegate:delegate];
  if (self) {
    source = (RTCVideoSource*)delegate;
    stopCompletions = [NSMutableArray array];
  }
  return self;
}

- (void)startCapture {
  [self startCaptureWithConstraints:@{} completionHandler:^(NSError* error) {
    if (error != nil) NSLog(@"ReplayKit capture could not start (%ld)", (long)error.code);
  }];
}

- (void)finishStart:(NSError*)error {
  NSAssert([NSThread isMainThread], @"ReplayKit lifecycle must use the main thread");
  void (^completion)(NSError*) = startCompletion;
  startCompletion = nil;
  if (completion != nil) completion(error);
}

- (void)finishStop {
  NSAssert([NSThread isMainThread], @"ReplayKit lifecycle must use the main thread");
  capturing = NO;
  stopping = NO;
  if (activeReplayKitCapturer == self) activeReplayKitCapturer = nil;
  NSArray* completions = [stopCompletions copy];
  [stopCompletions removeAllObjects];
  for (void (^completion)(void) in completions) completion();
}

- (void)stopRecorderAfterStart {
  if (stopping) return;
  stopping = YES;
  NSUInteger stoppingGeneration = generation;
  __weak FlutterRPScreenRecorder* weakSelf = self;
  [screenRecorder stopCaptureWithHandler:^(NSError* error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRPScreenRecorder* strongSelf = weakSelf;
      if (strongSelf == nil || activeReplayKitCapturer != strongSelf ||
          strongSelf->generation != stoppingGeneration) return;
      if (error != nil) NSLog(@"ReplayKit stop completed with error (%ld)", (long)error.code);
      [strongSelf finishStop];
    });
  }];
}

- (void)startCaptureWithConstraints:(NSDictionary*)constraints
                 completionHandler:(void (^)(NSError* _Nullable))completion {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self startCaptureWithConstraints:constraints completionHandler:completion];
    });
    return;
  }
  if (activeReplayKitCapturer != nil) {
    completion(CaptureError(1, @"A ReplayKit capture or permission request is already active."));
    return;
  }
  screenRecorder = [RPScreenRecorder sharedRecorder];
  if (!screenRecorder.isAvailable || screenRecorder.isRecording) {
    completion(CaptureError(2, @"ReplayKit screen capture is unavailable or already in use."));
    return;
  }

  NSInteger width = ConstraintInteger(constraints, @"width", 1280, 1280);
  NSInteger height = ConstraintInteger(constraints, @"height", 720, 1280);
  targetLongSide = MIN(1280, MAX(width, height));
  targetShortSide = MIN(720, MIN(width, height));
  targetFPS = ConstraintInteger(constraints, @"frameRate", 24, 30);
  adaptedWidth = 0;
  adaptedHeight = 0;
  nextFrameTimestampNs = -1;
  cancelled = NO;
  pendingStart = YES;
  startCompletion = [completion copy];
  activeReplayKitCapturer = self;
  NSUInteger operationGeneration = ++generation;
  [screenRecorder setMicrophoneEnabled:NO];

  __weak FlutterRPScreenRecorder* weakSelf = self;
  [screenRecorder
      startCaptureWithHandler:^(CMSampleBufferRef sampleBuffer,
                                RPSampleBufferType bufferType, NSError* error) {
        FlutterRPScreenRecorder* strongSelf = weakSelf;
        if (strongSelf == nil || error != nil || bufferType != RPSampleBufferTypeVideo) return;
        [strongSelf handleSourceBuffer:sampleBuffer sampleType:bufferType];
      }
      completionHandler:^(NSError* error) {
        dispatch_async(dispatch_get_main_queue(), ^{
          FlutterRPScreenRecorder* strongSelf = weakSelf;
          if (strongSelf == nil || activeReplayKitCapturer != strongSelf ||
              strongSelf->generation != operationGeneration) return;
          strongSelf->pendingStart = NO;
          if (error != nil) {
            [strongSelf finishStart:error];
            [strongSelf finishStop];
            return;
          }
          strongSelf->capturing = YES;
          if (strongSelf->cancelled) {
            [strongSelf finishStart:CaptureError(3, @"Screen capture was cancelled.")];
            [strongSelf stopRecorderAfterStart];
            return;
          }
          @synchronized(strongSelf) {
            strongSelf->acceptFrames = YES;
          }
          // The Dart stream is returned only after ReplayKit consent succeeded.
          [strongSelf finishStart:nil];
        });
      }];

  // A Future timeout in Dart cannot cancel Apple's permission callback. Keep
  // ownership until it drains, with frames gated off immediately on timeout.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
    FlutterRPScreenRecorder* strongSelf = weakSelf;
    if (strongSelf == nil || activeReplayKitCapturer != strongSelf ||
        strongSelf->generation != operationGeneration || !strongSelf->pendingStart ||
        strongSelf->cancelled) return;
    @synchronized(strongSelf) {
      strongSelf->acceptFrames = NO;
    }
    strongSelf->cancelled = YES;
    [strongSelf finishStart:CaptureError(4, @"Screen capture permission timed out.")];
  });
}

+ (void)cancelActiveCaptureWithCompletionHandler:(nullable void (^)(void))completion {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self cancelActiveCaptureWithCompletionHandler:completion];
    });
    return;
  }
  FlutterRPScreenRecorder* capturer = activeReplayKitCapturer;
  if (capturer == nil) {
    if (completion != nil) completion();
    return;
  }
  BOOL awaitingConsent = capturer->pendingStart;
  [capturer stopCaptureWithCompletionHandler:awaitingConsent ? nil : completion];
  // No sample can leave a pending operation after the admission gate closes.
  // Apple alone owns the prompt: a late acceptance is stopped without frames.
  if (awaitingConsent && completion != nil) completion();
}

- (void)stopCapture {
  [self stopCaptureWithCompletionHandler:nil];
}

- (void)stopCaptureWithCompletionHandler:(nullable void (^)(void))completion {
  // Synchronize with the sample callback before yielding to the lifecycle queue.
  @synchronized(self) {
    acceptFrames = NO;
  }
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self stopCaptureWithCompletionHandler:completion];
    });
    return;
  }
  cancelled = YES;
  if (completion != nil) [stopCompletions addObject:[completion copy]];
  if (activeReplayKitCapturer != self) {
    [self finishStop];
    return;
  }
  [self finishStart:CaptureError(3, @"Screen capture was cancelled.")];
  if (pendingStart) return;
  if (capturing) {
    [self stopRecorderAfterStart];
  } else {
    [self finishStop];
  }
}

- (void)handleSourceBuffer:(CMSampleBufferRef)sampleBuffer
                sampleType:(RPSampleBufferType)sampleType {
  if (sampleBuffer == nil || CMSampleBufferGetNumSamples(sampleBuffer) != 1 || !CMSampleBufferIsValid(sampleBuffer) ||
      !CMSampleBufferDataIsReady(sampleBuffer)) return;
  CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  if (!CMTIME_IS_NUMERIC(timestamp)) return;
  double timestampSeconds = CMTimeGetSeconds(timestamp);
  if (!isfinite(timestampSeconds)) return;
  int64_t timestampNs = (int64_t)(timestampSeconds * NSEC_PER_SEC);

  @synchronized(self) {
    if (!acceptFrames) return;
    // Admit one fresh frame per interval; never enqueue missed screen samples.
    if (nextFrameTimestampNs >= 0 && timestampNs < nextFrameTimestampNs) return;
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer == nil) return;
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    if (width < 2 || height < 2) return;
    double scale = fmin(1.0, fmin((double)targetLongSide / MAX(width, height),
                                (double)targetShortSide / MIN(width, height)));
    int outputWidth = MAX(2, ((int)floor(width * scale) / 2) * 2);
    int outputHeight = MAX(2, ((int)floor(height * scale) / 2) * 2);
    if (adaptedWidth != outputWidth || adaptedHeight != outputHeight) {
      adaptedWidth = outputWidth;
      adaptedHeight = outputHeight;
      [source adaptOutputFormatToWidth:outputWidth height:outputHeight fps:(int)targetFPS];
    }
    // Keep a deadline rather than measuring from the previous admitted sample:
    // a 60 Hz source can then alternate intervals to target 24, rather than
    // rounding every interval up to three samples and unintentionally doing 20.
    int64_t intervalNs = NSEC_PER_SEC / targetFPS;
    nextFrameTimestampNs = nextFrameTimestampNs < 0 ||
                                   timestampNs - nextFrameTimestampNs >= intervalNs
                               ? timestampNs + intervalNs
                               : nextFrameTimestampNs + intervalNs;
    RTCCVPixelBuffer* rtcPixelBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
    RTCVideoFrame* videoFrame = [[RTCVideoFrame alloc] initWithBuffer:rtcPixelBuffer
                                                             rotation:RTCVideoRotation_0
                                                          timeStampNs:timestampNs];
    [self.delegate capturer:self didCaptureVideoFrame:videoFrame];
  }
}

@end
#endif
