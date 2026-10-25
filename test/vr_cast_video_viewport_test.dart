import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/ui/vr_cast_video_viewport.dart';

void main() {
  testWidgets('stereo preview crops the left eye and keeps monocular aspect', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 300,
            height: 300,
            child: RepaintBoundary(
              key: key,
              child: const VrCastVideoViewport(
                videoAspectRatio: 2,
                stereo: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: ColoredBox(color: Color(0xFFFF0000))),
                    Expanded(child: ColoredBox(color: Color(0xFF0000FF))),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final source = tester.getSize(find.byType(Row));
    expect(source, const Size(600, 300));
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        // Even the far right edge is red: the right eye never leaks into view.
        final edge = (150 * image.width + 290) * 4;
        expect(bytes!.getUint8(edge), 255);
        expect(bytes.getUint8(edge + 2), 0);
      } finally {
        image.dispose();
      }
    });
  });
}
