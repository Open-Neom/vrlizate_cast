import 'dart:typed_data';

/// Abstract HTTP frame client for fetching VRlizate cast frames.
abstract class VrCastFrameClient {
  Future<Uint8List> read(Uri uri);
  void close();
}
