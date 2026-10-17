import 'dart:typed_data';

import '../../utils/constants/vr_cast_constants.dart';
import 'vr_cast_frame_client.dart';

/// Stub implementation of [VrCastFrameClient] for non-`dart:io` platforms.
class VrCastUnsupportedFrameClient implements VrCastFrameClient {
  @override
  Future<Uint8List> read(Uri uri) async =>
      throw UnsupportedError(VrCastConstants.errOpenSpectatorInBrowser);

  @override
  void close() {}
}
