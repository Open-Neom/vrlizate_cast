import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/domain/models/vr_cast_request.dart';
import 'package:vrlizate_cast/domain/models/vr_cast_response.dart';
import 'package:vrlizate_cast/domain/models/vr_cast_session.dart';
import 'package:vrlizate_cast/domain/services/vr_cast_io_server_transport.dart';
import 'package:vrlizate_cast/domain/services/vr_cast_signaling_client.dart';
import 'package:vrlizate_cast/utils/constants/vr_cast_signaling_constants.dart';

void main() {
  final token = 'ab' * 32;
  final sessionId = 'cd' * 16;
  late VrCastIoServerTransport server;
  late VrCastSignalingClient client;

  setUp(() {
    server = VrCastIoServerTransport();
    client = createVrCastSignalingClient();
  });
  tearDown(() async {
    client.close();
    await server.close();
  });

  VrCastSession session(int port) =>
      VrCastSession.tryParse('http://127.0.0.1:$port/?token=$token&pin=1234')!;

  test(
    'complete SDP and session operations preserve token/PIN and methods',
    () async {
      final requests = <VrCastRequest>[];
      final payloads = <Map<String, dynamic>>[];
      final port = await server.start(0, (request) async {
        requests.add(request);
        expect(request.contentType, 'application/json');
        final first = request.readBody();
        expect(identical(first, request.readBody()), isTrue);
        final bytes = await first;
        payloads.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
        if (request.uri.path == VrCastSignalingConstants.offerPath) {
          return VrCastResponse(
            200,
            contentType: 'application/json',
            bytes: Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'type': 'answer',
                  'sdp': 'v=0\r\n',
                  'sessionId': sessionId,
                }),
              ),
            ),
          );
        }
        return const VrCastResponse(204);
      });
      final viewer = session(port);
      final answer = await client.exchange(viewer, {
        'type': 'offer',
        'sdp': 'v=0\r\n',
        'requestId': sessionId,
      });
      expect(answer['sessionId'], sessionId);
      await client.keepAlive(viewer, sessionId);
      await client.release(viewer, sessionId);
      expect(requests.map((r) => r.method), ['POST', 'POST', 'DELETE']);
      expect(requests.map((r) => r.uri.path), [
        '/rtc/offer',
        '/rtc/session',
        '/rtc/session',
      ]);
      for (final request in requests) {
        expect(request.uri.queryParameters, {'token': token, 'pin': '1234'});
      }
      expect(payloads[0], {
        'type': 'offer',
        'sdp': 'v=0\r\n',
        'requestId': sessionId,
      });
      expect(payloads[1], {'sessionId': sessionId});
    },
  );

  test('unauthorized incomplete body is rejected without reading it', () async {
    var reads = 0;
    final port = await server.start(0, (request) async {
      if (request.uri.queryParameters['token'] != token) {
        return const VrCastResponse(403);
      }
      reads++;
      await request.readBody();
      return const VrCastResponse(204);
    });
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    try {
      socket.write(
        'POST /rtc/offer?token=wrong HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\nContent-Length: 50000\r\n\r\nx',
      );
      await socket.flush();
      final reply = await socket.first.timeout(const Duration(seconds: 1));
      expect(ascii.decode(reply), startsWith('HTTP/1.1 403'));
      expect(reads, 0);
    } finally {
      socket.destroy();
    }
  });

  test('oversized declared bodies are rejected before payload arrives', () async {
    final port = await server.start(0, (request) async {
      await request.readBody();
      return const VrCastResponse(204);
    });
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    try {
      socket.write(
        'POST /rtc/offer HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Content-Length: ${VrCastSignalingConstants.maxBodyBytes + 1}\r\n\r\nx',
      );
      await socket.flush();
      final reply = await socket.first.timeout(const Duration(seconds: 1));
      expect(ascii.decode(reply), startsWith('HTTP/1.1 413'));
    } finally {
      socket.destroy();
    }
  });

  test('chunked bodies cannot bypass the byte limit', () async {
    final port = await server.start(0, (request) async {
      await request.readBody();
      return const VrCastResponse(204);
    });
    final http = HttpClient();
    try {
      final request = await http.postUrl(
        Uri.parse('http://127.0.0.1:$port/rtc/offer'),
      );
      request.add(Uint8List(VrCastSignalingConstants.maxBodyBytes + 1));
      final response = await request.close();
      expect(response.statusCode, 413);
      await response.drain<void>();
    } finally {
      http.close(force: true);
    }
  });

  test(
    'slow authenticated bodies time out and release their reader slot',
    () async {
      final port = await server.start(0, (request) async {
        await request.readBody();
        return const VrCastResponse(204);
      });
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      try {
        socket.write(
          'POST /rtc/offer HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          'Content-Length: 10\r\n\r\nx',
        );
        await socket.flush();
        final reply = await socket.first.timeout(const Duration(seconds: 5));
        expect(ascii.decode(reply), startsWith('HTTP/1.1 408'));
      } finally {
        socket.destroy();
      }
    },
  );

  test(
    'redirects are refused and diagnostics contain no credentials',
    () async {
      final port = await server.start(0, (request) async {
        await request.readBody();
        return const VrCastResponse(
          302,
          headers: {'location': 'http://example.com/'},
        );
      });
      try {
        await client.exchange(session(port), {
          'type': 'offer',
          'sdp': 'v=0\r\n',
          'requestId': sessionId,
        });
        fail('Redirect must not be followed.');
      } on VrCastSignalingException catch (error) {
        expect(error.statusCode, 302);
        expect(error.toString(), isNot(contains(token)));
        expect(error.toString(), isNot(contains('1234')));
        expect(error.toString(), isNot(contains('example.com')));
      }
    },
  );

  test('oversized responses are refused before JSON parsing', () async {
    final port = await server.start(0, (request) async {
      await request.readBody();
      return VrCastResponse(
        200,
        contentType: 'application/json',
        bytes: Uint8List(VrCastSignalingConstants.maxBodyBytes + 1),
      );
    });
    await expectLater(
      client.exchange(session(port), {
        'type': 'offer',
        'sdp': 'v=0\r\n',
        'requestId': sessionId,
      }),
      throwsA(
        isA<VrCastSignalingException>().having(
          (error) => error.code,
          'code',
          'response-too-large',
        ),
      ),
    );
  });

  test(
    'oversized SDP and invalid session IDs never reach the server',
    () async {
      var requests = 0;
      final port = await server.start(0, (request) async {
        requests++;
        return const VrCastResponse(204);
      });
      await expectLater(
        client.exchange(session(port), {
          'type': 'offer',
          'sdp': 'a' * (VrCastSignalingConstants.maxSdpBytes + 1),
          'requestId': sessionId,
        }),
        throwsA(isA<VrCastSignalingException>()),
      );
      await expectLater(
        client.keepAlive(session(port), '../bad'),
        throwsA(isA<VrCastSignalingException>()),
      );
      expect(requests, 0);
    },
  );

  test(
    'initial absent source retries once a second with the same request id',
    () async {
      final offers = <Map<String, dynamic>>[];
      final clock = Stopwatch()..start();
      final port = await server.start(0, (request) async {
        offers.add(
          jsonDecode(utf8.decode(await request.readBody()))
              as Map<String, dynamic>,
        );
        if (offers.length == 1) {
          return const VrCastResponse(
            503,
            headers: {'X-VRlizate-Video-State': 'source-unavailable'},
          );
        }
        return VrCastResponse(
          200,
          contentType: 'application/json',
          bytes: Uint8List.fromList(
            utf8.encode(jsonEncode({'sessionId': sessionId})),
          ),
        );
      });
      final answer = await client.exchange(session(port), {
        'type': 'offer',
        'sdp': 'v=0\r\n',
        'requestId': sessionId,
      });
      expect(answer['sessionId'], sessionId);
      expect(offers.length, 2);
      expect(offers.last, offers.first);
      expect(clock.elapsed, greaterThanOrEqualTo(const Duration(seconds: 1)));
    },
  );

  test(
    'permission rejection and other errors never automatically retry',
    () async {
      var requests = 0;
      var status = 503;
      String? state;
      final port = await server.start(0, (request) async {
        requests++;
        await request.readBody();
        return VrCastResponse(
          status,
        headers: {if (state != null) 'X-VRlizate-Video-State': state},
        );
      });
      for (final item in <(int, String?)>[
        (503, null),
        (503, 'permission-denied'),
        (503, 'SOURCE-unavailable'),
        (403, 'source-unavailable'),
        (409, 'source-unavailable'),
      ]) {
        (status, state) = item;
        await expectLater(
          client.exchange(session(port), {
            'type': 'offer',
            'sdp': 'v=0\r\n',
            'requestId': sessionId,
          }),
          throwsA(isA<VrCastSignalingException>()),
        );
      }
      expect(requests, 5);
    },
  );

  test(
    'DELETE is independent during the source wait and close cancels it',
    () async {
      final firstOffer = Completer<void>();
      var offers = 0;
      String? releasedId;
      final port = await server.start(0, (request) async {
        final body =
            jsonDecode(utf8.decode(await request.readBody()))
                as Map<String, dynamic>;
        if (request.method == 'DELETE') {
          releasedId = body['sessionId'] as String;
          return const VrCastResponse(204);
        }
        offers++;
        if (!firstOffer.isCompleted) firstOffer.complete();
        return const VrCastResponse(
          503,
          headers: {'X-VRlizate-Video-State': 'source-unavailable'},
        );
      });
      final viewer = session(port);
      final exchange = client.exchange(viewer, {
        'type': 'offer',
        'sdp': 'v=0\r\n',
        'requestId': sessionId,
      });
      final stopped = expectLater(
        exchange,
        throwsA(
          isA<VrCastSignalingException>().having(
            (error) => error.code,
            'code',
            'closed',
          ),
        ),
      );
      await firstOffer.future;
      await client
          .release(viewer, sessionId)
          .timeout(const Duration(seconds: 1));
      final clock = Stopwatch()..start();
      client.close();
      await stopped.timeout(const Duration(milliseconds: 500));
      expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(releasedId, sessionId);
      expect(offers, 1);
    },
  );

  test('initial source recovery stops after fifteen seconds', () async {
    var offers = 0;
    final port = await server.start(0, (request) async {
      offers++;
      await request.readBody();
      return const VrCastResponse(
        503,
        headers: {'X-VRlizate-Video-State': 'source-unavailable'},
      );
    });
    final clock = Stopwatch()..start();
    await expectLater(
      client.exchange(session(port), {
        'type': 'offer',
        'sdp': 'v=0\r\n',
        'requestId': sessionId,
      }),
      throwsA(
        isA<VrCastSignalingException>().having(
          (error) => error.code,
          'code',
          'source-unavailable',
        ),
      ),
    );
    expect(
      clock.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 14900)),
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 18)));
    expect(offers, inInclusiveRange(2, 15));
  });
}
