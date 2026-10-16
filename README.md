# vrlizate_cast

Vista previa LAN opcional del SDK de VRlizate. La imagen se transmite por Wi-Fi; el mando mantiene su transporte Bluetooth y solo recibe una oferta de enlace. No se inicia el servidor Wi-Fi antiguo del joystick.

## Estado beta

Implementación inicial de imágenes JPEG monoculares, bajo demanda, hasta 360 píxeles de ancho y 3 FPS por defecto. No incluye audio, WebRTC, Chromecast, Miracast ni una cámara de espectador independiente. No afirma 720p/30 FPS ni compatibilidad universal de Smart TV.

`VrCastHost` aloja un receptor HTML y cuadros autenticados. `VrCastSurface` registra exclusivamente la experiencia visible y recorta un ojo después de la composición Flutter, incluyendo la foveación. `VrCastPreview` recibe la imagen en Flutter sin inyectar controles.

## Uso

```dart
final host = VrCastHost(); // crear no abre puertos
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

La aplicación debe desactivar `enabled` en rutas cubiertas por ajustes, cuentas u otros diálogos. El widget también pausa por ciclo de vida. Solo la última fuente registrada está activa; una fuente antigua no puede eliminar a su reemplazo.

## Transporte y límites

- HTTP IPv4 local, sin cifrado: usar una red de confianza. Enlace bearer aleatorio propio, distinto del token de control, revocable al detener y renovado al reiniciar. Caduca después de una hora.
- GET `/`: receptor web. GET `/frame.jpg`: JPEG. GET `/stats`: métricas. Todas las rutas necesitan el token de sesión y devuelven `Cache-Control: no-store`.
- Una captura/codificación en vuelo y máximo tres solicitudes de cuadro simultáneas. No hay cola de imágenes. Las solicitudes dentro del intervalo comparten el cuadro reciente. Sin solicitudes no hay captura.
- Un timeout no permite lanzar otra captura antes de concluir la original. Cambiar fuente, pausar o detener invalida los cuadros en curso.
- Receptor nativo con límites de bytes, dimensiones, tiempo y frecuencia; no sigue redirecciones ni acepta URLs públicas.
- Captura de GPU y lectura RGBA en Flutter; JPEG en isolate. Tiene coste real. Primero medir un receptor y después evaluar más espectadores.
- Sesión ligada a la dirección Wi-Fi al activarla. Si cambia de red, detener y volver a activar para renovar el enlace.
- No se guardan enlaces ni imágenes en almacenamiento. Las imágenes recibidas se liberan al reemplazarse.

## Validación de dispositivos

En S25: entrar al visor y vincular el mando Bluetooth. La plataforma activa la vista Wi-Fi y anuncia la sesión al mando autenticado; el Motorola abre la vista automáticamente. Cerrar vista en el mando no desconecta Bluetooth. Proyectar muestra un enlace/QR para otros receptores de navegador. También puede iniciarse o detenerse manualmente en Compartir vista por Wi-Fi. Los dos necesitan estar en la misma LAN sin aislamiento entre clientes. Un navegador puede abrir el enlace del visor.

Comparar la experiencia con vista apagada/encendida: FPS del visor, duración de captura, edad y tamaño de cuadros, desconexión Wi-Fi conservando BLE, pausa/resume, cambio de sala y revocación del enlace. La proyección YouTube y superficies nativas requieren comprobación real por motor/dispositivo.

Para presentaciones de video continuo, el siguiente adaptador es captura nativa con recorte y codificación por hardware, WebRTC y audio por separado; el transporte JPEG actual es una prueba de vista previa.
