/// An incoming HTTP request to the local VRlizate cast server.
class VrCastRequest {
  const VrCastRequest(this.method, this.uri);

  final String method;
  final Uri uri;
}
