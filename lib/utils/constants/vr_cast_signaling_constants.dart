/// Bounds for authenticated, local-only WebRTC signaling. Media never uses
/// these HTTP endpoints; ICE candidates are included in the complete SDP.
abstract final class VrCastSignalingConstants {
  static const offerPath = '/rtc/offer';
  static const sessionPath = '/rtc/session';
  static const maxBodyBytes = 64 * 1024;
  static const maxSdpBytes = 48 * 1024;
  static const bodyTimeout = Duration(seconds: 3);
  // Initial platform screen-capture consent can require a human response.
  static const handshakeTimeout = Duration(seconds: 45);
  static const sessionRequestTimeout = Duration(seconds: 5);
  static const iceGatheringTimeout = Duration(seconds: 6);
  static const sessionLifetime = Duration(minutes: 2);
  static const heartbeatInterval = Duration(seconds: 20);
  static const maxConcurrentBodyReaders = 4;
  static const sessionIdPattern = r'^[a-f0-9]{32}$';
}
