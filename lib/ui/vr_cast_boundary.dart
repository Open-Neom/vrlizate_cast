import 'package:flutter/widgets.dart';

import 'vr_render_cast_boundary.dart';

/// Repaint boundary widget backed by [VrRenderCastBoundary].
class VrCastBoundary extends SingleChildRenderObjectWidget {
  const VrCastBoundary({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      VrRenderCastBoundary();
}
