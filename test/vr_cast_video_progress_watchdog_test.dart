import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/domain/models/vr_cast_video_progress_watchdog.dart';

void main() {
  test(
    'an unchanged positive counter stalls after eight monotonic seconds',
    () {
      final watchdog = VrCastVideoProgressWatchdog();
      expect(watchdog.observe(20, Duration.zero), isFalse);
      expect(watchdog.observe(20, const Duration(seconds: 2)), isFalse);
      expect(watchdog.observe(20, const Duration(seconds: 7)), isFalse);
      expect(watchdog.observe(20, const Duration(seconds: 8)), isTrue);
    },
  );

  test('real decoded progress restarts the stall window', () {
    final watchdog = VrCastVideoProgressWatchdog();
    watchdog.observe(20, Duration.zero);
    expect(watchdog.observe(21, const Duration(seconds: 6)), isFalse);
    expect(watchdog.observe(21, const Duration(seconds: 8)), isFalse);
    expect(watchdog.observe(21, const Duration(seconds: 14)), isTrue);
  });

  test('counter resets and clock resets establish a fresh baseline', () {
    final watchdog = VrCastVideoProgressWatchdog();
    watchdog.observe(200, const Duration(seconds: 10));
    expect(watchdog.observe(3, const Duration(seconds: 16)), isFalse);
    expect(watchdog.observe(3, const Duration(seconds: 23)), isFalse);
    expect(watchdog.observe(3, const Duration(seconds: 1)), isFalse);
    expect(watchdog.observe(3, const Duration(seconds: 8)), isFalse);
    expect(watchdog.observe(3, const Duration(seconds: 9)), isTrue);
  });

  test('missing stats do not accrue time against a future valid sample', () {
    final watchdog = VrCastVideoProgressWatchdog();
    watchdog.observe(20, Duration.zero);
    watchdog.observationUnavailable();
    expect(watchdog.observe(20, const Duration(seconds: 100)), isFalse);
    expect(watchdog.observe(20, const Duration(seconds: 107)), isFalse);
    expect(watchdog.observe(20, const Duration(seconds: 108)), isTrue);
  });

  test('unknown, zero or invalid counters cannot declare stalled video', () {
    for (final value in <Object?>[
      null,
      '20',
      0,
      -1,
      1.5,
      double.nan,
      double.infinity,
      (1 << 53) + 1,
    ]) {
      final watchdog = VrCastVideoProgressWatchdog();
      watchdog.observe(20, Duration.zero);
      expect(watchdog.observe(value, const Duration(seconds: 10)), isFalse);
      expect(watchdog.observe(20, const Duration(seconds: 100)), isFalse);
    }
  });
}
