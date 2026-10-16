import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

import 'vr_cast_host.dart';
import 'vr_cast_models.dart';

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
  });
  final VrCastHost host;
  final Widget child;
  final bool enabled;
  final VrCastEye eye;
  @override
  State<VrCastSurface> createState() => _VrCastSurfaceState();
}

class _VrCastSurfaceState extends State<VrCastSurface>
    with WidgetsBindingObserver {
  final _key = GlobalKey();
  VrCastSourceHandle? _handle;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    if (widget.enabled && _foreground) {
      _handle ??= widget.host.registerSource(_capture);
    } else if (_handle case final handle?) {
      widget.host.unregisterSource(handle);
      _handle = null;
    }
  }

  @override
  void didUpdateWidget(VrCastSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host != widget.host || oldWidget.eye != widget.eye) {
      if (_handle != null) oldWidget.host.unregisterSource(_handle!);
      _handle = null;
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
    if (boundary is! _RenderCastBoundary ||
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
      ));
    } finally {
      image.dispose();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_handle != null) widget.host.unregisterSource(_handle!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _CastBoundary(key: _key, child: widget.child);
}

Uint8List _encodeJpeg((Uint8List, int, int) data) {
  final image = img.Image.fromBytes(
    width: data.$2,
    height: data.$3,
    bytes: data.$1.buffer,
    bytesOffset: data.$1.offsetInBytes,
    numChannels: 4,
  );
  return img.encodeJpg(image, quality: 65);
}

class _CastBoundary extends SingleChildRenderObjectWidget {
  const _CastBoundary({super.key, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCastBoundary();
}

class _RenderCastBoundary extends RenderRepaintBoundary {
  Future<ui.Image> capture(Rect bounds, {required double pixelRatio}) {
    assert(!debugNeedsPaint);
    return (layer! as OffsetLayer).toImage(bounds, pixelRatio: pixelRatio);
  }
}
