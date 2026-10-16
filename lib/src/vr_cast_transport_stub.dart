import 'dart:typed_data';

import 'vr_cast_transport.dart';

VrCastServerTransport createServer() => _UnsupportedServer();
VrCastFrameClient createClient() => _UnsupportedClient();

class _UnsupportedServer implements VrCastServerTransport {
  @override
  Future<int> start(
    int port,
    Future<VrCastResponse> Function(VrCastRequest) handle,
  ) async => throw UnsupportedError('LAN hosting requires a native app.');
  @override
  Future<List<String>> localAddresses() async => [];
  @override
  Future<void> close() async {}
}

class _UnsupportedClient implements VrCastFrameClient {
  @override
  Future<Uint8List> read(Uri uri) async =>
      throw UnsupportedError('Open the spectator URL in a browser.');
  @override
  void close() {}
}
