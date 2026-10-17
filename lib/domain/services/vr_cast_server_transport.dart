import '../models/vr_cast_request.dart';
import '../models/vr_cast_response.dart';

/// Abstract local HTTP server transport for VRlizate LAN casting.
abstract class VrCastServerTransport {
  Future<int> start(
    int port,
    Future<VrCastResponse> Function(VrCastRequest) handle,
  );
  Future<List<String>> localAddresses();
  Future<void> close();
}
