import '../../src/vr_cast_transport_stub.dart'
    if (dart.library.io) '../../src/vr_cast_transport_io.dart'
    as platform;
import 'vr_cast_frame_client.dart';
import 'vr_cast_server_transport.dart';

VrCastServerTransport createVrCastServerTransport() => platform.createServer();
VrCastFrameClient createVrCastFrameClient() => platform.createClient();
