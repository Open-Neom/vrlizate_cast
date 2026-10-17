import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../utils/constants/vr_cast_constants.dart';
import 'vr_cast_frame_client.dart';

/// Native `dart:io` implementation of [VrCastFrameClient].
class VrCastIoFrameClient implements VrCastFrameClient {
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
      request.headers.set(
        HttpHeaders.acceptHeader,
        VrCastConstants.contentTypeJpeg,
      );
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok ||
          response.headers.contentType?.mimeType !=
              VrCastConstants.contentTypeJpeg) {
        request.abort();
        throw const FormatException(VrCastConstants.errNoFrameAvailable);
      }
      if (response.contentLength > VrCastConstants.maxFrameBytes) {
        request.abort();
        throw const FormatException(VrCastConstants.errFrameExceedsByteLimit);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length > VrCastConstants.maxFrameBytes) {
          request.abort();
          throw const FormatException(VrCastConstants.errFrameExceedsByteLimit);
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    }

    return load().timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        pending?.abort();
        throw TimeoutException(VrCastConstants.errPreviewTimedOut);
      },
    );
  }

  @override
  void close() => _client.close(force: true);
}
