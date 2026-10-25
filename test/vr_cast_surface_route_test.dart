import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/vrlizate_cast.dart';

class _SourceHost extends VrCastHost {
  int registrations = 0;
  int revocations = 0;

  @override
  VrCastSourceHandle registerSource(
    VrCastFrameProvider provider, {
    bool realtimeStereo = true,
  }) {
    registrations++;
    return super.registerSource(provider, realtimeStereo: realtimeStereo);
  }

  @override
  void unregisterSource(VrCastSourceHandle handle) {
    revocations++;
    super.unregisterSource(handle);
  }
}

void main() {
  testWidgets('a standalone surface revokes while another route covers it', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final host = _SourceHost();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: VrCastSurface(host: host, child: const SizedBox.expand()),
      ),
    );
    expect(host.registrations, 1);
    expect(host.revocations, 0);
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Private pairing page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(host.revocations, 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(host.registrations, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    host.dispose();
  });
}
