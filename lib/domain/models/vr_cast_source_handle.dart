import 'dart:typed_data';

typedef VrCastFrameProvider = Future<Uint8List?> Function();

/// An opaque source lease. An old route cannot unregister its replacement.
class VrCastSourceHandle {
  VrCastSourceHandle();
}
