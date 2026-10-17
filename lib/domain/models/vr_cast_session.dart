import '../../utils/constants/vr_cast_constants.dart';

/// A local spectator URL. It never carries a controller pairing credential.
class VrCastSession {
  const VrCastSession._(this.viewerUri, {this.pinCode});

  final Uri viewerUri;
  final String? pinCode;

  Uri get frameUri => viewerUri.replace(path: VrCastConstants.framePath);

  static VrCastSession? tryParse(String value) {
    if (value.length > VrCastConstants.maxSessionUriLength) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != VrCastConstants.httpScheme ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !isVrCastLocalAddress(uri.host) ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (uri.path != VrCastConstants.emptyString &&
            uri.path != VrCastConstants.rootPath &&
            uri.path != VrCastConstants.framePath)) {
      return null;
    }
    final query = uri.queryParametersAll;
    final token = query[VrCastConstants.queryToken];
    if (token == null ||
        token.length != 1 ||
        !RegExp(VrCastConstants.tokenHexPattern).hasMatch(token.single)) {
      return null;
    }
    final pin = query[VrCastConstants.queryPin];
    if (pin != null) {
      if (query.length != 2 ||
          pin.length != 1 ||
          !RegExp(VrCastConstants.pinCodePattern).hasMatch(pin.single)) {
        return null;
      }
    } else if (query.length != 1) {
      return null;
    }
    return VrCastSession._(
      uri.replace(path: VrCastConstants.rootPath),
      pinCode: pin?.single,
    );
  }
}

/// IPv4 LAN and loopback only in this preview protocol. Loopback permits
/// an on-device viewer/test, but the host never advertises it to other devices.
bool isVrCastLocalAddress(String host) {
  final parts = host.split(VrCastConstants.ipv4Separator);
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
