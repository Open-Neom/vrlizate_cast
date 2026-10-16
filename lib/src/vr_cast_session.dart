/// A local spectator URL. It never carries a controller pairing credential.
class VrCastSession {
  const VrCastSession._(this.viewerUri);

  final Uri viewerUri;
  Uri get frameUri => viewerUri.replace(path: '/frame.jpg');

  static VrCastSession? tryParse(String value) {
    if (value.length > 1024) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !isVrCastLocalAddress(uri.host) ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (uri.path != '' && uri.path != '/' && uri.path != '/frame.jpg')) {
      return null;
    }
    final query = uri.queryParametersAll;
    final token = query['token'];
    if (query.length != 1 ||
        token == null ||
        token.length != 1 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token.single)) {
      return null;
    }
    return VrCastSession._(uri.replace(path: '/'));
  }
}

/// IPv4 LAN and loopback only in this first preview protocol. Loopback permits
/// an on-device viewer/test, but the host never advertises it to other devices.
bool isVrCastLocalAddress(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255 || '$value' != part) {
      return false;
    }
    octets.add(value);
  }
  return octets[0] == 10 ||
      octets[0] == 127 ||
      (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] == 192 && octets[1] == 168);
}
