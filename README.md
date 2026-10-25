# vrlizate_cast

Vista LAN opcional del SDK de VRlizate (`1.0.0`): vista previa JPEG y vídeo WebRTC con captura iOS en fase de validación. La imagen se transmite por Wi-Fi; el mando mantiene su transporte Bluetooth y solo recibe una oferta de enlace. No se inicia el servidor Wi-Fi antiguo del joystick.

## Novedades en 1.0.0

- **`VrCastQualityPreset`**: Perfiles preconfigurados de calidad y latencia (`lowLatency`, `balanced`, `highDefinition`).
- **`VrCastAccessPolicy`**: Protección opcional mediante PIN de 4 dígitos y límite configurable de espectadores simultáneos (`maxViewers`).
- **`VrCastTelemetrySnapshot`**: Instantánea de telemetría con cuadros enviados, bytes transmitidos, FPS estimado y espectadores activos.
- **Arquitectura Open Neom**: Separación estricta de una declaración por archivo en `lib/utils/constants/`, `lib/utils/enums/`, `lib/domain/models/`, `lib/domain/services/` y `lib/ui/`.

## Uso de la vista previa JPEG

```dart
final host = VrCastHost(
  qualityPreset: VrCastQualityPreset.balanced,
  accessPolicy: VrCastAccessPolicy(pinCode: '4821', maxViewers: 4),
);
// En una acción explícita del usuario:
await host.start();
// Compartir host.preferredViewerUri con el mando autenticado o un navegador.
// En el árbol visible:
VrCastSurface(host: host, enabled: routeActive, child: immersiveExperience);
// En el receptor:
VrCastPreview(uri: session.viewerUri);
// Al detener:
await host.stop();
```

## Transporte y límites

- HTTP IPv4 local con enlace bearer aleatorio propio y PIN opcional de 4 dígitos, revocable al detener y renovado al reiniciar. Caduca después de una hora.
- GET `/`: receptor web. GET `/frame.jpg`: JPEG. GET `/stats`: métricas. Todas las rutas necesitan el token de sesión (y PIN cuando está activo) y devuelven `Cache-Control: no-store`.
- Una captura/codificación en vuelo y límite configurable de solicitudes simultáneas (`accessPolicy.maxViewers`).

## Vídeo WebRTC: iPad/iPhone visor y Android mando

La captura de vídeo de esta integración está habilitada únicamente para un visor iOS/iPadOS en primer plano. El Motorola/Android funciona como receptor y joystick; también existe un receptor iOS. Un visor Android conserva la vista previa JPEG hasta integrar la admisión nativa de MediaProjection y su servicio de captura. El navegador del enlace HTTP continúa mostrando JPEG.

El objetivo inicial es **24 FPS**, con un máximo solicitado de 1,8 Mbps. La captura mantiene la proporción de pantalla, sin ampliar, dentro de un lado largo de 1280 píxeles y uno corto de 720; un iPad puede producir dimensiones menores según su proporción. Son límites de configuración, **no mediciones de FPS sostenidos ni de latencia**. La fluidez, aceleración del códec, consumo y temperatura requieren medición física. Se prefiere H.264 cuando existe, conservando los códecs compatibles como alternativa.

El vídeo lleva la composición de la app, incluidos estéreo y passthrough visible; el receptor puede presentar un ojo sin estirar la imagen. Solo se transmite vídeo: **no incluye micrófono ni audio de la experiencia**. Los controles Bluetooth no cambian al conectar o perder el vídeo. La señalización HTTP autenticada usa la misma sesión LAN y el vídeo viaja por WebRTC entre los dispositivos; no se configuran servidores STUN/TURN ni retransmisión por Internet. Se admite un espectador WebRTC; `maxViewers` sigue regulando las solicitudes de la vista previa JPEG.

## Fork requerido en la aplicación consumidora

El paquete incluye una copia reproducible de **`flutter_webrtc 1.6.2+hotfix.3`** en [`third_party/flutter_webrtc`](third_party/flutter_webrtc/UPSTREAM.md), con `LICENSE`, `NOTICE`, procedencia y hashes originales. El parche iOS elimina el límite fijo de 8 FPS del capturador foreground de ReplayKit, interpreta límites de resolución/FPS y añade cancelación durante el consentimiento. No modifica los códecs ni la versión de WebRTC-SDK.

La aplicación Flutter que consume el SDK debe resolver **esa copia**, mediante un override en su propio `pubspec.yaml` o `pubspec_overrides.yaml`. Los overrides del paquete dependiente no se heredan. Ejemplo para una app ubicada junto al directorio `neom_modules`:

```yaml
dependency_overrides:
  flutter_webrtc:
    path: ../neom_modules/vr/vrlizate_cast/third_party/flutter_webrtc
```

Adapta la ruta a tu checkout y conserva los demás overrides que ya utilice la app. Ejecuta `flutter pub get` desde la app y actualiza sus dependencias nativas iOS con el flujo Flutter/CocoaPods habitual. No edites `.pub-cache`. El helper de cancelación y las garantías de admisión descritas aquí pertenecen al fork; resolver el paquete publicado sin este parche no proporciona esa API.

Para añadir vídeo al host:

```dart
final realtime = VrCastRealtimeHost();
final host = VrCastHost(realtime: realtime);
final navigationGuard = VrCastNavigationGuard(
  hasVideoSession: () => realtime.hasVideoSession,
  suspendCapture: realtime.suspendBeforeNavigation,
);

// En el Navigator que presenta experiencias, cuentas, pairing y diálogos:
MaterialApp(
  navigatorObservers: [navigationGuard],
  builder: (_, child) => VrCastPrivacyCurtain(
    obscured: navigationGuard.obscured,
    child: child!,
  ),
  home: experience,
);

// La experiencia registra una fuente solo mientras sea visible y esté activa.
VrCastSurface(host: host, enabled: routeActive, child: immersiveExperience);
// El mismo receptor decide entre vídeo y vista previa.
VrCastPreview(uri: session.viewerUri);
```

Al cerrar el propietario de la app, elimina el observer, libera `navigationGuard` y llama a `host.dispose()`; el host libera también su servicio realtime. Mantén una única sesión de captura foreground por proceso.

## Consentimiento, navegación y reintento

La primera conexión de vídeo puede abrir el aviso de captura de ReplayKit en el visor. Debe aceptarse allí: la vinculación Bluetooth y el permiso de cámara para passthrough no sustituyen ese consentimiento. El stream se publica solo después del éxito nativo. La solicitud de permiso tiene un plazo de 45 segundos y un resultado tardío cancelado no entrega frames. No hace falta una Broadcast Extension para esta captura de la propia app en primer plano.

La captura nativa incluye toda la UI visible de la app. Integra **ambas piezas**, `VrCastNavigationGuard` como observer y `VrCastPrivacyCurtain` por encima del Navigator: la cortina tapa el primer frame de la nueva ruta y bloquea sus controles hasta recibir el ACK nativo de suspensión. Un error no revela el contenido. La excepción para `inactive` durante el aviso del sistema conserva únicamente un lease existente en la ruta actual; un segundo plano real o una ruta no activa suspende la fuente.

El observer cubre push, pop, replace y remove del Navigator al que está conectado. Un Navigator anidado, un `OverlayEntry` o contenido privado sustituido dentro de la misma ruta requiere una barrera equivalente o suspensión explícita antes de mostrarlo. Un timeout de limpieza no debe tratarse como un ACK de privacidad. Si ReplayKit no confirma una parada activa, la cortina permanece cerrada.

Si el permiso seguía pendiente al cancelar, iOS puede conservar su diálogo hasta que el usuario responda. La puerta de frames queda cerrada y una aceptación tardía se detiene sin enviar imágenes. Un nuevo intento puede indicar captura ocupada hasta que termine esa operación nativa.

Si la fuente aún no está disponible al terminar pairing, el cliente espera y reintenta ese estado inicial durante un máximo de 15 segundos. No repite automáticamente una denegación o un fallo de captura. Ante rechazo, desconexión, falta de vídeo o plataforma no compatible, `VrCastPreview` mantiene o recupera JPEG, con el límite actual de aproximadamente 3 FPS en ese widget. **«Reintentar vídeo»** inicia otra negociación cuando el visor vuelve a estar listo. No se equipara esta vista previa a vídeo en tiempo real.
