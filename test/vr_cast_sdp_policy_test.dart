import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/domain/models/vr_cast_sdp_policy.dart';

String _sdp({String direction = 'recvonly', String candidates = ''}) =>
    'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
    'm=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP6 2001:db8::1\r\n'
    'a=$direction\r\na=rtcp-mux\r\na=rtpmap:96 VP8/90000\r\n'
    'a=candidate:1 1 udp 2122260223 192.168.1.20 54321 typ host\r\n'
    '$candidates';

void main() {
  test('keeps private host video and strips public IPv6 relay and mDNS', () {
    final result = VrCastSdpPolicy.sanitize(
      _sdp(
        candidates:
            'a=candidate:2 1 udp 1 8.8.8.8 2000 typ host\r\n'
            'a=candidate:3 1 udp 1 2001:db8::2 2000 typ host\r\n'
            'a=candidate:4 1 udp 1 10.0.0.2 2000 typ relay\r\n'
            'a=candidate:5 1 udp 1 host.local 2000 typ host\r\n'
            'a=candidate:6 1 udp 1 127.0.0.1 2000 typ host\r\n'
            'a=remote-candidates:1 8.8.8.8 2000\r\n',
      ),
      offer: true,
    );
    expect(result, contains('192.168.1.20 54321 typ host'));
    expect(result, contains('c=IN IP4 0.0.0.0'));
    expect(result, isNot(contains('8.8.8.8')));
    expect(result, isNot(contains('2001:')));
    expect(result, isNot(contains('host.local')));
    expect(result, isNot(contains('typ relay')));
    expect(result, isNot(contains('remote-candidates')));
  });

  test('requires one private candidate after sanitizing', () {
    final value = _sdp().replaceAll('192.168.1.20', '8.8.8.8');
    expect(
      () => VrCastSdpPolicy.sanitize(value, offer: true),
      throwsA(isA<VrCastSdpException>()),
    );
  });

  test('rejects audio and data channels even when marked inactive', () {
    for (final media in [
      'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=inactive\r\n',
      'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=inactive\r\n',
    ]) {
      expect(
        () => VrCastSdpPolicy.sanitize('${_sdp()}$media', offer: true),
        throwsA(isA<VrCastSdpException>()),
      );
    }
  });

  test('only receiver offers and sender answers are permitted', () {
    expect(
      VrCastSdpPolicy.sanitize(_sdp(direction: 'sendonly'), offer: false),
      contains('a=sendonly'),
    );
    for (final direction in ['sendrecv', 'sendonly', 'inactive']) {
      expect(
        () => VrCastSdpPolicy.sanitize(_sdp(direction: direction), offer: true),
        throwsA(isA<VrCastSdpException>()),
      );
    }
  });

  test('rejects ambiguous duplicate directions and non-multiplexed RTCP', () {
    for (final value in [
      _sdp().replaceFirst('a=recvonly', 'a=recvonly\r\na=sendrecv'),
      _sdp().replaceFirst('a=rtcp-mux\r\n', ''),
    ]) {
      expect(
        () => VrCastSdpPolicy.sanitize(value, offer: true),
        throwsA(isA<VrCastSdpException>()),
      );
    }
  });

  test('related candidate addresses are removed and TCP mode retained', () {
    final result = VrCastSdpPolicy.sanitize(
      _sdp(
        candidates:
            'a=candidate:2 1 tcp 1 10.0.0.3 9 typ host tcptype active raddr 8.8.8.8 rport 20\r\n',
      ),
      offer: true,
    );
    expect(result, contains('10.0.0.3 9 typ host tcptype active'));
    expect(result, isNot(contains('8.8.8.8')));
  });

  test('IPv4 policy recognizes only canonical RFC1918 addresses', () {
    for (final value in [
      '10.0.0.1',
      '172.16.0.1',
      '172.31.255.254',
      '192.168.0.2',
    ]) {
      expect(VrCastSdpPolicy.isPrivateV4(value), isTrue, reason: value);
    }
    for (final value in [
      '172.15.0.1',
      '172.32.0.1',
      '127.0.0.1',
      '192.168.0.999',
      '010.0.0.1',
    ]) {
      expect(VrCastSdpPolicy.isPrivateV4(value), isFalse, reason: value);
    }
  });
}
