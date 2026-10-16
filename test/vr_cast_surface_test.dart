import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vrlizate_cast/vrlizate_cast.dart';

class CaptureHost extends VrCastHost {
  VrCastFrameProvider? capture;
  @override
  VrCastSourceHandle registerSource(VrCastFrameProvider provider) {
    capture = provider;
    return super.registerSource(provider);
  }
}

void main() {
  test('eye bounds preserve monocular aspect and never stretch to stereo', () {
    const size = Size(800, 360);
    expect(
      vrCastEyeBounds(size, VrCastEye.left),
      const Rect.fromLTWH(0, 0, 400, 360),
    );
    expect(
      vrCastEyeBounds(size, VrCastEye.right),
      const Rect.fromLTWH(400, 0, 400, 360),
    );
  });

  testWidgets('real composed layer capture encodes only the left eye', (
    tester,
  ) async {
    final host = CaptureHost();
    await tester.binding.setSurfaceSize(const Size(800, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: VrCastSurface(
          host: host,
          child: const Row(
            children: [
              Expanded(
                child: ColoredBox(color: Colors.red, child: SizedBox.expand()),
              ),
              Expanded(
                child: ColoredBox(color: Colors.blue, child: SizedBox.expand()),
              ),
            ],
          ),
        ),
      ),
    );
    late Future<Uint8List?> pending;
    await tester.runAsync(() async {
      pending = host.capture!();
    });
    await tester.pump();
    final bytes = await tester.runAsync(() => pending);
    expect(bytes, isNotNull);
    final decoded = img.decodeJpg(bytes!)!;
    expect(decoded.width, 360);
    expect(decoded.height, 324);
    final pixel = decoded.getPixel(180, 162);
    expect(pixel.r, greaterThan(220));
    expect(pixel.b, lessThan(80));
    await tester.pumpWidget(const SizedBox.shrink());
    host.dispose();
  });
}
