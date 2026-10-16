import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'vr_cast_session.dart';
import 'vr_cast_transport.dart';

VrCastServerTransport createServer() => _IoServer();
VrCastFrameClient createClient() => _IoClient();

class _IoServer implements VrCastServerTransport {
  HttpServer? _server;
  bool _closed = false;

  @override
  Future<int> start(
    int port,
    Future<VrCastResponse> Function(VrCastRequest) handle,
  ) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    if (_closed) {
      await server.close(force: true);
      throw StateError('Cast stopped during startup.');
    }
    _server = server;
    server.idleTimeout = const Duration(seconds: 3);
    server.listen((request) async {
      try {
        final response = await handle(
          VrCastRequest(request.method, request.uri),
        );
        request.response.statusCode = response.status;
        request.response.headers
          ..set(HttpHeaders.cacheControlHeader, 'no-store')
          ..set('X-Content-Type-Options', 'nosniff')
          ..set('Referrer-Policy', 'no-referrer');
        if (response.contentType case final type?) {
          request.response.headers.set(HttpHeaders.contentTypeHeader, type);
        }
        response.headers.forEach(request.response.headers.set);
        final bytes = response.bytes;
        request.response.contentLength = bytes?.length ?? 0;
        if (bytes != null) request.response.add(bytes);
        await request.response.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        // Disconnects are expected; never log URLs or session credentials.
        try {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
        } catch (_) {}
      }
    }, onError: (Object _) {});
    return server.port;
  }

  @override
  Future<List<String>> localAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final addresses = <String>{};
    for (final interface in interfaces) {
      // Ignore common cellular/tunnel interfaces; never present these as Wi-Fi.
      if (RegExp(
        r'^(lo|utun|tun|tap|ppp|rmnet|pdp_ip|ipsec|wg)',
      ).hasMatch(interface.name)) {
        continue;
      }
      for (final address in interface.addresses) {
        if (isVrCastLocalAddress(address.address) && !address.isLoopback) {
          addresses.add(address.address);
        }
      }
    }
    return addresses.toList()..sort();
  }

  @override
  Future<void> close() async {
    _closed = true;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}

class _IoClient implements VrCastFrameClient {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..idleTimeout = const Duration(seconds: 2)
    ..maxConnectionsPerHost = 1;

  @override
  Future<Uint8List> read(Uri uri) async {
    HttpClientRequest? pending;
    Future<Uint8List> load() async {
      final request = await _client.getUrl(uri);
      pending = request;
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'image/jpeg');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok ||
          response.headers.contentType?.mimeType != 'image/jpeg') {
        request.abort();
        throw const FormatException('The visor has no frame available.');
      }
      if (response.contentLength > vrCastMaxFrameBytes) {
        request.abort();
        throw const FormatException('Preview frame exceeds its byte limit.');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length > vrCastMaxFrameBytes) {
          request.abort();
          throw const FormatException('Preview frame exceeds its byte limit.');
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    }

    return load().timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        pending?.abort();
        throw TimeoutException('Preview timed out.');
      },
    );
  }

  @override
  void close() => _client.close(force: true);
}
