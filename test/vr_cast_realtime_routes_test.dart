import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/domain/models/vr_cast_request.dart';
import 'package:vrlizate_cast/domain/models/vr_cast_response.dart';
import 'package:vrlizate_cast/domain/services/vr_cast_server_transport.dart';
import 'package:vrlizate_cast/utils/constants/vr_cast_signaling_constants.dart';
import 'package:vrlizate_cast/vrlizate_cast.dart';

class _Transport implements VrCastServerTransport {
  late Future<VrCastResponse> Function(VrCastRequest) handle;
  bool closed = false;

  @override
  Future<List<String>> localAddresses() async => ['192.168.1.10'];

  @override
  Future<int> start(
    int port,
    Future<VrCastResponse> Function(VrCastRequest) handler,
  ) async {
    handle = handler;
    return 12000;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _Video extends VrCastRealtimeHost {
  final offers = <Map<String, dynamic>>[];
  final releases = <String>[];
  final heartbeats = <String>[];
  final entered = Completer<void>();
  Completer<Map<String, dynamic>>? pending;
  VrCastRealtimeException? failure;
  bool active = false;

  @override
  void setSource({required bool active, bool stereo = true}) {
    this.active = active;
  }

  @override
  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer) async {
    offers.add(Map.of(offer));
    if (!entered.isCompleted) entered.complete();
    if (failure case final failure?) throw failure;
    return pending?.future ??
        Future.value(_answer(offer['requestId'] as String));
  }

  @override
  Future<void> release(String requestId) async {
    releases.add(requestId);
  }

  @override
  void keepAlive(String requestId) {
    heartbeats.add(requestId);
  }

  @override
  Future<void> stop() async {
    active = false;
  }
}

Map<String, dynamic> _answer(String id) => {
  'type': 'answer',
  'sdp': 'test-answer',
  'sessionId': id,
  'stereo': true,
  'framesPerSecond': 24,
};

void main() {
  final id = 'ab' * 16;
  final offer = {'type': 'offer', 'sdp': 'test-offer', 'requestId': id};
  late _Transport transport;
  late _Video video;
  late VrCastHost host;
  late VrCastSourceHandle source;

  Uint8List encode(Object? body) =>
      Uint8List.fromList(utf8.encode(jsonEncode(body)));

  setUp(() async {
    transport = _Transport();
    video = _Video();
    host = VrCastHost(
      accessPolicy: VrCastAccessPolicy(pinCode: '1234'),
      realtime: video,
      createTransport: () => transport,
    );
    source = host.registerSource(
      () async => Uint8List.fromList([255, 216, 255, 217]),
    );
    await host.start();
  });

  tearDown(() => host.dispose());

  Future<VrCastResponse> request({
    String path = VrCastSignalingConstants.offerPath,
    String method = 'POST',
    String? contentType = 'application/json',
    Uri? uri,
    Object? body,
    Future<Uint8List> Function()? reader,
  }) => transport.handle(
    VrCastRequest(
      method,
      uri ?? host.preferredViewerUri!.replace(path: path),
      contentType: contentType,
      readBody: reader ?? (() async => encode(body ?? offer)),
    ),
  );

  test(
    'authorization rejects missing wrong duplicated token and wrong PIN before reading',
    () async {
      var reads = 0;
      final valid = host.preferredViewerUri!.replace(path: '/rtc/offer');
      final query = valid.queryParameters;
      final invalid = [
        valid.replace(query: ''),
        valid.replace(queryParameters: {'token': '00' * 32, 'pin': '1234'}),
        valid.replace(
          queryParameters: {'token': query['token']!, 'pin': '9999'},
        ),
        valid.replace(query: '${valid.query}&token=${query['token']}'),
        valid.replace(query: '${valid.query}&extra=1'),
      ];
      for (final uri in invalid) {
        final response = await request(
          uri: uri,
          reader: () async {
            reads++;
            return encode(offer);
          },
        );
        expect(response.status, 403);
      }
      expect(reads, 0);
      expect(video.offers, isEmpty);
    },
  );

  test(
    'invalid methods and content types are rejected without body reads',
    () async {
      var reads = 0;
      Future<Uint8List> read() async {
        reads++;
        return encode(offer);
      }

      for (final method in ['GET', 'DELETE', 'PUT']) {
        expect((await request(method: method, reader: read)).status, 405);
      }
      for (final method in ['GET', 'PATCH', 'PUT']) {
        expect(
          (await request(
            path: '/rtc/session',
            method: method,
            reader: read,
          )).status,
          405,
        );
      }
      for (final contentType in [
        null,
        'text/plain',
        'application/octet-stream',
      ]) {
        expect(
          (await request(contentType: contentType, reader: read)).status,
          415,
        );
      }
      expect(reads, 0);
      expect(video.offers, isEmpty);
    },
  );

  test(
    'inactive immersive source returns retryable state without invoking native host',
    () async {
      host.unregisterSource(source);
      final response = await request();
      expect(response.status, 503);
      expect(response.headers['X-VRlizate-Video-State'], 'source-unavailable');
      expect(video.offers, isEmpty);
      expect(video.active, isFalse);
    },
  );

  test(
    'authorized offer returns JSON answer and supports heartbeat and release',
    () async {
      final response = await request();
      expect(response.status, 200);
      expect(response.contentType, 'application/json');
      expect(jsonDecode(utf8.decode(response.bytes!)), _answer(id));
      expect(video.offers.single, offer);
      expect(
        (await request(path: '/rtc/session', body: {'sessionId': id})).status,
        204,
      );
      expect(
        (await request(
          path: '/rtc/session',
          method: 'DELETE',
          body: {'sessionId': id},
        )).status,
        204,
      );
      expect(video.heartbeats, [id]);
      expect(video.releases, [id]);
    },
  );

  test(
    'malformed JSON invalid UTF8 nonobjects and oversized bodies never reach RTC',
    () async {
      for (final bytes in [
        Uint8List.fromList(utf8.encode('{broken')),
        Uint8List.fromList([0xff, 0xfe]),
        encode([]),
        encode(null),
        encode('value'),
      ]) {
        expect((await request(reader: () async => bytes)).status, 400);
      }
      expect(
        (await request(
          reader: () async =>
              Uint8List(VrCastSignalingConstants.maxBodyBytes + 1),
        )).status,
        413,
      );
      expect(video.offers, isEmpty);
    },
  );

  test('session operations require exactly one correctly shaped ID', () async {
    for (final body in [
      <String, dynamic>{},
      {'sessionId': '../invalid'},
      {'sessionId': 123},
      {'sessionId': id, 'extra': true},
    ]) {
      for (final method in ['POST', 'DELETE']) {
        expect(
          (await request(
            path: '/rtc/session',
            method: method,
            body: body,
          )).status,
          400,
        );
      }
    }
    expect(video.releases, isEmpty);
    expect(video.heartbeats, isEmpty);
  });

  test(
    'safe native failure status is returned without native payload',
    () async {
      video.failure = const VrCastRealtimeException(409, 'spectator-busy');
      final response = await request();
      expect(response.status, 409);
      expect(response.bytes, isNull);
    },
  );

  test(
    'host stop during an authenticated body read revokes admission',
    () async {
      final body = Completer<Uint8List>();
      final waiting = request(reader: () => body.future);
      await host.stop();
      body.complete(encode(offer));
      expect((await waiting).status, 403);
      expect(video.offers, isEmpty);
    },
  );

  test(
    'source removal during offer discards late answer and releases its ID',
    () async {
      video.pending = Completer<Map<String, dynamic>>();
      final waiting = request();
      await video.entered.future;
      host.unregisterSource(source);
      video.pending!.complete(_answer(id));
      final response = await waiting;
      expect(response.status, 503);
      expect(response.bytes, isNull);
      expect(video.releases, [id]);
    },
  );

  test(
    'source replacement during offer cannot publish the previous source answer',
    () async {
      video.pending = Completer<Map<String, dynamic>>();
      final waiting = request();
      await video.entered.future;
      host.registerSource(() async => Uint8List.fromList([255, 216, 255, 217]));
      video.pending!.complete(_answer(id));
      final response = await waiting;
      expect(response.status, 503);
      expect(response.bytes, isNull);
      expect(video.releases, [id]);
    },
  );

  test(
    'host stop during offer discards late answer and releases its ID',
    () async {
      video.pending = Completer<Map<String, dynamic>>();
      final waiting = request();
      await video.entered.future;
      await host.stop();
      video.pending!.complete(_answer(id));
      final response = await waiting;
      expect(response.status, 503);
      expect(response.bytes, isNull);
      expect(video.releases, [id]);
      expect(transport.closed, isTrue);
    },
  );
}
