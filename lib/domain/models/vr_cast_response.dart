import 'dart:typed_data';

/// An HTTP response emitted by the local VRlizate cast server.
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
