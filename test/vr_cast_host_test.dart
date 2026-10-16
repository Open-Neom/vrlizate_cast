import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/vrlizate_cast.dart';
import 'package:vrlizate_cast/src/vr_cast_transport.dart';

class MemoryTransport implements VrCastServerTransport {
  late Future<VrCastResponse> Function(VrCastRequest) handle;
  bool closed = false;
  @override
  Future<List<String>> localAddresses() async => ['192.168.1.5'];
  @override
  Future<int> start(
    int port,
    Future<VrCastResponse> Function(VrCastRequest) handler,
  ) async {
    handle = handler;
    return 12345;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final jpeg = Uint8List.fromList([255, 216, 255, 217]);

void main() {
  late MemoryTransport transport;
  late VrCastHost host;
  setUp(() {
    transport = MemoryTransport();
    host = VrCastHost(createTransport: () => transport);
  });
  tearDown(() => host.dispose());
  Future<VrCastResponse> frame([Uri? uri]) => transport.handle(
    VrCastRequest(
      'GET',
      uri ?? host.preferredViewerUri!.replace(path: '/frame.jpg'),
    ),
  );

  test(
    'idle server, browser page and unauthorized requests never capture',
    () async {
      var calls = 0;
      host.registerSource(() async {
        calls++;
        return jpeg;
      });
      await host.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 0);
      expect((await frame(Uri.parse('/frame.jpg'))).status, 403);
      expect(
        (await transport.handle(
          VrCastRequest('GET', host.preferredViewerUri!),
        )).status,
        200,
      );
      expect(calls, 0);
      expect((await frame()).bytes, jpeg);
      expect(calls, 1);
      expect(host.stats.deliveredFrames, 1);
    },
  );

  test(
    'concurrent requests share one capture and refuse excessive waiters',
    () async {
      var calls = 0;
      final pending = Completer<Uint8List?>();
      host.registerSource(() {
        calls++;
        return pending.future;
      });
      await host.start();
      final requests = [frame(), frame(), frame()];
      expect((await frame()).status, 429);
      expect(calls, 1);
      pending.complete(jpeg);
      expect((await Future.wait(requests)).map((r) => r.status), [
        200,
        200,
        200,
      ]);
      await frame();
      expect(calls, 1, reason: 'Cached frame is reused within the FPS limit.');
    },
  );

  test(
    'source replacement discards stale capture; old lease cannot detach new',
    () async {
      final pending = Completer<Uint8List?>();
      final old = host.registerSource(() => pending.future);
      await host.start();
      final waiting = frame();
      final current = host.registerSource(() async => jpeg);
      host.unregisterSource(old);
      pending.complete(jpeg);
      expect((await waiting).status, 503);
      expect((await frame()).status, 200);
      host.unregisterSource(current);
      expect((await frame()).status, 503);
    },
  );

  test(
    'stopping revokes token, discards pending frame and rotates on restart',
    () async {
      final pending = Completer<Uint8List?>();
      host.registerSource(() => pending.future);
      await host.start();
      final oldUri = host.preferredViewerUri!.replace(path: '/frame.jpg');
      final waiting = frame();
      await host.stop();
      pending.complete(jpeg);
      expect((await waiting).status, 503);
      expect(host.preferredViewerUri, isNull);
      expect(transport.closed, isTrue);
      await host.start();
      expect((await frame(oldUri)).status, 403);
      expect(host.preferredViewerUri!.query, isNot(oldUri.query));
    },
  );

  test(
    'capture timeout never opens a second capture while GPU is pending',
    () async {
      host.dispose();
      host = VrCastHost(
        captureTimeout: const Duration(milliseconds: 5),
        createTransport: () => transport,
      );
      final pending = Completer<Uint8List?>();
      var calls = 0;
      host.registerSource(() {
        calls++;
        return pending.future;
      });
      await host.start();
      expect((await frame()).status, 503);
      expect((await frame()).status, 503);
      expect(calls, 1);
      pending.complete(jpeg);
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'oversized/failed capture cannot leave a previous image visible',
    () async {
      host.registerSource(() async => jpeg);
      await host.start();
      expect((await frame()).status, 200);
      host.registerSource(() async => Uint8List(vrCastMaxFrameBytes + 1));
      expect((await frame()).status, 503);
      host.registerSource(() async => throw StateError('Render unavailable'));
      expect((await frame()).status, 503);
      expect(host.stats.captureErrors, 1);
    },
  );

  test(
    'bounded local URI rejects public destinations, redirects and secrets in userInfo',
    () {
      final token = 'ab' * 32;
      expect(
        VrCastSession.tryParse('http://192.168.100.14:1234/?token=$token'),
        isNotNull,
      );
      for (final uri in [
        'http://example.com:1234/?token=$token',
        'https://192.168.1.1:1234/?token=$token',
        'http://user:secret@192.168.1.1:1234/?token=$token',
        'http://192.168.1.1:1234/?token=$token&token=$token',
        'http://192.168.1.1:1234/?token=$token#fragment',
        'http://192.168.1.1:1234/?token=short',
        'http://192.168.1.1:1234/other?token=$token',
      ]) {
        expect(VrCastSession.tryParse(uri), isNull, reason: uri);
      }
    },
  );
}
