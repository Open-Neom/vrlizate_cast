/// Quality and frame-rate presets for LAN spectator casting.
enum VrCastQualityPreset {
  lowLatency(frameWidth: 280, framesPerSecond: 5, jpegQuality: 55),
  balanced(frameWidth: 360, framesPerSecond: 3, jpegQuality: 65),
  highDefinition(frameWidth: 540, framesPerSecond: 4, jpegQuality: 80);

  const VrCastQualityPreset({
    required this.frameWidth,
    required this.framesPerSecond,
    required this.jpegQuality,
  });

  final int frameWidth;
  final int framesPerSecond;
  final int jpegQuality;
}
