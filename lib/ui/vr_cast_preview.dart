import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/models/vr_cast_session.dart';
import '../domain/services/vr_cast_frame_client.dart';
import '../domain/services/vr_cast_transport_factory.dart';
import '../utils/constants/vr_cast_constants.dart';
import '../utils/constants/vr_cast_translation_constants.dart';

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
    final session = VrCastSession.tryParse(widget.uri.toString());
    if (session == null) {
      _status = VrCastTranslationConstants.invalidViewLink;
      return;
    }
    final client = _client = createVrCastFrameClient();
    final generation = ++_generation;
    unawaited(_next(client, session.frameUri, generation));
  }

  Future<void> _next(VrCastFrameClient client, Uri uri, int generation) async {
    if (!mounted || generation != _generation) return;
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
        if (!mounted || generation != _generation) return;
        final old = _image;
        setState(() {
          _image = next;
          next = null;
          _status = VrCastTranslationConstants.wifiNoAudio;
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
      if (mounted && generation == _generation) {
        final old = _image;
        setState(() {
          _image = null;
          _status = VrCastTranslationConstants.viewPausedCheckWifi;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
      }
    }
    if (!mounted || generation != _generation) return;
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
    _timer?.cancel();
    _timer = null;
    _client?.close();
    _client = null;
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
        if (_image != null)
          RawImage(
            image: _image,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.low,
          ),
        Align(
          alignment: _image == null ? Alignment.center : Alignment.bottomCenter,
          child: Container(
            color: Colors.black54,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 10),
            ),
          ),
        ),
      ],
    ),
  );
}
