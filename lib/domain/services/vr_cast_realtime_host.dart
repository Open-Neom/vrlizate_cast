import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../utils/constants/vr_cast_signaling_constants.dart';
import '../models/vr_cast_sdp_policy.dart';

/// One foreground, video-only LAN spectator. Screen capture belongs to the
/// same source/lease as the HTTP cast and is revoked when that source changes.
class VrCastRealtimeHost extends ChangeNotifier {
  VrCastRealtimeHost({
    @visibleForTesting
    Future<MediaStream> Function(Map<String, dynamic>)? captureDisplay,
    @visibleForTesting
    Future<RTCPeerConnection> Function(Map<String, dynamic>)? createPeer,
    @visibleForTesting Future<void> Function()? cancelDisplay,
    @visibleForTesting
    Future<RTCRtpCapabilities> Function(String)? senderCapabilities,
    @visibleForTesting DateTime Function()? now,
    @visibleForTesting
    this.handshakeTimeout = VrCastSignalingConstants.handshakeTimeout,
    @visibleForTesting
    this.sessionLifetime = VrCastSignalingConstants.sessionLifetime,
  }) : _captureDisplay =
           captureDisplay ??
           ((constraints) =>
               navigator.mediaDevices.getDisplayMedia(constraints)),
       _captureSupported =
           captureDisplay != null ||
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS),
       _createPeer =
           createPeer ??
           ((configuration) => createPeerConnection(configuration)),
       _cancelDisplay = cancelDisplay ?? Helper.cancelPendingDisplayMedia,
       _senderCapabilities = senderCapabilities ?? getRtpSenderCapabilities,
       _now = now ?? DateTime.now;

  final Future<MediaStream> Function(Map<String, dynamic>) _captureDisplay;
  // This release validates ReplayKit capture. Android remains a receive-only
  // WebRTC peer until MediaProjection's foreground admission is integrated.
  final bool _captureSupported;
  final Future<RTCPeerConnection> Function(Map<String, dynamic>) _createPeer;
  final Future<void> Function() _cancelDisplay;
  final Future<RTCRtpCapabilities> Function(String) _senderCapabilities;
  final DateTime Function() _now;
  final Duration handshakeTimeout;
  final Duration sessionLifetime;
  final Map<String, DateTime> _cancelledRequests = {};
  final Stopwatch _clock = Stopwatch()..start();
  _RealtimeSession? _session;
  int _epoch = 0;
  bool _active = false;
  bool _stereo = true;
  bool _disposed = false;
  String? _lastFailure;
  Map<String, Object?> _lastStats = {};

  bool get isAwaitingConsent => _session?.awaitingConsent ?? false;
  bool get isStreaming => _session?.connected ?? false;
  bool get hasVideoSession => _session != null;

  Map<String, Object?> get diagnostics => {
    'available': _active && !_disposed && _captureSupported,
    'awaitingConsent': isAwaitingConsent,
    'streaming': isStreaming,
    'sessionActive': _session != null,
    'transport': 'webrtc-lan-video',
    'fpsCap': 24,
    'maxBitrate': 1800000,
    'captureWidth': 1280,
    'captureHeight': 720,
    'stereo': _stereo,
    if (_session case final session?) ...{
      'connectionState': session.state,
      'codecPreferenceApplied': session.codecPreferenceApplied,
      'senderLimitsApplied': session.senderLimitsApplied,
    },
    if (_lastFailure != null) 'lastFailure': _lastFailure,
    ..._lastStats,
  };

  /// Calling with inactive or changed stereo layout invalidates every pending
  /// operation before asynchronous cleanup, including a late consent result.
  void setSource({required bool active, bool stereo = true}) {
    if (_disposed) return;
    if (_active == active && _stereo == stereo) return;
    _active = active;
    _stereo = stereo;
    unawaited(stop());
    _notify();
  }

  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer) async {
    try {
      return await _acceptOffer(offer);
    } on VrCastRealtimeException catch (error) {
      _logFailure(error.code, statusCode: error.statusCode);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _acceptOffer(Map<String, dynamic> offer) async {
    if (!_captureSupported) {
      throw const VrCastRealtimeException(501, 'capture-platform-unavailable');
    }
    if (_disposed || !_active) {
      throw const VrCastRealtimeException(503, 'source-unavailable');
    }
    final id = offer['requestId'];
    final rawSdp = offer['sdp'];
    if (offer['type'] != 'offer' || !_validId(id) || rawSdp is! String) {
      throw const VrCastRealtimeException(400, 'invalid-offer');
    }
    _pruneTombstones();
    if (_cancelledRequests.containsKey(id)) {
      throw const VrCastRealtimeException(410, 'session-cancelled');
    }
    if (_session != null) {
      throw const VrCastRealtimeException(409, 'spectator-busy');
    }
    String sdp;
    try {
      sdp = VrCastSdpPolicy.sanitize(rawSdp, offer: true);
    } on VrCastSdpException {
      throw const VrCastRealtimeException(400, 'unsafe-video-description');
    }
    // Reserve before touching native screen capture or showing consent.
    final session = _RealtimeSession(id as String, ++_epoch, _stereo);
    _session = session;
    _lastFailure = null;
    _lastStats = {};
    _renewLease(session);
    _notify();
    try {
      return await Future.any<Map<String, dynamic>>([
        _negotiate(session, sdp),
        session.cancelled.future.then((_) {
          throw const VrCastRealtimeException(410, 'session-cancelled');
        }),
      ]).timeout(
        handshakeTimeout,
        onTimeout: () {
          _lastFailure = 'negotiation-timeout';
          _rememberCancellation(session.id);
          unawaited(_closeSession(session));
          throw const VrCastRealtimeException(504, 'negotiation-timeout');
        },
      );
    } catch (error) {
      if (error is! VrCastRealtimeException) {
        _lastFailure = 'capture-unavailable';
      }
      unawaited(_closeSession(session));
      if (error is VrCastRealtimeException) rethrow;
      throw const VrCastRealtimeException(503, 'capture-unavailable');
    }
  }

  Future<Map<String, dynamic>> _negotiate(
    _RealtimeSession session,
    String sdp,
  ) async {
    final stream = await _captureDisplay({
      'audio': false,
      'video': {'width': 1280, 'height': 720, 'frameRate': 24},
    });
    if (!_live(session)) {
      await _disposeStream(stream);
      throw const VrCastRealtimeException(410, 'session-cancelled');
    }
    session.stream = stream;
    session.awaitingConsent = false;
    final tracks = stream.getVideoTracks();
    if (tracks.length != 1 || stream.getAudioTracks().isNotEmpty) {
      throw const VrCastRealtimeException(503, 'video-capture-unavailable');
    }
    final track = tracks.single;
    track.onEnded = () => _end(session, 'capture-ended');
    _notify();
    final peer = await _createPeer({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': 'all',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
    if (!_live(session)) {
      await _disposePeer(peer);
      throw const VrCastRealtimeException(410, 'session-cancelled');
    }
    session.peer = peer;
    peer.onConnectionState = (state) => _connectionChanged(session, state);
    final gathered = Completer<void>();
    peer.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    await peer.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _checkLive(session);
    final sender = await peer.addTrack(track, stream);
    _checkLive(session);
    await _preferH264(session, peer);
    _checkLive(session);
    // The native plugin defaults to receiving audio and video. The visor sends
    // its existing screen track and receives neither media kind in this path.
    final answer = await peer.createAnswer({
      'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
      'optional': <Object>[],
    });
    _checkLive(session);
    await peer.setLocalDescription(answer);
    _checkLive(session);
    if (peer.iceGatheringState !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      try {
        await gathered.future.timeout(
          VrCastSignalingConstants.iceGatheringTimeout,
        );
      } on TimeoutException {
        throw const VrCastRealtimeException(504, 'ice-gathering-timeout');
      }
    }
    _checkLive(session);
    var negotiatedSender = sender;
    try {
      // Native sender objects cache parameters. Refresh after applying the
      // answer so encodings and transactionId reflect the negotiated sender.
      final senders = await peer.getSenders();
      for (final candidate in senders) {
        if (candidate.track?.kind == 'video') {
          negotiatedSender = candidate;
          break;
        }
      }
    } catch (_) {}
    _checkLive(session);
    await _limitSender(session, negotiatedSender);
    _checkLive(session);
    final local = await peer.getLocalDescription();
    _checkLive(session);
    String answerSdp;
    try {
      answerSdp = VrCastSdpPolicy.sanitize(local?.sdp ?? '', offer: false);
    } on VrCastSdpException {
      throw const VrCastRealtimeException(503, 'private-lan-unavailable');
    }
    return {
      'type': 'answer',
      'sdp': answerSdp,
      'sessionId': session.id,
      'stereo': session.stereo,
      'framesPerSecond': 24,
      'width': 1280,
      'height': 720,
    };
  }

  Future<void> _preferH264(
    _RealtimeSession session,
    RTCPeerConnection peer,
  ) async {
    try {
      final codecs = (await _senderCapabilities('video')).codecs ?? [];
      _checkLive(session);
      final h264 = codecs.where(
        (c) => c.mimeType.toLowerCase() == 'video/h264',
      );
      if (h264.isEmpty) return;
      final preference = [
        ...h264,
        ...codecs.where((c) => c.mimeType.toLowerCase() != 'video/h264'),
      ];
      for (final transceiver in await peer.getTransceivers()) {
        _checkLive(session);
        if (transceiver.sender.track?.kind == 'video') {
          await transceiver.setCodecPreferences(preference);
          session.codecPreferenceApplied = true;
        }
      }
    } catch (_) {
      // A preference is optional; actual negotiated codec comes from stats.
    }
  }

  Future<void> _limitSender(
    _RealtimeSession session,
    RTCRtpSender sender,
  ) async {
    try {
      final parameters = sender.parameters;
      final encodings = parameters.encodings;
      if (encodings == null || encodings.isEmpty) return;
      for (final encoding in encodings) {
        encoding.maxBitrate = 1800000;
        encoding.maxFramerate = 24;
      }
      session.senderLimitsApplied = await sender.setParameters(parameters);
    } catch (_) {
      // Native support varies. Report whether limits were actually accepted.
    }
  }

  void _connectionChanged(
    _RealtimeSession session,
    RTCPeerConnectionState state,
  ) {
    if (!_live(session)) return;
    session.state = state.name;
    session.connected =
        state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
    if (session.connected) {
      session.disconnectGrace?.cancel();
      session.disconnectGrace = null;
      session.statsTimer ??= Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_readStats(session)),
      );
      unawaited(_readStats(session));
    } else if (state ==
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      session.disconnectGrace ??= Timer(
        const Duration(seconds: 3),
        () => _end(session, 'peer-disconnected'),
      );
    } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      _end(session, 'peer-closed');
    }
    _notify();
  }

  Future<void> _readStats(_RealtimeSession session) async {
    if (!_live(session) || session.readingStats || session.peer == null) return;
    session.readingStats = true;
    try {
      final reports = await session.peer!.getStats().timeout(
        const Duration(seconds: 2),
      );
      if (!_live(session)) return;
      final stats = <String, Object?>{};
      for (final report in reports) {
        final values = report.values;
        if (report.type != 'outbound-rtp' ||
            values['isRemote'] == true ||
            (values['kind'] ?? values['mediaType']) != 'video') {
          continue;
        }
        for (final key in [
          'framesEncoded',
          'bytesSent',
          'framesPerSecond',
          'frameWidth',
          'frameHeight',
          'totalEncodeTime',
        ]) {
          final value = values[key];
          if (value is num && value.isFinite && value >= 0) stats[key] = value;
        }
        final implementation = values['encoderImplementation'];
        if (_safeLabel(implementation)) {
          stats['encoderImplementation'] = implementation;
        }
        final efficient = values['powerEfficientEncoder'];
        if (efficient is bool) stats['powerEfficientEncoder'] = efficient;
        final limitation = values['qualityLimitationReason'];
        if (const {'none', 'cpu', 'bandwidth', 'other'}.contains(limitation)) {
          stats['qualityLimitationReason'] = limitation;
        }
        for (final codec in reports) {
          if (codec.type == 'codec' &&
              codec.id == values['codecId'] &&
              _safeLabel(codec.values['mimeType'])) {
            stats['codec'] = codec.values['mimeType'];
          }
        }
        final frames = stats['framesEncoded'];
        final time = _clock.elapsedMicroseconds;
        if (frames is num) {
          final previous = session.previousFrames;
          final elapsed = time - session.previousStatsUs;
          if (previous != null && frames >= previous && elapsed > 0) {
            stats['estimatedFps'] = (frames - previous) * 1000000 / elapsed;
          }
          session.previousFrames = frames;
          session.previousStatsUs = time;
        }
        break;
      }
      _lastStats = stats;
      if (const bool.fromEnvironment('VRLIZATE_CAST_LOG')) {
        debugPrint('[VrCastVideoSender] ${jsonEncode(diagnostics)}');
      }
      _notify();
    } catch (_) {
      // A failed optional stats query must not interrupt the media stream.
    } finally {
      session.readingStats = false;
    }
  }

  bool _safeLabel(Object? value) =>
      value is String &&
      RegExp(r'^[a-zA-Z0-9 .+/_()\-]{1,120}$').hasMatch(value);

  void keepAlive(String requestId) {
    final session = _session;
    if (session != null && _live(session) && session.id == requestId) {
      _renewLease(session);
    }
  }

  Future<void> release(String requestId) async {
    if (!_validId(requestId)) {
      throw const VrCastRealtimeException(400, 'invalid-session');
    }
    // DELETE can arrive before the initial POST on a second HTTP connection.
    _rememberCancellation(requestId);
    final session = _session;
    if (session != null && session.id == requestId) {
      await _closeSession(session);
    }
  }

  void _renewLease(_RealtimeSession session) {
    session.lease?.cancel();
    session.lease = Timer(
      sessionLifetime,
      () => _end(session, 'lease-expired'),
    );
  }

  void _end(_RealtimeSession session, String reason) {
    if (!_live(session)) return;
    _lastFailure = reason;
    _logFailure(reason);
    _rememberCancellation(session.id);
    unawaited(_closeSession(session));
  }

  void _logFailure(String reason, {int? statusCode}) {
    if (!const bool.fromEnvironment('VRLIZATE_CAST_LOG')) return;
    final safeReason = _failureReasons.contains(reason)
        ? reason
        : 'capture-unavailable';
    debugPrint(
      '[VrCastVideoSenderState] '
      '${jsonEncode({'state': 'unavailable', 'reason': safeReason, if (statusCode != null) 'statusCode': statusCode})}',
    );
  }

  static const _failureReasons = {
    'capture-platform-unavailable',
    'source-unavailable',
    'invalid-offer',
    'session-cancelled',
    'spectator-busy',
    'unsafe-video-description',
    'negotiation-timeout',
    'capture-unavailable',
    'video-capture-unavailable',
    'ice-gathering-timeout',
    'private-lan-unavailable',
    'capture-ended',
    'peer-disconnected',
    'peer-closed',
    'lease-expired',
  };

  bool _live(_RealtimeSession session) =>
      !_disposed &&
      _active &&
      identical(_session, session) &&
      session.epoch == _epoch &&
      !session.cancelled.isCompleted;

  void _checkLive(_RealtimeSession session) {
    if (!_live(session)) {
      throw const VrCastRealtimeException(410, 'session-cancelled');
    }
  }

  static bool _validId(Object? id) =>
      id is String &&
      RegExp(VrCastSignalingConstants.sessionIdPattern).hasMatch(id);

  void _rememberCancellation(String id) {
    _pruneTombstones();
    _cancelledRequests.remove(id);
    _cancelledRequests[id] = _now().add(
      VrCastSignalingConstants.sessionLifetime,
    );
    while (_cancelledRequests.length > 32) {
      _cancelledRequests.remove(_cancelledRequests.keys.first);
    }
  }

  void _pruneTombstones() {
    final now = _now();
    _cancelledRequests.removeWhere((_, expires) => !expires.isAfter(now));
  }

  Future<void> stop() async {
    _epoch++;
    final session = _session;
    if (session == null) return;
    _rememberCancellation(session.id);
    await _closeSession(session);
  }

  /// A navigation curtain must stay opaque until native capture admission is
  /// acknowledged closed. Unlike best-effort cleanup, this barrier must not
  /// turn a timeout into permission to expose a private page.
  Future<void> suspendBeforeNavigation() async {
    final closing = stop();
    await _cancelDisplay();
    await closing;
  }

  Future<void> _closeSession(_RealtimeSession session) =>
      session.closing ??= _cleanup(session);

  Future<void> _cleanup(_RealtimeSession session) async {
    if (!session.cancelled.isCompleted) session.cancelled.complete();
    session.connected = false;
    session.awaitingConsent = false;
    session.lease?.cancel();
    session.disconnectGrace?.cancel();
    session.statsTimer?.cancel();
    final peer = session.peer;
    final stream = session.stream;
    session.peer = null;
    session.stream = null;
    if (peer != null) {
      peer.onConnectionState = null;
      peer.onIceGatheringState = null;
    }
    for (final track in stream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.onEnded = null;
      // Revoke synchronously before native stop/permission callbacks complete.
      track.enabled = false;
    }
    _notify();
    await Future.wait([
      _bounded(_cancelDisplay),
      if (stream != null) _disposeStream(stream),
      if (peer != null) _disposePeer(peer),
    ]);
    if (identical(_session, session)) {
      _session = null;
      _lastStats = {};
      _notify();
    }
  }

  Future<void> _disposeStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      track.onEnded = null;
      track.enabled = false;
      await _bounded(track.stop);
    }
    await _bounded(stream.dispose);
  }

  Future<void> _disposePeer(RTCPeerConnection peer) async {
    await _bounded(peer.close);
    await _bounded(peer.dispose);
  }

  Future<void> _bounded(Future<void> Function() operation) async {
    try {
      await operation().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}

class _RealtimeSession {
  _RealtimeSession(this.id, this.epoch, this.stereo);
  final String id;
  final int epoch;
  final bool stereo;
  final Completer<void> cancelled = Completer<void>();
  Future<void>? closing;
  MediaStream? stream;
  RTCPeerConnection? peer;
  Timer? lease;
  Timer? disconnectGrace;
  Timer? statsTimer;
  bool awaitingConsent = true;
  bool connected = false;
  bool readingStats = false;
  bool codecPreferenceApplied = false;
  bool senderLimitsApplied = false;
  String state = 'awaiting-consent';
  num? previousFrames;
  int previousStatsUs = 0;
}

class VrCastRealtimeException implements Exception {
  const VrCastRealtimeException(this.statusCode, this.code);
  final int statusCode;
  final String code;
  @override
  String toString() => 'Realtime cast failed: $code ($statusCode).';
}
