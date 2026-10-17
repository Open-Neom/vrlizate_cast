# vrlizate_cast

Vista previa LAN opcional del SDK de VRlizate (`1.0.0`). La imagen se transmite por Wi-Fi; el mando mantiene su transporte Bluetooth y solo recibe una oferta de enlace. No se inicia el servidor Wi-Fi antiguo del joystick.

## Novedades en 1.0.0

- **`VrCastQualityPreset`**: Perfiles preconfigurados de calidad y latencia (`lowLatency`, `balanced`, `highDefinition`).
- **`VrCastAccessPolicy`**: Protección opcional mediante PIN de 4 dígitos y límite configurable de espectadores simultáneos (`maxViewers`).
- **`VrCastTelemetrySnapshot`**: Instantánea de telemetría con cuadros enviados, bytes transmitidos, FPS estimado y espectadores activos.
- **Arquitectura Open Neom**: Separación estricta de una declaración por archivo en `lib/utils/constants/`, `lib/utils/enums/`, `lib/domain/models/`, `lib/domain/services/` y `lib/ui/`.

## Uso

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
