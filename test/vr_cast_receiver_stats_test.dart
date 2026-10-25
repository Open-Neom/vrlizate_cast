import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/domain/models/vr_cast_receiver_stats.dart';

void main() {
  test('decoder rates use video counters and a monotonic interval', () {
    const previous = VrCastReceiverStats(
      framesDecoded: 100,
      bytesReceived: 10000,
    );
    final stats = VrCastReceiverStats.fromInboundVideo(
      {
        'framesDecoded': 148,
        'bytesReceived': 26000,
        'frameWidth': 1280,
        'frameHeight': 720,
        'packetsLost': 3,
        'jitter': 0.004,
        'decoderImplementation': 'MediaCodec',
      },
      previous: previous,
      elapsed: const Duration(seconds: 2),
      codec: 'video/H264',
    );
    expect(stats.framesPerSecond, 24);
    expect(stats.bitsPerSecond, 64000);
    expect(stats.jitterMilliseconds, 4);
    expect(stats.width, 1280);
    expect(stats.height, 720);
    expect(stats.codec, 'video/H264');
    expect(stats.decoderImplementation, 'MediaCodec');
    expect(stats.toJson().keys, isNot(contains('sessionId')));
    expect(stats.toJson().keys, isNot(contains('sdp')));
  });

  test(
    'native reported FPS wins and counter resets never make negative rates',
    () {
      final stats = VrCastReceiverStats.fromInboundVideo(
        {'framesDecoded': 2, 'bytesReceived': 200, 'framesPerSecond': 23.5},
        previous: const VrCastReceiverStats(
          framesDecoded: 100,
          bytesReceived: 10000,
        ),
        elapsed: const Duration(seconds: 2),
      );
      expect(stats.framesPerSecond, 23.5);
      expect(stats.bitsPerSecond, 0);
    },
  );

  test('missing, nonfinite and initial samples do not invent FPS', () {
    final stats = VrCastReceiverStats.fromInboundVideo({
      'framesDecoded': 400,
      'bytesReceived': 50000,
      'framesPerSecond': double.nan,
      'jitter': double.infinity,
      'frameWidth': '1280',
    });
    expect(stats.framesPerSecond, 0);
    expect(stats.bitsPerSecond, 0);
    expect(stats.jitterMilliseconds, 0);
    expect(stats.width, 0);
  });
}
