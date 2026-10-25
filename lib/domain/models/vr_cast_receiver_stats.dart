import 'package:flutter/foundation.dart';

/// Decoder observations, not a measurement of camera-to-display latency.
@immutable
class VrCastReceiverStats {
  const VrCastReceiverStats({
    this.framesDecoded = 0,
    this.bytesReceived = 0,
    this.framesPerSecond = 0,
    this.bitsPerSecond = 0,
    this.packetsLost = 0,
    this.jitterMilliseconds = 0,
    this.width = 0,
    this.height = 0,
    this.codec,
    this.decoderImplementation,
  });

  final int framesDecoded;
  final int bytesReceived;
  final double framesPerSecond;
  final double bitsPerSecond;
  final int packetsLost;
  final double jitterMilliseconds;
  final int width;
  final int height;
  final String? codec;
  final String? decoderImplementation;

  /// Takes already filtered video inbound-rtp values and an interval measured
  /// with a monotonic clock. Counter resets never produce negative rates.
  factory VrCastReceiverStats.fromInboundVideo(
    Map<dynamic, dynamic> values, {
    VrCastReceiverStats? previous,
    Duration elapsed = Duration.zero,
    String? codec,
  }) {
    num number(String key) {
      final value = values[key];
      if (value is num && value.isFinite) return value;
      return 0;
    }

    final frames = number('framesDecoded').toInt().clamp(0, 1 << 53);
    final bytes = number('bytesReceived').toInt().clamp(0, 1 << 53);
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final frameDelta = frames - (previous?.framesDecoded ?? frames);
    final byteDelta = bytes - (previous?.bytesReceived ?? bytes);
    final reportedFps = number('framesPerSecond').toDouble();
    final measuredFps = previous != null && seconds > 0 && frameDelta >= 0
        ? frameDelta / seconds
        : 0.0;
    return VrCastReceiverStats(
      framesDecoded: frames,
      bytesReceived: bytes,
      framesPerSecond: reportedFps > 0 ? reportedFps : measuredFps,
      bitsPerSecond: previous != null && seconds > 0 && byteDelta >= 0
          ? byteDelta * 8 / seconds
          : 0,
      packetsLost: number('packetsLost').toInt(),
      jitterMilliseconds: number('jitter').toDouble() * 1000,
      width: number('frameWidth').toInt(),
      height: number('frameHeight').toInt(),
      codec: codec,
      decoderImplementation: values['decoderImplementation'] is String
          ? values['decoderImplementation'] as String
          : null,
    );
  }

  /// Intentionally excludes endpoints, identifiers, credentials and SDP.
  Map<String, Object?> toJson() => {
    'framesDecoded': framesDecoded,
    'bytesReceived': bytesReceived,
    'framesPerSecond': framesPerSecond,
    'bitsPerSecond': bitsPerSecond,
    'packetsLost': packetsLost,
    'jitterMilliseconds': jitterMilliseconds,
    'width': width,
    'height': height,
    'codec': codec,
    'decoderImplementation': decoderImplementation,
  };
}
