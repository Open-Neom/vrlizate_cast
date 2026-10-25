import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

import '../domain/models/vr_cast_source_handle.dart';
import '../domain/services/vr_cast_host.dart';
import '../utils/enums/vr_cast_eye.dart';
import 'vr_cast_boundary.dart';
import 'vr_render_cast_boundary.dart';

Rect vrCastEyeBounds(Size size, VrCastEye eye) => switch (eye) {
  VrCastEye.left => Rect.fromLTWH(0, 0, size.width / 2, size.height),
  VrCastEye.right => Rect.fromLTWH(
    size.width / 2,
    0,
    size.width / 2,
    size.height,
  ),
  VrCastEye.stereo => Offset.zero & size,
};

/// Captures only the selected region of the already composed Flutter layer.
/// The rendering engine continues to own all stereo/foveation work.
class VrCastSurface extends StatefulWidget {
  const VrCastSurface({
    super.key,
    required this.host,
    required this.child,
    this.enabled = true,
    this.eye = VrCastEye.left,
    this.realtimeStereo = true,
  });

  final VrCastHost host;
  final Widget child;
  final bool enabled;
  final VrCastEye eye;

  /// The native screen capture includes both eyes. JPEG's selected eye is
  /// independent of this full-screen video layout.
  final bool realtimeStereo;

  @override
  State<VrCastSurface> createState() => _VrCastSurfaceState();
}

class _VrCastSurfaceState extends State<VrCastSurface>
    with WidgetsBindingObserver {
  final GlobalKey _key = GlobalKey();
  VrCastSourceHandle? _handle;
  bool _foreground = true;
  bool _holdingConsentTransition = false;
  bool _consentResolved = false;
  bool _syncing = false;
  Timer? _consentDeadline;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.host.realtime?.addListener(_onConsentChanged);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  void _sync() {
    if (_syncing) return;
    _syncing = true;
    try {
      _syncSource();
    } finally {
      _syncing = false;
    }
  }

  void _onConsentChanged() {
    if (mounted && _handle != null) _sync();
  }

  void _clearConsentTransition() {
    _holdingConsentTransition = false;
    _consentResolved = false;
    _consentDeadline?.cancel();
    _consentDeadline = null;
  }

  void _expireConsentTransition() {
    _clearConsentTransition();
    final handle = _handle;
    _handle = null;
    if (handle != null) widget.host.unregisterSource(handle);
  }

  void _syncSource() {
    // ReplayKit may temporarily make this current route inactive while its
    // system consent alert is visible. Retain only an EXISTING lease for that
    // handshake. A private route, disposal or real background always revokes
    // the stream before its frames can be offered to a viewer.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final currentRoute = ModalRoute.isCurrentOf(context) ?? true;
    final canRetainConsent =
        _handle != null &&
        currentRoute &&
        (lifecycle == AppLifecycleState.inactive ||
            lifecycle == AppLifecycleState.resumed);
    if (!canRetainConsent) {
      _clearConsentTransition();
    } else {
      if (!_holdingConsentTransition &&
          lifecycle == AppLifecycleState.inactive &&
          widget.host.isAwaitingScreenCaptureConsent) {
        _holdingConsentTransition = true;
        // Native permission admission is bounded at 45s. Keep this local
        // transition bounded too if no lifecycle callback ever follows it.
        _consentDeadline = Timer(
          const Duration(seconds: 48),
          _expireConsentTransition,
        );
      }
      if (_holdingConsentTransition &&
          !_consentResolved &&
          !widget.host.isAwaitingScreenCaptureConsent) {
        _consentResolved = true;
        _consentDeadline?.cancel();
        _consentDeadline = Timer(
          const Duration(seconds: 2),
          _expireConsentTransition,
        );
      }
      if (_holdingConsentTransition &&
          lifecycle == AppLifecycleState.resumed &&
          _foreground &&
          widget.enabled) {
        _clearConsentTransition();
      }
    }
    // Resolving getDisplayMedia can precede Flutter's resumed notification.
    // Retain the same lease through that short handoff, even if the enclosing
    // experience rebuilt inactive; never admit a fresh source in that state.
    final consentTransition = canRetainConsent && _holdingConsentTransition;
    if ((widget.enabled && _foreground && currentRoute) || consentTransition) {
      _handle ??= widget.host.registerSource(
        _capture,
        realtimeStereo: widget.realtimeStereo,
      );
    } else if (_handle case final handle?) {
      _handle = null;
      widget.host.unregisterSource(handle);
    }
  }

  @override
  void didUpdateWidget(VrCastSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host != widget.host ||
        oldWidget.eye != widget.eye ||
        oldWidget.realtimeStereo != widget.realtimeStereo) {
      oldWidget.host.realtime?.removeListener(_onConsentChanged);
      _clearConsentTransition();
      if (_handle != null) oldWidget.host.unregisterSource(_handle!);
      _handle = null;
      widget.host.realtime?.addListener(_onConsentChanged);
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  Future<Uint8List?> _capture() async {
    if (!mounted || !_foreground || !widget.enabled) return null;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_foreground || !widget.enabled) return null;
    final boundary = _key.currentContext?.findRenderObject();
    if (boundary is! VrRenderCastBoundary ||
        !boundary.hasSize ||
        boundary.size.isEmpty) {
      return null;
    }
    final bounds = vrCastEyeBounds(boundary.size, widget.eye);
    // Both dimensions are bounded even on unusual portrait/desktop surfaces.
    final ratio = math.min(
      widget.host.frameWidth / bounds.width,
      640 / bounds.height,
    );
    // OffsetLayer is the same public layer used by boundary.toImage, but its
    // bounds let us avoid allocating/readback of the other eye.
    final image = await boundary.capture(bounds, pixelRatio: ratio);
    try {
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null || !mounted || !_foreground || !widget.enabled) {
        return null;
      }
      return await compute(_encodeJpeg, (
        rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
        image.width,
        image.height,
        widget.host.jpegQuality,
      ));
    } finally {
      image.dispose();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.host.realtime?.removeListener(_onConsentChanged);
    _clearConsentTransition();
    if (_handle != null) widget.host.unregisterSource(_handle!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      VrCastBoundary(key: _key, child: widget.child);
}

Uint8List _encodeJpeg((Uint8List, int, int, int) data) {
  final image = img.Image.fromBytes(
    width: data.$2,
    height: data.$3,
    bytes: data.$1.buffer,
    bytesOffset: data.$1.offsetInBytes,
    numChannels: 4,
  );
  return img.encodeJpg(image, quality: data.$4);
}
