import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../utils/constants/vr_cast_constants.dart';
import '../../utils/constants/vr_cast_signaling_constants.dart';
import '../models/vr_cast_request.dart';
import '../models/vr_cast_response.dart';
import '../models/vr_cast_session.dart';
import 'vr_cast_server_transport.dart';

/// Native `dart:io` implementation of [VrCastServerTransport].
class VrCastIoServerTransport implements VrCastServerTransport {
  HttpServer? _server;
  bool _closed = false;
  int _bodyReaders = 0;

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
      StreamSubscription<List<int>>? bodySubscription;
      try {
        Future<Uint8List>? body;
        // An unconsumed unauthorized body must not be drained indefinitely to
        // reuse the connection. Signaling is infrequent; disable persistence.
        if (request.method != VrCastConstants.methodGet ||
            request.contentLength != 0) {
          request.response.persistentConnection = false;
        }
        final response = await handle(
          VrCastRequest(
            request.method,
            request.uri,
            contentType: request.headers.contentType?.mimeType,
            readBody: () => body ??= _readBody(
              request,
              (subscription) => bodySubscription = subscription,
            ),
          ),
        );
        bodySubscription ??= _pauseUnreadBody(request);
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
      } on VrCastRequestBodyException catch (failure) {
        try {
          bodySubscription ??= _pauseUnreadBody(request);
          request.response.statusCode = failure.statusCode;
          request.response.persistentConnection = false;
          await request.response.close();
        } catch (_) {}
      } catch (_) {
        // Disconnects are expected; never log URLs or session credentials.
        try {
          bodySubscription ??= _pauseUnreadBody(request);
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
        } catch (_) {}
      } finally {
        // Cancel only after writing the response: cancelling an unfinished
        // HttpRequest stream first destroys its socket before headers flush.
        try {
          await bodySubscription?.cancel();
        } catch (_) {}
      }
    }, onError: (Object _) {});
    return server.port;
  }

  StreamSubscription<List<int>>? _pauseUnreadBody(HttpRequest request) {
    try {
      // HttpResponse otherwise drains an unlistened body before sending even
      // its headers. An attacker could withhold the body indefinitely. Mark
      // the stream as listened and immediately pause; the nonpersistent
      // connection closes after this response. No unauthenticated bytes are
      // buffered or decoded. Already-read streams simply throw StateError.
      return request.listen(null, onError: (Object _) {})..pause();
    } on StateError {
      // The authenticated bounded reader already owned this stream.
      return null;
    }
  }

  Future<Uint8List> _readBody(
    HttpRequest request,
    void Function(StreamSubscription<List<int>>) onSubscribe,
  ) async {
    if (request.contentLength > VrCastSignalingConstants.maxBodyBytes) {
      throw const VrCastRequestBodyException(HttpStatus.requestEntityTooLarge);
    }
    if (_bodyReaders >= VrCastSignalingConstants.maxConcurrentBodyReaders) {
      throw const VrCastRequestBodyException(HttpStatus.tooManyRequests);
    }
    _bodyReaders++;
    final result = Completer<Uint8List>();
    final bytes = BytesBuilder(copy: false);
    StreamSubscription<List<int>>? subscription;
    Timer? timeout;
    void fail(int status) {
      if (result.isCompleted) return;
      result.completeError(VrCastRequestBodyException(status));
      subscription?.pause();
    }

    try {
      timeout = Timer(
        VrCastSignalingConstants.bodyTimeout,
        () => fail(HttpStatus.requestTimeout),
      );
      subscription = request.listen(
        (chunk) {
          if (result.isCompleted) return;
          if (bytes.length + chunk.length >
              VrCastSignalingConstants.maxBodyBytes) {
            fail(HttpStatus.requestEntityTooLarge);
          } else {
            bytes.add(chunk);
          }
        },
        onDone: () {
          if (!result.isCompleted) result.complete(bytes.takeBytes());
        },
        onError: (Object _) => fail(HttpStatus.badRequest),
        cancelOnError: true,
      );
      onSubscribe(subscription);
      return await result.future;
    } finally {
      timeout?.cancel();
      _bodyReaders--;
    }
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
