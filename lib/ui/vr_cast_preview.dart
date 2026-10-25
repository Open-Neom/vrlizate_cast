import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../domain/models/vr_cast_session.dart';
import '../domain/services/vr_cast_frame_client.dart';
import '../domain/services/vr_cast_realtime_receiver.dart';
import '../domain/services/vr_cast_transport_factory.dart';
import '../utils/constants/vr_cast_constants.dart';
import '../utils/constants/vr_cast_translation_constants.dart';
import 'vr_cast_video_viewport.dart';

/// A read-only receiver. Network failures never reach a controller transport.
class VrCastPreview extends StatefulWidget {
  const VrCastPreview({super.key, required this.uri});
  final Uri uri;
  @override
  State<VrCastPreview> createState() => _VrCastPreviewState();
}

class _VrCastPreviewState extends State<VrCastPreview>
    with WidgetsBindingObserver {
  VrCastFrameClient? _client;
  Timer? _timer;
  ui.Image? _image;
  VrCastRealtimeReceiver? _realtime;
  Future<void>? _retiringRealtime;
  String? _fallbackReason;
  bool _retrying = false;
  int _generation = 0;
  String _status = VrCastTranslationConstants.connectingWifiView;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _start();
  }

  @override
  void didUpdateWidget(VrCastPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) {
      _stop();
      _start();
    }
  }

  void _start() {
    if (!_foreground) return;
    _fallbackReason = null;
    _status = VrCastTranslationConstants.connectingWifiView;
    final session = VrCastSession.tryParse(widget.uri.toString());
    if (session == null) {
      _status = VrCastTranslationConstants.invalidViewLink;
      return;
    }
    final generation = ++_generation;
    _startJpeg(session, generation);
    _startRealtime(session);
  }

  void _startRealtime(VrCastSession session) {
    if (VrCastRealtimeReceiver.isSupported) {
      final receiver = _realtime = VrCastRealtimeReceiver(session);
      receiver.addListener(_onRealtimeChanged);
      unawaited(receiver.start());
    }
  }

  Future<void> _retryRealtime() async {
    if (_retrying || _realtime != null || !_foreground) return;
    final session = VrCastSession.tryParse(widget.uri.toString());
    if (session == null) return;
    final generation = _generation;
    setState(() {
      _retrying = true;
      _fallbackReason = null;
      _status = 'Vista previa · Conectando vídeo…';
    });
    // Release the previous host slot before an explicit new negotiation.
    await _retiringRealtime;
    if (!mounted || !_foreground || generation != _generation) return;
    setState(() {
      _retrying = false;
      _startRealtime(session);
    });
  }

  void _startJpeg(VrCastSession session, int generation) {
    if (_client != null) return;
    final client = _client = createVrCastFrameClient();
    unawaited(_next(client, session.frameUri, generation));
  }

  void _stopJpeg() {
    _timer?.cancel();
    _timer = null;
    _client?.close();
    _client = null;
  }

  bool _canRead(VrCastFrameClient client, int generation) =>
      mounted &&
      _foreground &&
      generation == _generation &&
      identical(client, _client) &&
      !(_realtime?.isPlaying ?? false);

  void _onRealtimeChanged() {
    final receiver = _realtime;
    if (!mounted || receiver == null) return;
    if (receiver.isPlaying) {
      _stopJpeg();
      final old = _image;
      setState(() {
        _image = null;
        final fps = receiver.stats.framesPerSecond;
        _status = fps > 0
            ? 'Vídeo · ${fps.toStringAsFixed(0)} FPS · Wi-Fi · Sin audio'
            : 'Reproducción fluida · Wi-Fi · Sin audio';
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
    } else if (receiver.state == VrCastRealtimeReceiverState.unavailable) {
      receiver.removeListener(_onRealtimeChanged);
      _realtime = null;
      _fallbackReason = receiver.fallbackReason;
      setState(() => _status = _jpegStatus);
      _retiringRealtime = receiver.close();
      final session = VrCastSession.tryParse(widget.uri.toString());
      if (_foreground && session != null) _startJpeg(session, _generation);
    }
  }

  String get _jpegStatus => _retrying || _realtime != null
      ? 'Vista previa · Conectando vídeo…'
      : switch (_fallbackReason) {
          null => VrCastTranslationConstants.wifiNoAudio,
          'access-denied' => 'Vista previa · Vídeo sin autorización',
          'host-busy' => 'Vista previa · Vídeo ocupado',
          'connection-lost' ||
          'session-expired' => 'Vista previa · Vídeo desconectado',
          'host-without-video' || 'unsupported-platform' =>
            'Vista previa · Vídeo no disponible en este visor',
          'no-video-frames' => 'Vista previa · No llegaron imágenes del vídeo',
          'video-stalled' => 'Vista previa · El vídeo dejó de avanzar',
          _ => 'Vista previa · Vídeo no disponible',
        };

  Future<void> _next(VrCastFrameClient client, Uri uri, int generation) async {
    if (!_canRead(client, generation)) return;
    final clock = Stopwatch()..start();
    var failed = false;
    try {
      final bytes = await client.read(uri);
      // Inspect dimensions before decoding a potentially untrusted JPEG.
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      ui.Image? next;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        if (descriptor.width < 1 ||
            descriptor.height < 1 ||
            descriptor.width > 1280 ||
            descriptor.height > 1280) {
          throw const FormatException(VrCastConstants.errInvalidDimensions);
        }
        codec = await descriptor.instantiateCodec(
          targetWidth: descriptor.width.clamp(1, 640),
        );
        next = (await codec.getNextFrame()).image;
        if (!_canRead(client, generation)) return;
        final old = _image;
        setState(() {
          _image = next;
          next = null;
          _status = _jpegStatus;
        });
        // RawImage may still reference the old handle until the next paint.
        WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
      } finally {
        next?.dispose();
        codec?.dispose();
        descriptor?.dispose();
        buffer.dispose();
      }
    } catch (_) {
      failed = true;
      if (_canRead(client, generation)) {
        final old = _image;
        setState(() {
          _image = null;
          _status = VrCastTranslationConstants.viewPausedCheckWifi;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
      }
    }
    if (!_canRead(client, generation)) return;
    final delay = failed
        ? 1000
        : (334 - clock.elapsedMilliseconds).clamp(20, 334);
    _timer = Timer(
      Duration(milliseconds: delay),
      () => unawaited(_next(client, uri, generation)),
    );
  }

  void _stop() {
    _generation++;
    _retrying = false;
    _stopJpeg();
    final receiver = _realtime;
    _realtime = null;
    receiver?.removeListener(_onRealtimeChanged);
    if (receiver != null) _retiringRealtime = receiver.close();
    final old = _image;
    _image = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _stop();
    if (mounted) {
      setState(() => _status = VrCastTranslationConstants.viewPaused);
    }
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF050A12),
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (_realtime case final receiver? when receiver.isPlaying)
          _VrCastRealtimeView(receiver: receiver)
        else if (_image != null)
          RawImage(
            image: _image,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.low,
          ),
        Align(
          alignment: _image == null && !(_realtime?.isPlaying ?? false)
              ? Alignment.center
              : Alignment.bottomCenter,
          child: Container(
            color: Colors.black54,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
                if (_fallbackReason != null &&
                    !_retrying &&
                    VrCastRealtimeReceiver.isSupported)
                  TextButton(
                    key: const ValueKey('cast-retry-video'),
                    onPressed: _retryRealtime,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 24),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text(
                      'Reintentar vídeo',
                      style: TextStyle(fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// Full screen capture arrives in stereo. Show its left half with its original
/// aspect ratio; the controller sees one eye without stretching two images.
class _VrCastRealtimeView extends StatelessWidget {
  const _VrCastRealtimeView({required this.receiver});
  final VrCastRealtimeReceiver receiver;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<RTCVideoValue>(
    valueListenable: receiver.renderer,
    builder: (context, value, _) => VrCastVideoViewport(
      videoAspectRatio: value.aspectRatio,
      stereo: receiver.stereo,
      child: RTCVideoView(receiver.renderer),
    ),
  );
}
