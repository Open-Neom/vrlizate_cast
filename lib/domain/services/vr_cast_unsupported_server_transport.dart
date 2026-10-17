import '../../utils/constants/vr_cast_constants.dart';
import '../models/vr_cast_request.dart';
import '../models/vr_cast_response.dart';
import 'vr_cast_server_transport.dart';

/// Stub implementation of [VrCastServerTransport] for non-`dart:io` platforms.
class VrCastUnsupportedServerTransport implements VrCastServerTransport {
  @override
  Future<int> start(
    int port,
    Future<VrCastResponse> Function(VrCastRequest) handle,
  ) async => throw UnsupportedError(VrCastConstants.errLanHostingNativeOnly);

  @override
  Future<List<String>> localAddresses() async => [];

  @override
  Future<void> close() async {}
}
