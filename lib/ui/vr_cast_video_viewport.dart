import 'package:flutter/widgets.dart';

/// Displays one eye of a full stereo capture without stretching the picture.
class VrCastVideoViewport extends StatelessWidget {
  const VrCastVideoViewport({
    super.key,
    required this.videoAspectRatio,
    required this.stereo,
    required this.child,
  });

  final double videoAspectRatio;
  final bool stereo;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final aspect = videoAspectRatio.isFinite && videoAspectRatio > 0
        ? videoAspectRatio
        : 1.0;
    return Center(
      child: AspectRatio(
        aspectRatio: stereo ? aspect / 2 : aspect,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            maxWidth: double.infinity,
            child: AspectRatio(aspectRatio: aspect, child: child),
          ),
        ),
      ),
    );
  }
}
