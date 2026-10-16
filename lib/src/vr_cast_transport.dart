import 'dart:typed_data';

import 'vr_cast_transport_stub.dart'
    if (dart.library.io) 'vr_cast_transport_io.dart'
    as platform;

const vrCastMaxFrameBytes = 256 * 1024;

class VrCastRequest {
  const VrCastRequest(this.method, this.uri);
  final String method;
  final Uri uri;
}

class VrCastResponse {
  const VrCastResponse(
    this.status, {
    this.bytes,
    this.contentType,
    this.headers = const {},
  });
  final int status;
  final Uint8List? bytes;
  final String? contentType;
  final Map<String, String> headers;
}

abstract class VrCastServerTransport {
  Future<int> start(
    int port,
    Future<VrCastResponse> Function(VrCastRequest) handle,
  );
  Future<List<String>> localAddresses();
  Future<void> close();
}

abstract class VrCastFrameClient {
  Future<Uint8List> read(Uri uri);
  void close();
}

VrCastServerTransport createVrCastServerTransport() => platform.createServer();
VrCastFrameClient createVrCastFrameClient() => platform.createClient();
