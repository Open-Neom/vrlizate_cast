import 'dart:typed_data';

/// An incoming HTTP request to the local VRlizate cast server.
class VrCastRequest {
  const VrCastRequest(
    this.method,
    this.uri, {
    this.contentType,
    Future<Uint8List> Function()? readBody,
  }) : _readBody = readBody;

  final String method;
  final Uri uri;
  final String? contentType;
  final Future<Uint8List> Function()? _readBody;

  /// Reads a bounded request body only after the host has authenticated it.
  /// The IO transport caches the future, so repeated reads never re-subscribe.
  Future<Uint8List> readBody() =>
      _readBody?.call() ?? Future.value(Uint8List(0));
}

/// A safe HTTP failure that deliberately contains no request URI or payload.
class VrCastRequestBodyException implements Exception {
  const VrCastRequestBodyException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'Cast request body rejected ($statusCode).';
}
