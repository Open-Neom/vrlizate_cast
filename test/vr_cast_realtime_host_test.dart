import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vrlizate_cast/domain/services/vr_cast_realtime_host.dart';

const _offerSdp =
    'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
    'm=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 0.0.0.0\r\n'
    'a=recvonly\r\na=rtcp-mux\r\na=rtpmap:96 VP8/90000\r\n'
    'a=candidate:1 1 udp 2122260223 192.168.1.20 54321 typ host\r\n';
final _requestId = 'ab' * 16;

Map<String, dynamic> _offer([String? id]) => {
  'type': 'offer',
  'sdp': _offerSdp,
  'requestId': id ?? _requestId,
};

Matcher _status(int status) => isA<VrCastRealtimeException>().having(
  (error) => error.statusCode,
  'statusCode',
  status,
);

class _Track extends Fake implements MediaStreamTrack {
  @override
  bool enabled = true;
  @override
  StreamTrackCallback? onEnded;
  int stops = 0;
  @override
  String get kind => 'video';
  @override
  Future<void> stop() async {
    stops++;
  }
}

class _Stream extends Fake implements MediaStream {
  final _Track track = _Track();
  final disposed = Completer<void>();
  @override
  List<MediaStreamTrack> getTracks() => [track];
  @override
  List<MediaStreamTrack> getVideoTracks() => [track];
  @override
  List<MediaStreamTrack> getAudioTracks() => [];
  @override
  Future<void> dispose() async {
    if (!disposed.isCompleted) disposed.complete();
  }
}

class _Sender extends Fake implements RTCRtpSender {
  _Sender(this.track);
  @override
  final MediaStreamTrack track;
  @override
  final RTCRtpParameters parameters = RTCRtpParameters(
    encodings: [RTCRtpEncoding()],
  );
  bool limitsApplied = false;
  @override
  Future<bool> setParameters(RTCRtpParameters value) async {
    limitsApplied =
        value.encodings!.single.maxBitrate == 1800000 &&
        value.encodings!.single.maxFramerate == 24;
    return limitsApplied;
  }
}

class _Peer extends Fake implements RTCPeerConnection {
  _Peer(_Track track) : sender = _Sender(track);
  final _Sender sender;
  final disposed = Completer<void>();
  int closes = 0;
  Map<String, dynamic>? answerConstraints;
  @override
  Function(RTCPeerConnectionState)? onConnectionState;
  @override
  Function(RTCIceGatheringState)? onIceGatheringState;
  @override
  RTCIceGatheringState get iceGatheringState =>
      RTCIceGatheringState.RTCIceGatheringStateComplete;
  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}
  @override
  Future<RTCRtpSender> addTrack(
    MediaStreamTrack track, [
    MediaStream? stream,
  ]) async => sender;
  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async => [];
  @override
  Future<List<RTCRtpSender>> getSenders() async => [sender];
  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async {
    answerConstraints = constraints;
    return RTCSessionDescription(
      _offerSdp.replaceFirst('a=recvonly', 'a=sendonly'),
      'answer',
    );
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}
  @override
  Future<RTCSessionDescription> getLocalDescription() async =>
      RTCSessionDescription(
        _offerSdp.replaceFirst('a=recvonly', 'a=sendonly'),
        'answer',
      );
  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async => [];
  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<void> dispose() async {
    if (!disposed.isCompleted) disposed.complete();
  }
}

void main() {
  test('reserves before consent and rejects a second spectator', () async {
    final capture = Completer<MediaStream>();
    var cancelCalls = 0;
    var captureCalls = 0;
    final host = VrCastRealtimeHost(
      captureDisplay: (_) {
        captureCalls++;
        return capture.future;
      },
      cancelDisplay: () async {
        cancelCalls++;
      },
    )..setSource(active: true);
    addTearDown(host.dispose);
    final first = host.acceptOffer(_offer());
    final cancelled = expectLater(first, throwsA(_status(410)));
    expect(host.isAwaitingConsent, isTrue);
    await expectLater(
      host.acceptOffer(_offer('cd' * 16)),
      throwsA(_status(409)),
    );
    expect(captureCalls, 1);
    await host.release(_requestId);
    await cancelled;
    final late = _Stream();
    capture.complete(late);
    await late.disposed.future.timeout(const Duration(seconds: 1));
    expect(late.track.enabled, isFalse);
    expect(late.track.stops, 1);
    expect(cancelCalls, 1);
    expect(host.isStreaming, isFalse);
  });

  test(
    'DELETE before POST tombstones the request without invoking capture',
    () async {
      var captureCalls = 0;
      final host = VrCastRealtimeHost(
        captureDisplay: (_) async {
          captureCalls++;
          return _Stream();
        },
        cancelDisplay: () async {},
      )..setSource(active: true);
      addTearDown(host.dispose);
      await host.release(_requestId);
      await expectLater(host.acceptOffer(_offer()), throwsA(_status(410)));
      expect(captureCalls, 0);
    },
  );

  test(
    'source revocation cancels pending consent and destroys its late stream',
    () async {
      final capture = Completer<MediaStream>();
      final host = VrCastRealtimeHost(
        captureDisplay: (_) => capture.future,
        cancelDisplay: () async {},
      )..setSource(active: true);
      addTearDown(host.dispose);
      final pending = expectLater(
        host.acceptOffer(_offer()),
        throwsA(_status(410)),
      );
      host.setSource(active: false);
      await pending;
      final late = _Stream();
      capture.complete(late);
      await late.disposed.future.timeout(const Duration(seconds: 1));
      expect(late.track.enabled, isFalse);
      await expectLater(
        host.acceptOffer(_offer('cd' * 16)),
        throwsA(_status(503)),
      );
    },
  );

  test(
    'negotiation timeout and lease expiry revoke pending captures',
    () async {
      for (final lease in [false, true]) {
        final capture = Completer<MediaStream>();
        final host = VrCastRealtimeHost(
          captureDisplay: (_) => capture.future,
          cancelDisplay: () async {},
          handshakeTimeout: lease
              ? const Duration(seconds: 1)
              : const Duration(milliseconds: 20),
          sessionLifetime: lease
              ? const Duration(milliseconds: 20)
              : const Duration(seconds: 1),
        )..setSource(active: true);
        try {
          await expectLater(
            host.acceptOffer(_offer()),
            throwsA(_status(lease ? 410 : 504)),
          );
          final late = _Stream();
          capture.complete(late);
          await late.disposed.future.timeout(const Duration(seconds: 1));
          expect(late.track.stops, 1);
        } finally {
          host.dispose();
        }
      }
    },
  );

  test(
    'negotiates video limits and revokes an active peer on source change',
    () async {
      final stream = _Stream();
      final peer = _Peer(stream.track);
      Map<String, dynamic>? configuration;
      Map<String, dynamic>? constraints;
      final host = VrCastRealtimeHost(
        captureDisplay: (value) async {
          constraints = value;
          return stream;
        },
        createPeer: (value) async {
          configuration = value;
          return peer;
        },
        cancelDisplay: () async {},
        senderCapabilities: (_) async => RTCRtpCapabilities(codecs: []),
      )..setSource(active: true);
      addTearDown(host.dispose);
      final answer = await host.acceptOffer(_offer());
      expect(answer['sessionId'], _requestId);
      expect(answer['framesPerSecond'], 24);
      expect(answer['stereo'], isTrue);
      expect(configuration!['iceServers'], isEmpty);
      expect(constraints!['audio'], isFalse);
      expect(peer.answerConstraints, {
        'mandatory': {
          'OfferToReceiveAudio': false,
          'OfferToReceiveVideo': false,
        },
        'optional': <Object>[],
      });
      expect(peer.sender.limitsApplied, isTrue);
      peer.onConnectionState!(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      expect(host.isStreaming, isTrue);
      expect(host.diagnostics.toString(), isNot(contains(_requestId)));
      host.setSource(active: true, stereo: false);
      await peer.disposed.future.timeout(const Duration(seconds: 1));
      await stream.disposed.future.timeout(const Duration(seconds: 1));
      expect(stream.track.enabled, isFalse);
      expect(peer.closes, 1);
      expect(host.isStreaming, isFalse);
    },
  );
}
