import 'dart:typed_data';

typedef VrCastFrameProvider = Future<Uint8List?> Function();

enum VrCastEye { left, right, stereo }

/// An opaque source lease. An old route cannot unregister its replacement.
class VrCastSourceHandle {
  VrCastSourceHandle();
}

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

  final int captureCount, deliveredFrames, bytesSent, droppedFrames;
  final int captureErrors, sequence;
  final Duration lastCaptureDuration;
  final DateTime? lastFrameAt;
}
