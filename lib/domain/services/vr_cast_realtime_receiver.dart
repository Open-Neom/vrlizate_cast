import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/vr_cast_receiver_stats.dart';
import '../models/vr_cast_video_progress_watchdog.dart';
import '../models/vr_cast_sdp_policy.dart';
import '../models/vr_cast_session.dart';
import 'vr_cast_signaling_client.dart';

enum VrCastRealtimeReceiverState { connecting, playing, unavailable, closed }

/// A single receive-only LAN peer. It never opens a camera or microphone and
/// cannot send controller commands. JPEG remains an independent fallback.
class VrCastRealtimeReceiver extends ChangeNotifier {
  VrCastRealtimeReceiver(
    this.session, {
    VrCastSignalingClient? signaling,
    @visibleForTesting RTCVideoRenderer? videoRenderer,
    @visibleForTesting Future<RTCPeerConnection> Function()? createPeer,
  }) : _signaling = signaling ?? createVrCastSignalingClient(),
       renderer = videoRenderer ?? RTCVideoRenderer(),
       _createPeer = createPeer ?? _createLanPeer;

  final VrCastSession session;
  final RTCVideoRenderer renderer;
  final Future<RTCPeerConnection> Function() _createPeer;
  final VrCastSignalingClient _signaling;
  RTCPeerConnection? _peer;
  MediaStream? _remoteStream;
  Future<void>? _starting;
  Future<void>? _closing;
  Completer<void>? _iceComplete;
  Timer? _firstFrameTimeout;
  Timer? _statsTimer;
  Timer? _heartbeatTimer;
  bool _closed = false;
  bool _notifierDisposed = false;
  bool _rendererInitialized = false;
  bool _sampling = false;
  bool _heartbeatPending = false;
  final String _sessionId = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  bool _offerStarted = false;
  final Stopwatch _clock = Stopwatch();
  final _progressWatchdog = VrCastVideoProgressWatchdog();
  Duration? _previousSampleAt;

  VrCastRealtimeReceiverState state = VrCastRealtimeReceiverState.connecting;
  VrCastReceiverStats stats = const VrCastReceiverStats();
  bool stereo = false;

  /// A bounded diagnostic label; never exposes native errors or credentials.
  String? fallbackReason;

  bool get isPlaying => state == VrCastRealtimeReceiverState.playing;

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (!isSupported) {
      _fail('unsupported-platform');
      return;
    }
    try {
      await renderer.initialize();
      _rendererInitialized = true;
      if (_closed) return;
      renderer.onFirstFrameRendered = _onFirstFrame;
      final peer = await _createPeer();
      _peer = peer;
      if (_closed) return;
      peer.onTrack = _onTrack;
      peer.onConnectionState = (connection) {
        if (_closed) return;
        if (connection == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            connection == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
            connection ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _fail('connection-lost');
        }
      };
      final iceComplete = _iceComplete = Completer<void>();
      peer.onIceGatheringState = (gathering) {
        if (gathering == RTCIceGatheringState.RTCIceGatheringStateComplete &&
            !iceComplete.isCompleted) {
          iceComplete.complete();
        }
      };
      await peer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      if (_closed) return;
      // The plugin's default constraints also request an audio transceiver.
      // This protocol receives video only, even when no microphone was opened.
      final offer = await peer.createOffer({
        'mandatory': {
          'OfferToReceiveAudio': false,
          'OfferToReceiveVideo': true,
        },
        'optional': <Object>[],
      });
      if (_closed) return;
      await peer.setLocalDescription(offer);
      if (_closed) return;
      if (peer.iceGatheringState !=
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        await iceComplete.future.timeout(const Duration(seconds: 6));
      }
      if (_closed) return;
      final local = await peer.getLocalDescription();
      if (_closed) return;
      if (local?.sdp == null || local!.sdp!.isEmpty) {
        _fail('missing-local-description');
        return;
      }
      _offerStarted = true;
      final answer = await _signaling.exchange(session, {
        'type': 'offer',
        'sdp': VrCastSdpPolicy.sanitize(local.sdp!, offer: true),
        'requestId': _sessionId,
      });
      if (_closed) return;
      final sdp = answer['sdp'];
      if (answer['type'] != 'answer' ||
          sdp is! String ||
          sdp.isEmpty ||
          answer['sessionId'] != _sessionId) {
        _fail('invalid-answer');
        return;
      }
      stereo = answer['stereo'] == true;
      await peer.setRemoteDescription(
        RTCSessionDescription(
          VrCastSdpPolicy.sanitize(sdp, offer: false),
          'answer',
        ),
      );
      if (_closed) return;
      _clock.start();
      if (!isPlaying) {
        _firstFrameTimeout = Timer(
          const Duration(seconds: 12),
          () => _fail('no-video-frames'),
        );
      }
      _statsTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_sample()),
      );
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(_heartbeat()),
      );
    } on TimeoutException {
      _fail('negotiation-timeout');
    } on VrCastSdpException {
      _fail('unsafe-video-description');
    } on VrCastSignalingException catch (error) {
      _fail(switch (error.statusCode) {
        401 || 403 => 'access-denied',
        404 || 405 || 501 => 'host-without-video',
        409 || 429 => 'host-busy',
        _ => 'signaling-unavailable',
      });
    } catch (_) {
      _fail('video-unavailable');
    }
  }

  void _onTrack(RTCTrackEvent event) {
    if (_closed || event.track.kind != 'video') return;
    // The host adds its display track with a stream, so Unified Plan supplies
    // the remote stream. Reject a malformed stream instead of opening devices.
    if (event.streams.isEmpty) {
      _fail('missing-video-stream');
      return;
    }
    _remoteStream = event.streams.first;
    renderer.srcObject = _remoteStream;
  }

  void _onFirstFrame() {
    if (_closed || state == VrCastRealtimeReceiverState.unavailable) return;
    _firstFrameTimeout?.cancel();
    _progressWatchdog.observationUnavailable();
    state = VrCastRealtimeReceiverState.playing;
    notifyListeners();
  }

  void _fail(String reason) {
    if (_closed || state == VrCastRealtimeReceiverState.unavailable) return;
    _firstFrameTimeout?.cancel();
    _statsTimer?.cancel();
    _heartbeatTimer?.cancel();
    final safeReason = _failureReasons.contains(reason)
        ? reason
        : 'video-unavailable';
    fallbackReason = safeReason;
    state = VrCastRealtimeReceiverState.unavailable;
    if (const bool.fromEnvironment('VRLIZATE_CAST_LOG')) {
      debugPrint(
        '[VrCastVideoReceiverState] '
        '${jsonEncode({'state': 'unavailable', 'reason': safeReason})}',
      );
    }
    notifyListeners();
  }

  static const _failureReasons = {
    'unsupported-platform',
    'connection-lost',
    'missing-local-description',
    'invalid-answer',
    'no-video-frames',
    'negotiation-timeout',
    'unsafe-video-description',
    'access-denied',
    'host-without-video',
    'host-busy',
    'signaling-unavailable',
    'video-unavailable',
    'missing-video-stream',
    'session-expired',
    'video-stalled',
  };

  Future<void> _heartbeat() async {
    if (_closed || _heartbeatPending) return;
    _heartbeatPending = true;
    try {
      await _signaling.keepAlive(session, _sessionId);
    } catch (_) {
      _fail('session-expired');
    } finally {
      _heartbeatPending = false;
    }
  }

  Future<void> _sample() async {
    final peer = _peer;
    if (_closed || _sampling || peer == null) return;
    _sampling = true;
    try {
      final reports = await peer.getStats().timeout(const Duration(seconds: 2));
      if (_closed) return;
      var foundVideo = false;
      for (final report in reports) {
        final values = report.values;
        if (report.type != 'inbound-rtp' ||
            (values['kind'] != 'video' && values['mediaType'] != 'video')) {
          continue;
        }
        foundVideo = true;
        String? codec;
        for (final candidate in reports) {
          if (candidate.type == 'codec' && candidate.id == values['codecId']) {
            final mime = candidate.values['mimeType'];
            if (mime is String) codec = mime;
            break;
          }
        }
        final now = _clock.elapsed;
        stats = VrCastReceiverStats.fromInboundVideo(
          values,
          previous: _previousSampleAt == null ? null : stats,
          elapsed: now - (_previousSampleAt ?? now),
          codec: codec,
        );
        _previousSampleAt = now;
        if (isPlaying &&
            _progressWatchdog.observe(values['framesDecoded'], now)) {
          _fail('video-stalled');
          return;
        }
        if (const bool.fromEnvironment('VRLIZATE_CAST_LOG')) {
          debugPrint('[VrCastVideoReceiver] ${jsonEncode(stats.toJson())}');
        }
        notifyListeners();
        break;
      }
      if (!foundVideo) _progressWatchdog.observationUnavailable();
    } catch (_) {
      _progressWatchdog.observationUnavailable();
      // Stats are optional. A platform missing a metric must not stop video.
    } finally {
      _sampling = false;
    }
  }

  /// Call after removing the view that references [renderer]. Safe during an
  /// in-flight negotiation; no peer or texture can be installed after cleanup.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    state = VrCastRealtimeReceiverState.closed;
    _firstFrameTimeout?.cancel();
    _statsTimer?.cancel();
    _heartbeatTimer?.cancel();
    final iceComplete = _iceComplete;
    if (iceComplete != null && !iceComplete.isCompleted) iceComplete.complete();
    // The client-generated id lets DELETE cancel even an offer still waiting
    // for ReplayKit permission. Native decoding stops in parallel immediately.
    Future<void> release() async {
      if (!_offerStarted) return;
      try {
        await _signaling.release(session, _sessionId);
      } catch (_) {
        // Host-side TTL and connection state also release abandoned peers.
      }
    }

    await Future.wait([_closeNative(), release()]);
    _signaling.close();
    // An unresponsive native initialization must not block closing the view.
    // Every await in start checks _closed, and its eventual completion collects
    // any resource returned after the first cleanup without rendering it.
    final starting = _starting;
    if (starting != null) {
      unawaited(
        starting.then(
          (_) => _closeNative(),
          onError: (Object _, StackTrace __) => _closeNative(),
        ),
      );
    }
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }

  Future<void> _closeNative() async {
    final peer = _peer;
    _peer = null;
    if (peer != null) {
      peer.onTrack = null;
      peer.onConnectionState = null;
      peer.onIceGatheringState = null;
      try {
        await peer.close();
      } catch (_) {}
      try {
        await peer.dispose();
      } catch (_) {}
    }
    if (_rendererInitialized) {
      _rendererInitialized = false;
      renderer.onFirstFrameRendered = null;
      renderer.srcObject = null;
      try {
        await renderer.dispose();
      } catch (_) {}
    }
    try {
      await _remoteStream?.dispose();
    } catch (_) {}
    _remoteStream = null;
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    unawaited(close());
    super.dispose();
  }
}

Future<RTCPeerConnection> _createLanPeer() => createPeerConnection({
  'iceServers': <Object>[],
  'sdpSemantics': 'unified-plan',
});
