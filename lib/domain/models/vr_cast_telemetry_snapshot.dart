import 'package:flutter/foundation.dart';

import '../../utils/constants/vr_cast_constants.dart';
import 'vr_cast_stats.dart';

/// Tracks frames sent, bytes sent, estimated FPS, and active viewers for a cast session.
@immutable
class VrCastTelemetrySnapshot {
  const VrCastTelemetrySnapshot({
    this.framesSent = 0,
    this.bytesSent = 0,
    this.estimatedFps = 0.0,
    this.activeViewers = 0,
    this.droppedFrames = 0,
    this.captureErrors = 0,
    this.lastCaptureDuration = Duration.zero,
  });

  factory VrCastTelemetrySnapshot.fromStats(
    VrCastStats stats, {
    required Duration elapsed,
    int activeViewers = 0,
    int? fpsCap,
  }) {
    final seconds = elapsed.inMicroseconds / 1000000.0;
    var fps = seconds > 0 ? stats.deliveredFrames / seconds : 0.0;
    if (fpsCap != null && fps > fpsCap) {
      fps = fpsCap.toDouble();
    }
    return VrCastTelemetrySnapshot(
      framesSent: stats.deliveredFrames,
      bytesSent: stats.bytesSent,
      estimatedFps: fps,
      activeViewers: activeViewers,
      droppedFrames: stats.droppedFrames,
      captureErrors: stats.captureErrors,
      lastCaptureDuration: stats.lastCaptureDuration,
    );
  }

  final int framesSent;
  final int bytesSent;
  final double estimatedFps;
  final int activeViewers;
  final int droppedFrames;
  final int captureErrors;
  final Duration lastCaptureDuration;

  Map<String, dynamic> toJson() => {
    VrCastConstants.keyFramesSent: framesSent,
    VrCastConstants.keyBytesSent: bytesSent,
    VrCastConstants.keyEstimatedFps: estimatedFps,
    VrCastConstants.keyActiveViewers: activeViewers,
    VrCastConstants.keyDroppedFrames: droppedFrames,
    VrCastConstants.keyCaptureErrors: captureErrors,
    VrCastConstants.keyLastCaptureMs:
        lastCaptureDuration.inMicroseconds / 1000.0,
  };
}
