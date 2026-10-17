# Changelog

## 1.0.0

- Promoted `vrlizate_cast` to stable `1.0.0` following the Open Neom modular directory structure (`lib/utils/constants/`, `lib/utils/enums/`, `lib/domain/models/`, `lib/domain/services/`, `lib/ui/`).
- Split all multi-declaration files into single-declaration files while keeping `lib/src/**` barrel re-exports for backward compatibility.
- Centralized HTML/CSS receiver templates, routes, headers, and localized strings into `VrCastConstants` and `VrCastTranslationConstants`.
- Added `VrCastQualityPreset` (`lowLatency`, `balanced`, `highDefinition`) with preset resolution, FPS, and JPEG quality configurations.
- Added `VrCastAccessPolicy` for optional 4-digit PIN protection and configurable maximum concurrent viewer limits.
- Added `VrCastTelemetrySnapshot` to track frames sent, bytes sent, estimated FPS, and active viewers.

## 0.1.0-beta.1

- Vista previa LAN de un ojo, con captura bajo demanda y límite de FPS.
- Receptores Flutter y navegador, token revocable y métricas sin reconstruir el visor por cuadro.
- Fuentes con ciclo de vida, límites de recursos y transporte separado de los controles.
