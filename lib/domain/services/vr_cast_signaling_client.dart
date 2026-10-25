import '../models/vr_cast_session.dart';
import 'vr_cast_unsupported_signaling_client.dart'
    if (dart.library.io) 'vr_cast_io_signaling_client.dart'
    as platform;

/// HTTP negotiation only. The peer connection carries the actual video.
abstract class VrCastSignalingClient {
  Future<Map<String, dynamic>> exchange(
    VrCastSession session,
    Map<String, dynamic> offer,
  );

  Future<void> keepAlive(VrCastSession session, String sessionId);
  Future<void> release(VrCastSession session, String sessionId);
  void close();
}

VrCastSignalingClient createVrCastSignalingClient() =>
    platform.createSignalingClient();

/// Safe to surface in diagnostics: credentials, SDP and remote error bodies
/// are deliberately excluded.
class VrCastSignalingException implements Exception {
  const VrCastSignalingException(this.code, {this.statusCode});

  final String code;
  final int? statusCode;

  @override
  String toString() =>
      'Cast signaling failed: $code'
      '${statusCode == null ? '' : ' ($statusCode)'}.';
}
