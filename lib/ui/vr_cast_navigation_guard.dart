import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Hides newly navigated app UI until native display capture acknowledges its
/// suspension. The previous spectator frame may remain visible, but no frame
/// of the new route is revealed while capture can still be running.
class VrCastNavigationGuard extends NavigatorObserver {
  VrCastNavigationGuard({
    required this.hasVideoSession,
    required this.suspendCapture,
    this.onError,
  });

  final bool Function() hasVideoSession;
  final Future<void> Function() suspendCapture;

  /// Receives bounded diagnostic codes, never native exceptions or route data.
  final ValueChanged<String>? onError;

  final ValueNotifier<bool> _obscured = ValueNotifier(false);
  int _generation = 0;
  bool _disposed = false;
  String? _lastFailure;

  ValueListenable<bool> get obscured => _obscured;
  String? get lastFailure => _lastFailure;

  void _beforeRouteFrame() {
    if (_disposed) return;
    bool videoSession;
    try {
      videoSession = hasVideoSession();
    } catch (_) {
      _generation++;
      _obscured.value = true;
      _fail('capture-state-unavailable');
      return;
    }
    // A second navigation must not release an earlier pending barrier just
    // because the first suspension already invalidated the host's session.
    if (!videoSession && !_obscured.value) return;
    final generation = ++_generation;
    _lastFailure = null;
    _obscured.value = true;
    Future<void> suspension;
    try {
      // Invoke immediately, not in a microtask, so admission closes before the
      // Navigator can paint the new composition behind the black curtain.
      suspension = suspendCapture();
    } catch (_) {
      _fail('capture-suspension-failed');
      return;
    }
    unawaited(_awaitAcknowledgement(suspension, generation));
  }

  Future<void> _awaitAcknowledgement(
    Future<void> suspension,
    int generation,
  ) async {
    try {
      await suspension;
      if (_disposed || generation != _generation) return;
      _obscured.value = false;
    } catch (_) {
      if (_disposed || generation != _generation) return;
      // Fail closed. A timeout or platform error is not a successful native
      // acknowledgement and must never reveal the newly presented app UI.
      _fail('capture-suspension-failed');
    }
  }

  void _fail(String code) {
    _lastFailure = code;
    try {
      onError?.call(code);
    } catch (_) {
      // Reporting must not break the privacy barrier.
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _beforeRouteFrame();
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _beforeRouteFrame();
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _beforeRouteFrame();
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _beforeRouteFrame();
    super.didRemove(route, previousRoute);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _obscured.dispose();
  }
}

/// Place above the Navigator, outside every captured immersive source.
class VrCastPrivacyCurtain extends StatelessWidget {
  const VrCastPrivacyCurtain({
    super.key,
    required this.obscured,
    required this.child,
  });

  final ValueListenable<bool> obscured;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      Positioned.fill(
        child: _CurtainVisibility(
          obscured: obscured,
          child: const BlockSemantics(
            child: AbsorbPointer(child: ColoredBox(color: Color(0xFF000000))),
          ),
        ),
      ),
    ],
  );
}

// Navigator observers may run during Navigator.build. Rebuilding an ancestor
// ValueListenableBuilder then is unsafe, and deferring until post-frame could
// expose the first private frame. Read the synchronous value at paint/hit-test
// time instead, with no widget rebuild needed to close the curtain.
class _CurtainVisibility extends SingleChildRenderObjectWidget {
  const _CurtainVisibility({required this.obscured, required super.child});

  final ValueListenable<bool> obscured;

  @override
  _RenderCurtainVisibility createRenderObject(BuildContext context) =>
      _RenderCurtainVisibility(obscured);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCurtainVisibility renderObject,
  ) => renderObject.obscured = obscured;
}

class _RenderCurtainVisibility extends RenderProxyBox {
  _RenderCurtainVisibility(this._obscured);

  ValueListenable<bool> _obscured;

  set obscured(ValueListenable<bool> value) {
    if (identical(value, _obscured)) return;
    if (attached) _obscured.removeListener(_changed);
    _obscured = value;
    if (attached) _obscured.addListener(_changed);
    _changed();
  }

  void _changed() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _obscured.addListener(_changed);
  }

  @override
  void detach() {
    _obscured.removeListener(_changed);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_obscured.value) super.paint(context, offset);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      _obscured.value && super.hitTest(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_obscured.value) super.visitChildrenForSemantics(visitor);
  }
}
