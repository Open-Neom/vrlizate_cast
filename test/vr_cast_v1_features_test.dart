import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/src/vr_cast_transport.dart';
import 'package:vrlizate_cast/vrlizate_cast.dart';

class _FakeServerTransport implements VrCastServerTransport {
  late Future<VrCastResponse> Function(VrCastRequest) handle;
  @override
  Future<List<String>> localAddresses() async => ['192.168.1.9'];
  @override
  Future<int> start(
    int port,
    Future<VrCastResponse> Function(VrCastRequest) handler,
  ) async {
    handle = handler;
    return 14567;
  }

  @override
  Future<void> close() async {}
}

final _sampleJpeg = Uint8List.fromList([255, 216, 255, 217]);

void main() {
  group('VrCastQualityPreset', () {
    test('presets configure expected width, fps, and jpegQuality', () {
      final low = VrCastHost(qualityPreset: VrCastQualityPreset.lowLatency);
      expect(low.frameWidth, 280);
      expect(low.framesPerSecond, 5);
      expect(low.jpegQuality, 55);
      low.dispose();

      final balanced = VrCastHost(qualityPreset: VrCastQualityPreset.balanced);
      expect(balanced.frameWidth, 360);
      expect(balanced.framesPerSecond, 3);
      expect(balanced.jpegQuality, 65);
      balanced.dispose();

      final hd = VrCastHost(qualityPreset: VrCastQualityPreset.highDefinition);
      expect(hd.frameWidth, 540);
      expect(hd.framesPerSecond, 4);
      expect(hd.jpegQuality, 80);
      hd.dispose();
    });
  });

  group('VrCastAccessPolicy', () {
    test('validates 4-digit PIN and maxViewers bounds', () {
      final policy = VrCastAccessPolicy(pinCode: '4821', maxViewers: 2);
      expect(policy.requiresPin, isTrue);
      expect(policy.verifyPin('4821'), isTrue);
      expect(policy.verifyPin('0000'), isFalse);
      expect(policy.verifyPin(null), isFalse);
      expect(policy.canAcceptViewer(0), isTrue);
      expect(policy.canAcceptViewer(1), isTrue);
      expect(policy.canAcceptViewer(2), isFalse);

      for (final invalidPin in ['', '123', '12345', 'abcd']) {
        expect(
          () => VrCastAccessPolicy(pinCode: invalidPin),
          throwsArgumentError,
        );
      }
      for (final invalidViewers in [0, -1, 17]) {
        expect(
          () => VrCastAccessPolicy(maxViewers: invalidViewers),
          throwsArgumentError,
        );
      }
    });

    test('host enforces PIN protection and maxViewers limit', () async {
      final transport = _FakeServerTransport();
      final host = VrCastHost(
        accessPolicy: VrCastAccessPolicy(pinCode: '7391', maxViewers: 2),
        createTransport: () => transport,
      );
      addTearDown(host.dispose);

      final pending = Completer<Uint8List?>();
      host.registerSource(() => pending.future);
      await host.start();

      final uriWithPin = host.preferredViewerUri!;
      expect(uriWithPin.queryParameters['pin'], '7391');
      final session = VrCastSession.tryParse(uriWithPin.toString());
      expect(session, isNotNull);
      expect(session!.pinCode, '7391');

      final uriWrongPin = uriWithPin.replace(
        queryParameters: {
          'token': uriWithPin.queryParameters['token']!,
          'pin': '0000',
        },
      );
      expect(
        (await transport.handle(VrCastRequest('GET', uriWrongPin))).status,
        403,
      );

      final frameUri = session.frameUri;
      final req1 = transport.handle(VrCastRequest('GET', frameUri));
      final req2 = transport.handle(VrCastRequest('GET', frameUri));
      final req3 = await transport.handle(VrCastRequest('GET', frameUri));
      expect(req3.status, 429);

      pending.complete(_sampleJpeg);
      final responses = await Future.wait([req1, req2]);
      expect(responses.map((r) => r.status), [200, 200]);
    });
  });

  group('VrCastTelemetrySnapshot', () {
    test('tracks framesSent, bytesSent, estimatedFps, and activeViewers', () async {
      final transport = _FakeServerTransport();
      final host = VrCastHost(createTransport: () => transport);
      addTearDown(host.dispose);

      host.registerSource(() async => _sampleJpeg);
      await host.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final frameUri = host.preferredViewerUri!.replace(path: '/frame.jpg');
      final res = await transport.handle(VrCastRequest('GET', frameUri));
      expect(res.status, 200);

      final telemetry = host.telemetry;
      expect(telemetry.framesSent, 1);
      expect(telemetry.bytesSent, _sampleJpeg.length);
      expect(telemetry.estimatedFps, greaterThan(0.0));
      expect(telemetry.activeViewers, 0);
      expect(telemetry.toJson()['framesSent'], 1);
      expect(telemetry.toJson()['bytesSent'], _sampleJpeg.length);
    });
  });
}
