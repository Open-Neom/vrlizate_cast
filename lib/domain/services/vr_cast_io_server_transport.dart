import 'dart:async';
import 'dart:io';

import '../../utils/constants/vr_cast_constants.dart';
import '../models/vr_cast_request.dart';
import '../models/vr_cast_response.dart';
import '../models/vr_cast_session.dart';
import 'vr_cast_server_transport.dart';

/// Native `dart:io` implementation of [VrCastServerTransport].
class VrCastIoServerTransport implements VrCastServerTransport {
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
      throw StateError(VrCastConstants.errCastStoppedStartup);
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
          ..set(
            HttpHeaders.cacheControlHeader,
            VrCastConstants.headerCacheControlValue,
          )
          ..set(
            VrCastConstants.headerContentTypeOptions,
            VrCastConstants.headerNoSniff,
          )
          ..set(
            VrCastConstants.headerReferrerPolicy,
            VrCastConstants.headerNoReferrer,
          );
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
        VrCastConstants.ignoredInterfacePattern,
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
