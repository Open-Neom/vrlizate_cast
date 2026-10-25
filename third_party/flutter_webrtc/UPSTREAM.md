# VRlizate foreground ReplayKit capture patch

Vendored from the published `flutter_webrtc` **1.6.2+hotfix.3** package in
`pub.dev`, on 2026-10-24. Upstream project:
<https://github.com/flutter-webrtc/flutter-webrtc>.

The package's `LICENSE` and `NOTICE` are retained unchanged. Its package version
is unchanged, so dependent modules do not need an artificial version upgrade.
`UPSTREAM_CHECKSUMS.json` contains SHA-256 hashes for every upstream package file
before this patch. Resolve the root Flutter application's `flutter_webrtc`
dependency to this directory using a path override; do not patch `.pub-cache`.

The upstream archive SHA-256 recorded by pub is
`c1d3674f61b14cbe98b60f0cce396835b1483163e644b8cd26fd3fdd55360fb9`.

## Scope

The upstream iOS foreground capturer fixes output to half the source dimensions
and 8 FPS, ignores requested screen-video constraints, and resolves
`getDisplayMedia` before ReplayKit's permission callback. This patch addresses
that foreground in-app path. Android capture, broadcast extensions, codecs,
audio, and the WebRTC SDK version remain upstream implementations.

`getDisplayMedia({'audio': false, 'video': {'width': 1280, 'height': 720,
'frameRate': 24}})` now requests 24 FPS, bounded to 1–30 FPS. Numeric constraints
and `max`/`ideal`/`exact`/`min` maps are accepted. Values are safety ceilings,
not promises to satisfy exact browser constraints. Output preserves the screen
aspect ratio, never upscales, uses even dimensions, and fits within a long side
of 1280 and a short side of 720. A 4:3 iPad therefore produces fewer than
1280×720 pixels; it is not stretched into 16:9.

Admission uses capture timestamps before constructing WebRTC frames. Missed
frames are dropped, not queued. A deadline-based cadence avoids rounding every
24 FPS interval to three 60 Hz samples, which would unintentionally yield
20 FPS. Source adaptation changes only when dimensions change.

ReplayKit consent remains under iOS control. The Dart stream becomes available
only after the asynchronous native start succeeds. Failure, cancellation, and
a 45-second unresolved permission request return a sanitized
`SCREEN_CAPTURE_FAILED` error with a numeric native code. No private native
error description or screen content is logged.

## Cancellation and privacy lifecycle

`Helper.cancelPendingDisplayMedia()` is an explicit no-op on web and platforms
other than iOS. On iOS it closes frame admission on the process-wide foreground
ReplayKit operation, covering both an unresolved prompt and an already active
capture. An active capture awaits ReplayKit's real stop callback.

When permission is unresolved, cancellation completes the outstanding
`getDisplayMedia` with an error and acknowledges the closed frame gate. It
cannot dismiss Apple's prompt. The old operation retains ownership until that
callback drains; a late acceptance is immediately stopped without admitting a
frame. Another start returns busy during this interval, preventing an old stop
callback from terminating a newer capture. The same draining rule applies to
the permission timeout. Normal stop callbacks complete after native stop.

Applications must still stop peers and dispose tracks/streams, invalidate their
own in-flight Future generations, and cancel before presenting private routes.
ReplayKit captures the full composition of the foreground app, including both
stereo eyes, camera passthrough, and other visible app UI. This patch does not
crop to a single eye or grant permission to capture unrelated app routes.

## Modified files

- `lib/src/helper.dart`: explicit cancellable foreground iOS capture helper.
- `FlutterRPScreenRecorder.{h,m}`: constraints, frame admission, consent,
  cancellation, singleton ownership, and asynchronous stop.
- `FlutterRTCDesktopCapturer.{h,m}`: publish streams after consent, cleanup on
  failure, cancellation bridge, and safe device-ID type checking.
- `FlutterWebRTCPlugin.m`: method-channel dispatch for cancellation.

Native changes are identical in `common/darwin/Classes` and the iOS sources
under `ios/flutter_webrtc/Sources/flutter_webrtc`, including public headers.
The iOS CocoaPods source layout uses the latter; patching only `common` would
not affect an iOS build. macOS source copies are intentionally unchanged.

## Verification

2026-10-24: the three changed implementation files `FlutterRPScreenRecorder.m`,
`FlutterRTCDesktopCapturer.m`, and `FlutterWebRTCPlugin.m` passed
`clang -fsyntax-only -fobjc-arc`
targeting arm64 iOS 15 using the installed Flutter profile and WebRTC-SDK
150.7871.01 framework headers, with no diagnostics (Clang modules enabled for
the plugin's upstream `@import` declarations). This checks Objective-C
syntax and API availability, not permission lifecycle on a real device.

Actual FPS, codec acceleration, latency, thermal behavior, rejection/retry,
and cancellation during consent require physical device validation. A 24 FPS
constraint is an objective, not a measured performance result.
