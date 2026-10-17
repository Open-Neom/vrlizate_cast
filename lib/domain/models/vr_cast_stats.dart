/// A snapshot, read on demand; frame delivery does not rebuild the host app.
class VrCastStats {
  const VrCastStats({
    this.captureCount = 0,
    this.deliveredFrames = 0,
    this.bytesSent = 0,
    this.droppedFrames = 0,
    this.captureErrors = 0,
    this.lastCaptureDuration = Duration.zero,
    this.lastFrameAt,
    this.sequence = 0,
  });

  final int captureCount;
  final int deliveredFrames;
  final int bytesSent;
  final int droppedFrames;
  final int captureErrors;
  final int sequence;
  final Duration lastCaptureDuration;
  final DateTime? lastFrameAt;
}
