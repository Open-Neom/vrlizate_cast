import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../utils/constants/vr_cast_constants.dart';
import '../../utils/constants/vr_cast_signaling_constants.dart';
import '../models/vr_cast_session.dart';
import 'vr_cast_signaling_client.dart';

VrCastSignalingClient createSignalingClient() => VrCastIoSignalingClient();

/// Authenticated HTTP on the already validated cast LAN URL. Redirects,
/// public destinations and unbounded response bodies are never followed.
class VrCastIoSignalingClient implements VrCastSignalingClient {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..idleTimeout = const Duration(seconds: 2)
    ..maxConnectionsPerHost = 2;
  bool _closed = false;
  final Set<Completer<void>> _sourceWaits = {};

  @override
  Future<Map<String, dynamic>> exchange(
    VrCastSession session,
    Map<String, dynamic> offer,
  ) async {
    final sdp = offer['sdp'];
    final requestId = offer['requestId'];
    if (offer['type'] != 'offer' ||
        requestId is! String ||
        !RegExp(
          VrCastSignalingConstants.sessionIdPattern,
        ).hasMatch(requestId) ||
        sdp is! String ||
        sdp.isEmpty ||
        utf8.encode(sdp).length > VrCastSignalingConstants.maxSdpBytes) {
      throw const VrCastSignalingException('invalid-offer');
    }
    final initialSourceWait = Stopwatch()..start();
    const sourceWaitLimit = Duration(seconds: 15);
    while (true) {
      if (_closed) throw const VrCastSignalingException('closed');
      try {
        return await _request(
          session,
          'POST',
          VrCastSignalingConstants.offerPath,
          offer,
          VrCastSignalingConstants.handshakeTimeout,
        );
      } on VrCastSignalingException catch (error) {
        // Pairing can finish before the home surface registers its provider.
        // Only this explicit, pre-consent state can be retried automatically.
        // Consent denials and every other HTTP/native failure remain final.
        if (error.code != 'source-unavailable' ||
            error.statusCode != HttpStatus.serviceUnavailable ||
            initialSourceWait.elapsed >= sourceWaitLimit) {
          rethrow;
        }
        final remaining = sourceWaitLimit - initialSourceWait.elapsed;
        if (remaining < const Duration(seconds: 1)) {
          await _waitForSource(remaining);
          rethrow;
        }
        await _waitForSource(const Duration(seconds: 1));
        if (initialSourceWait.elapsed >= sourceWaitLimit) rethrow;
      }
    }
  }

  Future<void> _waitForSource(Duration delay) async {
    if (_closed) throw const VrCastSignalingException('closed');
    final waiter = Completer<void>();
    _sourceWaits.add(waiter);
    final timer = Timer(delay, waiter.complete);
    try {
      await waiter.future;
    } finally {
      timer.cancel();
      _sourceWaits.remove(waiter);
    }
    if (_closed) throw const VrCastSignalingException('closed');
  }

  @override
  Future<void> keepAlive(VrCastSession session, String sessionId) async {
    await _sessionRequest(session, sessionId, 'POST');
  }

  @override
  Future<void> release(VrCastSession session, String sessionId) async {
    await _sessionRequest(session, sessionId, 'DELETE');
  }

  Future<void> _sessionRequest(
    VrCastSession session,
    String sessionId,
    String method,
  ) async {
    if (!RegExp(
      VrCastSignalingConstants.sessionIdPattern,
    ).hasMatch(sessionId)) {
      throw const VrCastSignalingException('invalid-session');
    }
    await _request(session, method, VrCastSignalingConstants.sessionPath, {
      'sessionId': sessionId,
    }, VrCastSignalingConstants.sessionRequestTimeout);
  }

  Future<Map<String, dynamic>> _request(
    VrCastSession session,
    String method,
    String path,
    Map<String, dynamic> message,
    Duration timeout,
  ) async {
    if (_closed) throw const VrCastSignalingException('closed');
    // Revalidate at the transport boundary, including the token/PIN shape.
    final valid = VrCastSession.tryParse(session.viewerUri.toString());
    if (valid == null) throw const VrCastSignalingException('invalid-session');
    Uint8List payload;
    try {
      payload = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    } catch (_) {
      throw const VrCastSignalingException('invalid-message');
    }
    if (payload.length > VrCastSignalingConstants.maxBodyBytes) {
      throw const VrCastSignalingException('message-too-large');
    }
    HttpClientRequest? pending;
    var expired = false;
    Future<Map<String, dynamic>> load() async {
      final request = await _client.openUrl(
        method,
        valid.viewerUri.replace(path: path),
      );
      pending = request;
      if (_closed || expired) {
        request.abort();
        throw const VrCastSignalingException('closed');
      }
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.acceptHeader,
        VrCastConstants.contentTypeJson,
      );
      request.contentLength = payload.length;
      request.add(payload);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.noContent) {
        final state = response.headers['X-VRlizate-Video-State'];
        final sourceUnavailable =
            method == 'POST' &&
            path == VrCastSignalingConstants.offerPath &&
            response.statusCode == HttpStatus.serviceUnavailable &&
            state?.length == 1 &&
            state!.single == 'source-unavailable';
        request.abort();
        throw VrCastSignalingException(
          sourceUnavailable ? 'source-unavailable' : 'http-rejected',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode == HttpStatus.noContent) return {};
      if (response.headers.contentType?.mimeType !=
          VrCastConstants.contentTypeJson) {
        request.abort();
        throw const VrCastSignalingException('invalid-response');
      }
      if (response.contentLength > VrCastSignalingConstants.maxBodyBytes) {
        request.abort();
        throw const VrCastSignalingException('response-too-large');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length >
            VrCastSignalingConstants.maxBodyBytes) {
          request.abort();
          throw const VrCastSignalingException('response-too-large');
        }
        bytes.add(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is! Map<String, dynamic>) {
        throw const VrCastSignalingException('invalid-response');
      }
      return decoded;
    }

    try {
      return await load().timeout(
        timeout,
        onTimeout: () {
          expired = true;
          pending?.abort();
          throw const VrCastSignalingException('timeout');
        },
      );
    } on VrCastSignalingException {
      rethrow;
    } catch (_) {
      // Socket errors and JSON parser errors can contain a URL/payload.
      pending?.abort();
      throw VrCastSignalingException(_closed ? 'closed' : 'unavailable');
    }
  }

  @override
  void close() {
    _closed = true;
    for (final waiter in _sourceWaits.toList()) {
      if (!waiter.isCompleted) {
        waiter.completeError(const VrCastSignalingException('closed'));
      }
    }
    _client.close(force: true);
  }
}
