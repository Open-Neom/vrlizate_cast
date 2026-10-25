#if TARGET_OS_IPHONE
#import <WebRTC/WebRTC.h>
@interface FlutterRPScreenRecorder : RTCVideoCapturer

- (void)startCapture;

// Starts foreground app capture after ReplayKit grants consent. Constraints are
// bounded to 1280x720 (orientation independent) and 1..30 FPS; default 24 FPS.
- (void)startCaptureWithConstraints:(nonnull NSDictionary*)constraints
                 completionHandler:(nonnull void (^)(NSError* _Nullable error))completion;

// Gates frames immediately, including an unresolved consent request. The
// pending Apple prompt may still resolve later; that operation is then drained.
+ (void)cancelActiveCaptureWithCompletionHandler:(nullable void (^)(void))completion;

// Stops the capture session asynchronously and notifies callback on completion.
- (void)stopCaptureWithCompletionHandler:(nullable void (^)(void))completionHandler;

- (void)stopCapture;

@end
#endif
