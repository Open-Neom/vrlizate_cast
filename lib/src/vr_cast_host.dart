import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'vr_cast_models.dart';
import 'vr_cast_transport.dart';

/// Demand-driven, bounded LAN preview. This protocol sends JPEG images, not
/// continuous audiovisual WebRTC. No frame producer runs without requests.
class VrCastHost extends ChangeNotifier {
  VrCastHost({
    this.frameWidth = 360,
    this.framesPerSecond = 3,
    this.captureTimeout = const Duration(seconds: 2),
    this.sessionLifetime = const Duration(hours: 1),
    @visibleForTesting VrCastServerTransport Function()? createTransport,
  }) : assert(frameWidth >= 160 && frameWidth <= 640),
       assert(framesPerSecond >= 1 && framesPerSecond <= 5),
       _createTransport = createTransport ?? createVrCastServerTransport;

  final int frameWidth, framesPerSecond;
  final Duration captureTimeout, sessionLifetime;
  final VrCastServerTransport Function() _createTransport;
  final _clock = Stopwatch()..start();
  VrCastServerTransport? _server;
  VrCastSourceHandle? _source;
  VrCastFrameProvider? _provider;
  Future<void>? _starting;
  Future<void>? _capture;
  Timer? _expiry;
  String? _token, _error;
  var _uris = <Uri>[];
  bool _running = false, _disposed = false;
  int _session = 0, _sourceRevision = 0, _requests = 0;
  int _lastAttemptUs = -10000000;
  Uint8List? _frame;
  int _captureCount = 0, _delivered = 0, _bytes = 0, _dropped = 0, _errors = 0;
  int _sequence = 0;
  Duration _lastDuration = Duration.zero;
  DateTime? _lastAt;

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
    if (_disposed) return Future.error(StateError('Cast has been disposed.'));
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
      if (addresses.isEmpty) throw StateError('No LAN interface.');
      if (_disposed || generation != _session) return;
      final random = Random.secure();
      final token = List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      _token = token;
      final boundPort = await server.start(port, _handle);
      if (_disposed || generation != _session) return;
      _uris = [
        for (final ip in addresses)
          Uri(
            scheme: 'http',
            host: ip,
            port: boundPort,
            path: '/',
            queryParameters: {'token': token},
          ),
      ];
      _running = true;
      _expiry = Timer(sessionLifetime, () => unawaited(stop()));
      notifyListeners();
    } catch (_) {
      if (!_disposed && generation == _session) {
        _token = null;
        _error =
            'Conecta el visor a una red Wi-Fi y vuelve a activar la vista.';
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
    final candidates = query['token'];
    if (!_running ||
        _token == null ||
        query.length != 1 ||
        candidates?.length != 1) {
      return false;
    }
    final candidate = candidates!.single;
    if (candidate.length != _token!.length) return false;
    var difference = 0;
    for (var i = 0; i < candidate.length; i++) {
      difference |= candidate.codeUnitAt(i) ^ _token!.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<VrCastResponse> _handle(VrCastRequest request) async {
    if (request.uri.toString().length > 1200 || !_authorized(request.uri)) {
      return const VrCastResponse(403);
    }
    if (request.method != 'GET') return const VrCastResponse(405);
    if (request.uri.path == '/') {
      return VrCastResponse(
        200,
        bytes: Uint8List.fromList(utf8.encode(_receiverHtml)),
        contentType: 'text/html; charset=utf-8',
        headers: {
          'Content-Security-Policy':
              "default-src 'none'; img-src 'self' blob:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'",
        },
      );
    }
    if (request.uri.path == '/stats') {
      return VrCastResponse(
        200,
        bytes: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'protocol': 'vrlizate-preview-1',
              'width': frameWidth,
              'fpsLimit': framesPerSecond,
              'sourceActive': _provider != null,
              'captures': _captureCount,
              'delivered': _delivered,
              'bytes': _bytes,
              'dropped': _dropped,
              'errors': _errors,
              'captureMs': _lastDuration.inMicroseconds / 1000,
            }),
          ),
        ),
        contentType: 'application/json',
      );
    }
    if (request.uri.path != '/frame.jpg') return const VrCastResponse(404);
    // Small fan-out is deliberate; conferences should use a relay later.
    if (_requests >= 3) return const VrCastResponse(429);
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
        contentType: 'image/jpeg',
        headers: {
          'X-VRlizate-Frame': '$_sequence',
          'X-VRlizate-Fps-Limit': '$framesPerSecond',
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
          bytes.length > vrCastMaxFrameBytes ||
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

const _receiverHtml = '''<!doctype html><html lang="es"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>VRlizate · Vista del visor</title>
<style>body{margin:0;background:#060b16;color:#edf5ff;font:16px system-ui;display:grid;place-items:center;height:100dvh}main{width:100%;height:100%;display:flex;flex-direction:column}header{padding:10px 18px;display:flex;gap:16px;align-items:center}button{background:#16475a;color:white;border:1px solid #37cadf;padding:9px;border-radius:9px}section{flex:1;min-height:0;display:grid;place-items:center}img{width:100%;height:100%;object-fit:contain;min-height:0}small{color:#9eb9cb}#status{padding:8px 18px}body:fullscreen header{display:none}</style>
<main><header><strong>VRlizate</strong><small>Vista previa · Sin audio</small><button id="full">Pantalla completa</button></header><section><img id="view" alt="Esperando la vista del visor"></section><div id="status">Conectando…</div></main>
<script>
const view=document.getElementById('view'),status=document.getElementById('status');
const target='/frame.jpg'+location.search;let blobUrl=null,paused=false;
document.getElementById('full').onclick=()=>document.body.requestFullscreen?.();
document.addEventListener('visibilitychange',()=>{paused=document.hidden;if(paused){view.removeAttribute('src');if(blobUrl)URL.revokeObjectURL(blobUrl);blobUrl=null;}});
async function next(){const start=performance.now();if(!paused){const abort=new AbortController(),timeout=setTimeout(()=>abort.abort(),2500);try{const result=await fetch(target,{cache:'no-store',signal:abort.signal});if(!result.ok)throw Error();const blob=await result.blob();if(blob.size>262144||blob.type!=='image/jpeg')throw Error();if(!paused){const old=blobUrl;blobUrl=URL.createObjectURL(blob);view.src=blobUrl;if(old)URL.revokeObjectURL(old);status.textContent='Vista del visor · Wi-Fi · Sin audio';}}catch(e){view.removeAttribute('src');status.textContent='Vista pausada o visor sin conexión. Comprueba la misma red Wi-Fi.';}finally{clearTimeout(timeout);}}setTimeout(next,Math.max(333-(performance.now()-start),50));}next();
</script></html>''';
