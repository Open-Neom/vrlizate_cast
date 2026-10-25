import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/ui/vr_cast_navigation_guard.dart';

Future<List<int>> _centerPixel(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final result = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final offset = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
      return bytes!.buffer
          .asUint8List(bytes.offsetInBytes + offset, 4)
          .toList();
    } finally {
      image.dispose();
    }
  });
  return result!;
}

PageRoute<void> _page(Widget child) => PageRouteBuilder<void>(
  transitionDuration: Duration.zero,
  reverseTransitionDuration: Duration.zero,
  pageBuilder: (_, _, _) => child,
);

void main() {
  testWidgets(
    'first new route frame stays black until native acknowledgement',
    (tester) async {
      var hasVideo = false;
      var suspensions = 0;
      var privateTaps = 0;
      final acknowledgement = Completer<void>();
      final guard = VrCastNavigationGuard(
        hasVideoSession: () => hasVideo,
        suspendCapture: () {
          suspensions++;
          hasVideo = false;
          return acknowledgement.future;
        },
      );
      addTearDown(guard.dispose);
      final navigator = GlobalKey<NavigatorState>();
      final pixels = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [guard],
          home: const ColoredBox(color: Colors.white),
          builder: (_, child) => RepaintBoundary(
            key: pixels,
            child: VrCastPrivacyCurtain(
              obscured: guard.obscured,
              child: child!,
            ),
          ),
        ),
      );
      expect(await _centerPixel(tester, pixels), [255, 255, 255, 255]);
      hasVideo = true;
      unawaited(
        navigator.currentState!.push(
          _page(
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => privateTaps++,
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      );
      // didPush closes the curtain synchronously, before pumping the new route.
      expect(guard.obscured.value, isTrue);
      expect(suspensions, 1);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(await _centerPixel(tester, pixels), [0, 0, 0, 255]);
      await tester.tapAt(const Offset(100, 100));
      expect(privateTaps, 0);
      acknowledgement.complete();
      await tester.pump();
      expect(guard.obscured.value, isFalse);
      expect(await _centerPixel(tester, pixels), [244, 67, 54, 255]);
      await tester.tapAt(const Offset(100, 100));
      expect(privateTaps, 1);
    },
  );

  testWidgets('navigation without a video session remains visible', (
    tester,
  ) async {
    var suspensions = 0;
    final guard = VrCastNavigationGuard(
      hasVideoSession: () => false,
      suspendCapture: () async => suspensions++,
    );
    addTearDown(guard.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [guard],
        home: const SizedBox.expand(),
        builder: (_, child) =>
            VrCastPrivacyCurtain(obscured: guard.obscured, child: child!),
      ),
    );
    unawaited(navigator.currentState!.push(_page(const SizedBox.expand())));
    await tester.pump();
    expect(guard.obscured.value, isFalse);
    expect(suspensions, 0);
    expect(tester.takeException(), isNull);
  });

  test('older acknowledgements cannot reveal a newer pending route', () async {
    final acknowledgements = <Completer<void>>[];
    var video = true;
    final guard = VrCastNavigationGuard(
      hasVideoSession: () => video,
      suspendCapture: () {
        video = false;
        final acknowledgement = Completer<void>();
        acknowledgements.add(acknowledgement);
        return acknowledgement.future;
      },
    );
    addTearDown(guard.dispose);
    final first = _page(const SizedBox());
    final second = _page(const SizedBox());
    guard.didPush(first, null);
    guard.didPush(second, first);
    expect(acknowledgements, hasLength(2));
    acknowledgements.first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(guard.obscured.value, isTrue);
    acknowledgements.last.complete();
    await Future<void>.delayed(Duration.zero);
    expect(guard.obscured.value, isFalse);
  });

  test(
    'failure stays obscured and reports only a bounded diagnostic',
    () async {
      final acknowledgement = Completer<void>();
      final errors = <String>[];
      final guard = VrCastNavigationGuard(
        hasVideoSession: () => true,
        suspendCapture: () => acknowledgement.future,
        onError: errors.add,
      );
      addTearDown(guard.dispose);
      guard.didReplace(newRoute: _page(const SizedBox()));
      acknowledgement.completeError(StateError('private-native-error-content'));
      await Future<void>.delayed(Duration.zero);
      expect(guard.obscured.value, isTrue);
      expect(guard.lastFailure, 'capture-suspension-failed');
      expect(errors, ['capture-suspension-failed']);
    },
  );

  test(
    'pop and remove suspend; disposed callbacks cannot change the curtain',
    () async {
      final acknowledgements = <Completer<void>>[];
      final guard = VrCastNavigationGuard(
        hasVideoSession: () => true,
        suspendCapture: () {
          final acknowledgement = Completer<void>();
          acknowledgements.add(acknowledgement);
          return acknowledgement.future;
        },
      );
      final first = _page(const SizedBox());
      final second = _page(const SizedBox());
      guard.didPop(second, first);
      guard.didRemove(first, null);
      expect(acknowledgements, hasLength(2));
      expect(guard.obscured.value, isTrue);
      guard.dispose();
      for (final acknowledgement in acknowledgements) {
        acknowledgement.complete();
      }
      await Future<void>.delayed(Duration.zero);
      guard.dispose();
    },
  );
}
