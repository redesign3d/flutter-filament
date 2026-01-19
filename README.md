# filament_widget

Flutter plugin that embeds Google Filament 1.68.4 for real-time, PBR-accurate rendering on
Android and iOS using the texture rendering path (no PlatformView).

## Features
- glTF 2.0 (.glb / .gltf + external buffers)
- Flutter asset and remote URL loading with deterministic caching
- Orbit camera with constraints, inertia, and zoom limits
- IBL + skybox environment lighting
- Animation playback (play/pause/seek/speed)
- Quality controls: MSAA, dynamic resolution, filmic tone mapping, shadows
- Dev tools: FPS overlay, wireframe, bounding boxes, debug logging
- Single shared Filament Engine per process

## Requirements
- Filament version: **1.68.4** (pinned)
- Android: minSdk **21**, arm64-v8a only
- iOS: minimum **14.0**

## Setup
1) Fetch Filament binaries (prebuilt only):
```
./tooling/fetch_filament_android.sh
./tooling/fetch_filament_ios.sh
```

2) Android app config (consumer):
- `minSdkVersion 21`
- ABI filter `arm64-v8a` only

3) iOS app config (consumer):
- `platform :ios, '14.0'`

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

## Troubleshooting
- Missing Filament artifacts: re-run the tooling scripts in `tooling/`.
- iOS builds on CI require `flutter build ios --debug --no-codesign`.
- Android builds require NDK 27.x (CI installs `ndk;27.0.12077973`).
