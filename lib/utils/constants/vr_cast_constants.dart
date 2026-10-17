abstract final class VrCastConstants {
  static const int maxFrameBytes = 256 * 1024;
  static const int maxUriLength = 1200;
  static const int maxSessionUriLength = 1024;
  static const int minFrameWidth = 160;
  static const int maxFrameWidth = 640;
  static const int minFramesPerSecond = 1;
  static const int maxFramesPerSecond = 5;
  static const int minViewers = 1;
  static const int maxViewersLimit = 16;
  static const int defaultMaxViewers = 3;
  static const int defaultJpegQuality = 65;

  static const String httpScheme = 'http';
  static const String methodGet = 'GET';
  static const String rootPath = '/';
  static const String statsPath = '/stats';
  static const String framePath = '/frame.jpg';

  static const String queryToken = 'token';
  static const String queryPin = 'pin';

  static const String tokenHexPattern = r'^[a-f0-9]{64}$';
  static const String pinCodePattern = r'^\d{4}$';
  static const String ignoredInterfacePattern =
      r'^(lo|utun|tun|tap|ppp|rmnet|pdp_ip|ipsec|wg)';
  static const String ipv4Separator = '.';
  static const String emptyString = '';
  static const String zeroPadChar = '0';

  static const String contentTypeHtml = 'text/html; charset=utf-8';
  static const String contentTypeJson = 'application/json';
  static const String contentTypeJpeg = 'image/jpeg';

  static const String headerCacheControlValue = 'no-store';
  static const String headerContentTypeOptions = 'X-Content-Type-Options';
  static const String headerNoSniff = 'nosniff';
  static const String headerReferrerPolicy = 'Referrer-Policy';
  static const String headerNoReferrer = 'no-referrer';
  static const String headerContentSecurityPolicy = 'Content-Security-Policy';
  static const String headerContentSecurityPolicyValue =
      "default-src 'none'; img-src 'self' blob:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'";
  static const String headerFrameSequence = 'X-VRlizate-Frame';
  static const String headerFpsLimit = 'X-VRlizate-Fps-Limit';

  static const String protocolVersion = 'vrlizate-preview-1';
  static const String keyProtocol = 'protocol';
  static const String keyWidth = 'width';
  static const String keyFpsLimit = 'fpsLimit';
  static const String keySourceActive = 'sourceActive';
  static const String keyCaptures = 'captures';
  static const String keyDelivered = 'delivered';
  static const String keyBytes = 'bytes';
  static const String keyDropped = 'dropped';
  static const String keyErrors = 'errors';
  static const String keyCaptureMs = 'captureMs';
  static const String keyFramesSent = 'framesSent';
  static const String keyBytesSent = 'bytesSent';
  static const String keyEstimatedFps = 'estimatedFps';
  static const String keyActiveViewers = 'activeViewers';
  static const String keyDroppedFrames = 'droppedFrames';
  static const String keyCaptureErrors = 'captureErrors';
  static const String keyLastCaptureMs = 'lastCaptureMs';

  static const String errCastDisposed = 'Cast has been disposed.';
  static const String errNoLanInterface = 'No LAN interface.';
  static const String errInvalidDimensions = 'Invalid dimensions';
  static const String errCastStoppedStartup = 'Cast stopped during startup.';
  static const String errNoFrameAvailable =
      'The visor has no frame available.';
  static const String errFrameExceedsByteLimit =
      'Preview frame exceeds its byte limit.';
  static const String errPreviewTimedOut = 'Preview timed out.';
  static const String errLanHostingNativeOnly =
      'LAN hosting requires a native app.';
  static const String errOpenSpectatorInBrowser =
      'Open the spectator URL in a browser.';
  static const String errInvalidPinCode =
      'PIN code must be exactly 4 numeric digits.';
  static const String errInvalidMaxViewers =
      'maxViewers must be between 1 and 16.';

  static const String receiverHtml =
      '''<!doctype html><html lang="es"><meta charset="utf-8">
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
}

const int vrCastMaxFrameBytes = VrCastConstants.maxFrameBytes;
