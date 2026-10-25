import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vrlizate_cast/domain/models/vr_cast_session.dart';
import 'package:vrlizate_cast/domain/services/vr_cast_realtime_receiver.dart';
import 'package:vrlizate_cast/domain/services/vr_cast_signaling_client.dart';

String _description(String direction) =>
    'v=0\r\n'
    'o=- 1 1 IN IP4 0.0.0.0\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
    'c=IN IP4 0.0.0.0\r\n'
    'a=$direction\r\n'
    'a=rtcp-mux\r\n'
    'a=candidate:1 1 udp 2122260223 192.168.1.20 54321 typ host\r\n';

class _Renderer extends RTCVideoRenderer {
  bool disposed = false;

  @override
  Future<void> initialize() async {}

  @override
  set srcObject(MediaStream? stream) {}

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

class _DelayedRenderer extends _Renderer {
  final initialized = Completer<void>();

  @override
  Future<void> initialize() => initialized.future;
}

class _Transceiver extends Fake implements RTCRtpTransceiver {}

class _Peer extends Fake implements RTCPeerConnection {
  bool closed = false;
  bool disposed = false;
  TransceiverDirection? direction;
  Map<String, dynamic>? offerConstraints;

  @override
  Function(RTCTrackEvent)? onTrack;

  @override
  Function(RTCPeerConnectionState)? onConnectionState;

  @override
  Function(RTCIceGatheringState)? onIceGatheringState;

  @override
  RTCIceGatheringState get iceGatheringState =>
      RTCIceGatheringState.RTCIceGatheringStateComplete;

  @override
  Future<RTCRtpTransceiver> addTransceiver({
    MediaStreamTrack? track,
    RTCRtpMediaType? kind,
    RTCRtpTransceiverInit? init,
  }) async {
    expect(kind, RTCRtpMediaType.RTCRtpMediaTypeVideo);
    direction = init?.direction;
    return _Transceiver();
  }

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async {
    offerConstraints = constraints;
    return RTCSessionDescription(_description('recvonly'), 'offer');
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}

  @override
  Future<RTCSessionDescription?> getLocalDescription() async =>
      RTCSessionDescription(_description('recvonly'), 'offer');

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _Signaling extends VrCastSignalingClient {
  final requested = Completer<Map<String, dynamic>>();
  final answer = Completer<Map<String, dynamic>>();
  String? released;
  bool closed = false;

  @override
  Future<Map<String, dynamic>> exchange(
    VrCastSession session,
    Map<String, dynamic> offer,
  ) {
    requested.complete(offer);
    return answer.future;
  }

  @override
  Future<void> keepAlive(VrCastSession session, String sessionId) async {}

  @override
  Future<void> release(VrCastSession session, String sessionId) async {
    released = sessionId;
  }

  @override
  void close() {
    closed = true;
    if (requested.isCompleted && !answer.isCompleted) {
      answer.completeError(const VrCastSignalingException('closed'));
    }
  }
}

void main() {
  late VrCastSession session;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    session = VrCastSession.tryParse(
      'http://192.168.1.3:12345/?token=${'a' * 64}',
    )!;
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'closing cancels a pending permission offer without waiting for consent',
    () async {
      final signaling = _Signaling();
      final peer = _Peer();
      final renderer = _Renderer();
      final receiver = VrCastRealtimeReceiver(
        session,
        signaling: signaling,
        videoRenderer: renderer,
        createPeer: () async => peer,
      );
      final started = receiver.start();
      final offer = await signaling.requested.future.timeout(
        const Duration(seconds: 1),
      );
      expect(peer.direction, TransceiverDirection.RecvOnly);
      expect(peer.offerConstraints, {
        'mandatory': {
          'OfferToReceiveAudio': false,
          'OfferToReceiveVideo': true,
        },
        'optional': <Object>[],
      });
      expect(offer['requestId'], matches(r'^[a-f0-9]{32}$'));
      await receiver.close().timeout(const Duration(seconds: 1));
      await started;
      expect(signaling.released, offer['requestId']);
      expect(signaling.closed, isTrue);
      expect(peer.closed, isTrue);
      expect(peer.disposed, isTrue);
      expect(renderer.disposed, isTrue);
      expect(receiver.state, VrCastRealtimeReceiverState.closed);
    },
  );

  test(
    'video is selected only after an actual renderer frame and uses same id',
    () async {
      final signaling = _Signaling();
      final renderer = _Renderer();
      final receiver = VrCastRealtimeReceiver(
        session,
        signaling: signaling,
        videoRenderer: renderer,
        createPeer: () async => _Peer(),
      );
      final started = receiver.start();
      final offer = await signaling.requested.future.timeout(
        const Duration(seconds: 1),
      );
      signaling.answer.complete({
        'type': 'answer',
        'sdp': _description('sendonly'),
        'sessionId': offer['requestId'],
        'stereo': true,
      });
      await started;
      expect(receiver.isPlaying, isFalse);
      expect(receiver.stereo, isTrue);
      renderer.onFirstFrameRendered!();
      expect(receiver.isPlaying, isTrue);
      await receiver.close();
    },
  );

  test(
    'an unrelated answer session is rejected and falls back explicitly',
    () async {
      final signaling = _Signaling();
      final receiver = VrCastRealtimeReceiver(
        session,
        signaling: signaling,
        videoRenderer: _Renderer(),
        createPeer: () async => _Peer(),
      );
      final started = receiver.start();
      await signaling.requested.future.timeout(const Duration(seconds: 1));
      signaling.answer.complete({
        'type': 'answer',
        'sdp': _description('sendonly'),
        'sessionId': 'b' * 32,
      });
      await started;
      expect(receiver.state, VrCastRealtimeReceiverState.unavailable);
      expect(receiver.fallbackReason, 'invalid-answer');
      await receiver.close();
    },
  );

  test(
    'close does not wait for native initialization and collects it later',
    () async {
      final renderer = _DelayedRenderer();
      final receiver = VrCastRealtimeReceiver(
        session,
        signaling: _Signaling(),
        videoRenderer: renderer,
        createPeer: () async => _Peer(),
      );
      final started = receiver.start();
      await receiver.close().timeout(const Duration(seconds: 1));
      expect(renderer.disposed, isFalse);
      renderer.initialized.complete();
      await started;
      await Future<void>.delayed(Duration.zero);
      expect(renderer.disposed, isTrue);
      expect(receiver.state, VrCastRealtimeReceiverState.closed);
    },
  );
}
