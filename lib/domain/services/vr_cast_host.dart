import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../utils/constants/vr_cast_constants.dart';
import '../../utils/constants/vr_cast_translation_constants.dart';
import '../../utils/enums/vr_cast_quality_preset.dart';
import '../models/vr_cast_access_policy.dart';
import '../models/vr_cast_request.dart';
import '../models/vr_cast_response.dart';
import '../models/vr_cast_source_handle.dart';
import '../models/vr_cast_stats.dart';
import '../models/vr_cast_telemetry_snapshot.dart';
import 'vr_cast_server_transport.dart';
import 'vr_cast_transport_factory.dart';

/// Demand-driven, bounded LAN preview. This protocol sends JPEG images, not
/// continuous audiovisual WebRTC. No frame producer runs without requests.
class VrCastHost extends ChangeNotifier {
  VrCastHost({
    int? frameWidth,
    int? framesPerSecond,
    this.qualityPreset = VrCastQualityPreset.balanced,
    this.accessPolicy = const VrCastAccessPolicy.open(),
    this.captureTimeout = const Duration(seconds: 2),
    this.sessionLifetime = const Duration(hours: 1),
    @visibleForTesting VrCastServerTransport Function()? createTransport,
  }) : frameWidth = frameWidth ?? qualityPreset.frameWidth,
       framesPerSecond = framesPerSecond ?? qualityPreset.framesPerSecond,
       assert(
         (frameWidth ?? qualityPreset.frameWidth) >=
                 VrCastConstants.minFrameWidth &&
             (frameWidth ?? qualityPreset.frameWidth) <=
                 VrCastConstants.maxFrameWidth,
       ),
       assert(
         (framesPerSecond ?? qualityPreset.framesPerSecond) >=
                 VrCastConstants.minFramesPerSecond &&
             (framesPerSecond ?? qualityPreset.framesPerSecond) <=
                 VrCastConstants.maxFramesPerSecond,
       ),
       _createTransport = createTransport ?? createVrCastServerTransport;

  final int frameWidth;
  final int framesPerSecond;
  final VrCastQualityPreset qualityPreset;
  final VrCastAccessPolicy accessPolicy;
  final Duration captureTimeout;
  final Duration sessionLifetime;
  final VrCastServerTransport Function() _createTransport;
  final Stopwatch _clock = Stopwatch()..start();
  VrCastServerTransport? _server;
  VrCastSourceHandle? _source;
  VrCastFrameProvider? _provider;
  Future<void>? _starting;
  Future<void>? _capture;
  Timer? _expiry;
  String? _token;
  String? _error;
  List<Uri> _uris = <Uri>[];
  bool _running = false;
  bool _disposed = false;
  int _session = 0;
  int _sourceRevision = 0;
  int _requests = 0;
  int _sessionStartUs = 0;
  int _lastAttemptUs = -10000000;
  Uint8List? _frame;
  int _captureCount = 0;
  int _delivered = 0;
  int _bytes = 0;
  int _dropped = 0;
  int _errors = 0;
  int _sequence = 0;
  Duration _lastDuration = Duration.zero;
  DateTime? _lastAt;

  int get jpegQuality => qualityPreset.jpegQuality;
  bool get isRunning => _running;
  String? get error => _error;
  List<Uri> get viewerUris => List.unmodifiable(_uris);
  Uri? get preferredViewerUri =>
      _running && _uris.isNotEmpty ? _uris.first : null;

  VrCastStats get stats => VrCastStats(
    captureCount: _captureCount,
    deliveredFrames: _delivered,
    bytesSent: _bytes,
    droppedFrames: _dropped,
    captureErrors: _errors,
    lastCaptureDuration: _lastDuration,
    lastFrameAt: _lastAt,
    sequence: _sequence,
  );

  VrCastTelemetrySnapshot get telemetry => VrCastTelemetrySnapshot.fromStats(
    stats,
    elapsed: _running
        ? Duration(microseconds: _clock.elapsedMicroseconds - _sessionStartUs)
        : Duration.zero,
    activeViewers: _requests,
    fpsCap: framesPerSecond,
  );

  VrCastSourceHandle registerSource(VrCastFrameProvider provider) {
    final handle = VrCastSourceHandle();
    if (_disposed) return handle;
    _source = handle;
    _provider = provider;
    _invalidateSource();
    return handle;
  }

  void unregisterSource(VrCastSourceHandle handle) {
    if (!identical(handle, _source)) return;
    _source = null;
    _provider = null;
    _invalidateSource();
  }

  void _invalidateSource() {
    _sourceRevision++;
    _frame = null;
    _lastAt = null;
    _lastAttemptUs = -10000000;
  }

  Future<void> start({int port = 0}) {
    if (_disposed) {
      return Future.error(StateError(VrCastConstants.errCastDisposed));
    }
    if (_running) return Future.value();
    return _starting ??= _start(port).whenComplete(() => _starting = null);
  }

  Future<void> _start(int port) async {
    final generation = ++_session;
    final server = _createTransport();
    _server = server;
    _error = null;
    try {
      final addresses = await server.localAddresses();
      if (addresses.isEmpty) {
        throw StateError(VrCastConstants.errNoLanInterface);
      }
      if (_disposed || generation != _session) return;
      final random = Random.secure();
      final token = List.generate(
        32,
        (_) => random
            .nextInt(256)
            .toRadixString(16)
            .padLeft(2, VrCastConstants.zeroPadChar),
      ).join();
      _token = token;
      final boundPort = await server.start(port, _handle);
      if (_disposed || generation != _session) return;
      final queryParams = <String, String>{
        VrCastConstants.queryToken: token,
        if (accessPolicy.requiresPin)
          VrCastConstants.queryPin: accessPolicy.pinCode!,
      };
      _uris = [
        for (final ip in addresses)
          Uri(
            scheme: VrCastConstants.httpScheme,
            host: ip,
            port: boundPort,
            path: VrCastConstants.rootPath,
            queryParameters: queryParams,
          ),
      ];
      _sessionStartUs = _clock.elapsedMicroseconds;
      _running = true;
      _expiry = Timer(sessionLifetime, () => unawaited(stop()));
      notifyListeners();
    } catch (_) {
      if (!_disposed && generation == _session) {
        _token = null;
        _error = VrCastTranslationConstants.connectVisorWifiError;
        notifyListeners();
      }
      rethrow;
    } finally {
      if (!_running || _disposed || generation != _session) {
        await server.close();
        if (identical(_server, server)) _server = null;
      }
    }
  }

  Future<void> stop() async {
    _session++;
    _expiry?.cancel();
    _expiry = null;
    _running = false;
    _token = null;
    _uris = [];
    _invalidateSource();
    final server = _server;
    _server = null;
    if (!_disposed) notifyListeners();
    await server?.close();
  }

  bool _authorized(Uri uri) {
    final query = uri.queryParametersAll;
    final candidates = query[VrCastConstants.queryToken];
    if (!_running ||
        _token == null ||
        candidates == null ||
        candidates.length != 1) {
      return false;
    }
    if (accessPolicy.requiresPin) {
      final pins = query[VrCastConstants.queryPin];
      if (query.length != 2 ||
          pins == null ||
          pins.length != 1 ||
          !accessPolicy.verifyPin(pins.single)) {
        return false;
      }
    } else if (query.length != 1) {
      return false;
    }
    final candidate = candidates.single;
    if (candidate.length != _token!.length) return false;
    var difference = 0;
    for (var i = 0; i < candidate.length; i++) {
      difference |= candidate.codeUnitAt(i) ^ _token!.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<VrCastResponse> _handle(VrCastRequest request) async {
    if (request.uri.toString().length > VrCastConstants.maxUriLength ||
        !_authorized(request.uri)) {
      return const VrCastResponse(403);
    }
    if (request.method != VrCastConstants.methodGet) {
      return const VrCastResponse(405);
    }
    if (request.uri.path == VrCastConstants.rootPath) {
      return VrCastResponse(
        200,
        bytes: Uint8List.fromList(utf8.encode(VrCastConstants.receiverHtml)),
        contentType: VrCastConstants.contentTypeHtml,
        headers: const {
          VrCastConstants.headerContentSecurityPolicy:
              VrCastConstants.headerContentSecurityPolicyValue,
        },
      );
    }
    if (request.uri.path == VrCastConstants.statsPath) {
      return VrCastResponse(
        200,
        bytes: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              VrCastConstants.keyProtocol: VrCastConstants.protocolVersion,
              VrCastConstants.keyWidth: frameWidth,
              VrCastConstants.keyFpsLimit: framesPerSecond,
              VrCastConstants.keySourceActive: _provider != null,
              VrCastConstants.keyCaptures: _captureCount,
              VrCastConstants.keyDelivered: _delivered,
              VrCastConstants.keyBytes: _bytes,
              VrCastConstants.keyDropped: _dropped,
              VrCastConstants.keyErrors: _errors,
              VrCastConstants.keyCaptureMs:
                  _lastDuration.inMicroseconds / 1000,
            }),
          ),
        ),
        contentType: VrCastConstants.contentTypeJson,
      );
    }
    if (request.uri.path != VrCastConstants.framePath) {
      return const VrCastResponse(404);
    }
    // Small fan-out is deliberate; conferences should use a relay later.
    if (!accessPolicy.canAcceptViewer(_requests)) {
      return const VrCastResponse(429);
    }
    final session = _session, revision = _sourceRevision;
    _requests++;
    try {
      if (_provider == null) return const VrCastResponse(503);
      if (_capture == null &&
          _clock.elapsedMicroseconds - _lastAttemptUs >=
              1000000 ~/ framesPerSecond) {
        _capture = _captureFrame().whenComplete(() => _capture = null);
      }
      final pending = _capture;
      if (pending != null) {
        try {
          await pending.timeout(captureTimeout);
        } on TimeoutException {
          // Keep the real operation in flight: a timed-out GPU readback must
          // not spawn a second allocation before it actually completes.
          _dropped++;
          return const VrCastResponse(503);
        }
      }
      final frame = _frame;
      if (!_running ||
          session != _session ||
          revision != _sourceRevision ||
          frame == null) {
        return const VrCastResponse(503);
      }
      _delivered++;
      _bytes += frame.length;
      return VrCastResponse(
        200,
        bytes: frame,
        contentType: VrCastConstants.contentTypeJpeg,
        headers: {
          VrCastConstants.headerFrameSequence: '$_sequence',
          VrCastConstants.headerFpsLimit: '$framesPerSecond',
        },
      );
    } finally {
      _requests--;
    }
  }

  Future<void> _captureFrame() async {
    final provider = _provider;
    final revision = _sourceRevision, session = _session;
    if (provider == null) return;
    _lastAttemptUs = _clock.elapsedMicroseconds;
    final began = _lastAttemptUs;
    _captureCount++;
    try {
      final bytes = await provider();
      if (!_running || session != _session || revision != _sourceRevision) {
        _dropped++;
        return;
      }
      if (bytes == null ||
          bytes.length < 4 ||
          bytes.length > VrCastConstants.maxFrameBytes ||
          bytes[0] != 0xff ||
          bytes[1] != 0xd8) {
        _frame = null;
        _dropped++;
        return;
      }
      _frame = bytes;
      _sequence++;
      _lastAt = DateTime.now();
    } catch (_) {
      if (session == _session && revision == _sourceRevision) _frame = null;
      _errors++;
    } finally {
      _lastDuration = Duration(
        microseconds: _clock.elapsedMicroseconds - began,
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(stop());
    _provider = null;
    _source = null;
    super.dispose();
  }
}
