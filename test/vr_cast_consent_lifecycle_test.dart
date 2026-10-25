import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/vrlizate_cast.dart';

class _Consent extends VrCastRealtimeHost {
  bool awaiting = false;
  @override
  bool get isAwaitingConsent => awaiting;
  @override
  void setSource({required bool active, bool stereo = true}) {}

  void resolve(bool pending) {
    awaiting = pending;
    notifyListeners();
  }
}

class _Host extends VrCastHost {
  _Host(_Consent consent) : super(realtime: consent);
  int registrations = 0;
  int revocations = 0;
  VrCastSourceHandle? lease;
  @override
  VrCastSourceHandle registerSource(
    VrCastFrameProvider provider, {
    bool realtimeStereo = true,
  }) {
    registrations++;
    return lease = super.registerSource(
      provider,
      realtimeStereo: realtimeStereo,
    );
  }

  @override
  void unregisterSource(VrCastSourceHandle handle) {
    revocations++;
    lease = null;
    super.unregisterSource(handle);
  }
}

void main() {
  Future<(_Consent, _Host, ValueNotifier<bool>, GlobalKey<NavigatorState>)>
  mount(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final consent = _Consent();
    final host = _Host(consent);
    final active = ValueNotifier(true);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (_, value, _) => VrCastSurface(
            host: host,
            enabled: value,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    addTearDown(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      host.dispose();
      active.dispose();
    });
    return (consent, host, active, navigator);
  }

  testWidgets(
    'resolved consent stays on the same lease through inactive rebuild',
    (tester) async {
      final (consent, host, active, _) = await mount(tester);
      final originalLease = host.lease;
      consent.resolve(true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      active.value = false;
      await tester.pump();
      consent.resolve(false);
      await tester.pump();
      expect(host.lease, same(originalLease));
      expect(host.revocations, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(host.lease, same(originalLease));
      expect(host.registrations, 1);
      expect(host.revocations, 0);
    },
  );

  for (final state in [AppLifecycleState.paused, AppLifecycleState.hidden]) {
    testWidgets('$state revokes even when capture consent is pending', (
      tester,
    ) async {
      final (consent, host, _, _) = await mount(tester);
      consent.resolve(true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(state);
      expect(host.revocations, 1);
      expect(host.lease, isNull);
    });
  }

  testWidgets('a private route revokes a retained consent lease', (
    tester,
  ) async {
    final (consent, host, _, navigator) = await mount(tester);
    consent.resolve(true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const SizedBox.expand()),
      ),
    );
    await tester.pumpAndSettle();
    expect(host.revocations, 1);
    expect(host.lease, isNull);
  });

  testWidgets(
    'disposing a retained consent surface revokes and cancels timers',
    (tester) async {
      final (consent, host, _, _) = await mount(tester);
      consent.resolve(true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(host.revocations, 1);
      consent.resolve(false);
      await tester.pump(const Duration(seconds: 49));
      expect(host.revocations, 1);
    },
  );

  testWidgets('resolved permission without resumed expires after two seconds', (
    tester,
  ) async {
    final (consent, host, _, _) = await mount(tester);
    consent.resolve(true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    consent.resolve(false);
    await tester.pump(const Duration(seconds: 2));
    expect(host.revocations, 1);
    expect(host.lease, isNull);
  });

  testWidgets('pending permission without resumed has a local hard deadline', (
    tester,
  ) async {
    final (consent, host, _, _) = await mount(tester);
    consent.resolve(true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 48));
    expect(host.revocations, 1);
    expect(host.lease, isNull);
  });
}
