/// Detects a stopped decoder from successive valid counters, never from the
/// absence of optional WebRTC statistics. The caller supplies a monotonic time.
class VrCastVideoProgressWatchdog {
  VrCastVideoProgressWatchdog({this.stallTimeout = const Duration(seconds: 8)});

  final Duration stallTimeout;
  int? _lastFrames;
  Duration? _lastObservationAt;
  Duration? _lastProgressAt;

  /// Returns true only when a positive decoded counter has remained unchanged
  /// for [stallTimeout] during an uninterrupted series of valid observations.
  /// A reset counter establishes a new baseline, as does a restarted clock.
  bool observe(Object? framesDecoded, Duration monotonicNow) {
    if (framesDecoded is! num ||
        !framesDecoded.isFinite ||
        framesDecoded <= 0 ||
        framesDecoded > 1 << 53 ||
        framesDecoded != framesDecoded.truncateToDouble() ||
        monotonicNow.isNegative) {
      observationUnavailable();
      return false;
    }
    final frames = framesDecoded.toInt();
    final previousAt = _lastObservationAt;
    if (_lastFrames == null ||
        frames != _lastFrames ||
        (previousAt != null && monotonicNow < previousAt)) {
      _lastFrames = frames;
      _lastObservationAt = monotonicNow;
      _lastProgressAt = monotonicNow;
      return false;
    }
    _lastObservationAt = monotonicNow;
    return monotonicNow - _lastProgressAt! >= stallTimeout;
  }

  /// No inference about video health can be made during a stats gap. Resume
  /// from a fresh baseline when valid counters become available again.
  void observationUnavailable() {
    _lastFrames = null;
    _lastObservationAt = null;
    _lastProgressAt = null;
  }
}
