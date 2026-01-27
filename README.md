# filament_widget

Flutter plugin that embeds Google Filament 1.68.4 for real-time, PBR-accurate rendering on
Android and iOS using the texture rendering path (no PlatformView).

## Features
- glTF 2.0 (.glb / .gltf + external buffers)
- Flutter asset and remote URL loading with deterministic caching
- Orbit camera with constraints, inertia, and zoom limits
- IBL + skybox environment lighting
- HDRI environment loading (equirectangular .hdr)
- Animation playback (play/pause/seek/speed)
- Quality controls: MSAA, dynamic resolution, filmic tone mapping, shadows
- Dev tools: FPS overlay, wireframe, bounding boxes, debug logging
- Single shared Filament Engine per process

## Requirements
- Filament version: **1.68.4** (pinned)
- Android: minSdk **21**
  - Debug: arm64-v8a + x86_64 (emulator)
  - Release: arm64-v8a only
- iOS: minimum **14.0**
  - Simulator uses x86_64 slices (Apple Silicon requires Rosetta)

## Setup
1) Verify Filament artifacts (optional for contributors):
```
./tooling/verify_vendored_filament.sh
```

2) Android app config (consumer):
- `minSdkVersion 21`
- ABI filter `arm64-v8a` only

3) iOS app config (consumer):
- `platform :ios, '14.0'`

## iOS binary acquisition
The plugin downloads a pinned Filament XCFramework automatically during `pod install`.

Environment options:
- Default: auto-download using a checksum-verified archive.
- Offline mode: `FILAMENT_WIDGET_DISABLE_BINARY_DOWNLOAD=1`
- Local override: `FILAMENT_WIDGET_LOCAL_XCFRAMEWORK=/abs/path/to/Filament.xcframework`
- Mirror URL override: `FILAMENT_WIDGET_IOS_XCFRAMEWORK_URL=https://your-mirror/Filament.xcframework.zip`

Downloads are cached under:
- macOS: `~/Library/Caches/filament_widget`
- Linux: `~/.cache/filament_widget`

## Usage
```dart
final controller = FilamentController();

@override
void dispose() {
  controller.dispose();
  super.dispose();
}

Widget build(BuildContext context) {
  return FilamentWidget(
    controller: controller,
    enableGestures: true,
    showDevToolsOverlay: true,
  );
}

Future<void> load() async {
  await controller.setIBLFromAsset('assets/envs/filament_env_ibl.ktx');
  await controller.setSkyboxFromAsset('assets/envs/filament_env_skybox.ktx');
  // Or use an HDRI (equirectangular .hdr):
  // await controller.setHdriFromUrl('https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/venice_sunset_1k.hdr');
  await controller.loadModelFromAsset('assets/models/Avocado.glb');
  await controller.frameModel();
}
```

## Caching
Remote URLs are cached after the first download:
```dart
await controller.loadModelFromUrl(url);
final size = await controller.getCacheSizeBytes();
await controller.clearCache();
```

## Example
```
cd example
flutter run
```

The example app uses BLoC for settings, model loading, and animation playback.

## Sample Assets
All sample models come from the KhronosGroup glTF Sample Models repository:
https://github.com/KhronosGroup/glTF-Sample-Models

Models used:
- `2.0/Avocado/glTF-Binary/Avocado.glb` (CC0, see model README)
- `2.0/BoomBox/glTF/BoomBox.gltf` (+ bin + textures, CC0, see model README)
- Remote URL: `2.0/BoxTextured/glTF-Binary/BoxTextured.glb`
  (CC-BY 4.0, see model README)
- HDRI: Poly Haven `venice_sunset_1k.hdr` (CC0)
  https://polyhaven.com/a/venice_sunset

## Troubleshooting
- Missing Filament artifacts: run `./tooling/verify_vendored_filament.sh` to trigger/validate the iOS download.
- iOS builds on CI require `flutter build ios --debug --no-codesign`.
- iOS simulator builds expect Filament.xcframework slices for `ios-arm64` and `ios-arm64_x86_64-simulator` (or `ios-arm64-simulator`).
- Android builds require NDK 27.x (CI installs `ndk;27.0.12077973`).

## Updating vendored Filament
To refresh the vendored artifacts (for Filament updates or rebuilds), run:
```
./tooling/fetch_filament_android.sh
./tooling/fetch_filament_ios.sh
./tooling/update_filament_manifest.sh
```
