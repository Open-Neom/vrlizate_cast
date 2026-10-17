import '../domain/services/vr_cast_frame_client.dart';
import '../domain/services/vr_cast_server_transport.dart';
import '../domain/services/vr_cast_unsupported_frame_client.dart';
import '../domain/services/vr_cast_unsupported_server_transport.dart';

export '../domain/services/vr_cast_unsupported_frame_client.dart';
export '../domain/services/vr_cast_unsupported_server_transport.dart';

VrCastServerTransport createServer() => VrCastUnsupportedServerTransport();
VrCastFrameClient createClient() => VrCastUnsupportedFrameClient();
