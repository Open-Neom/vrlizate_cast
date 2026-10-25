import '../models/vr_cast_session.dart';
import 'vr_cast_signaling_client.dart';

VrCastSignalingClient createSignalingClient() =>
    VrCastUnsupportedSignalingClient();

class VrCastUnsupportedSignalingClient implements VrCastSignalingClient {
  @override
  Future<Map<String, dynamic>> exchange(
    VrCastSession session,
    Map<String, dynamic> offer,
  ) async => throw const VrCastSignalingException('native-app-required');

  @override
  Future<void> keepAlive(VrCastSession session, String sessionId) async {}

  @override
  Future<void> release(VrCastSession session, String sessionId) async {}

  @override
  void close() {}
}
