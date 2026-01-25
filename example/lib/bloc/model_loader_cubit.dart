import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:filament_widget/filament_widget.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

const String kAssetGlbPath = 'assets/models/Avocado.glb';
const String kAssetGltfPath = 'assets/models/BoomBox/BoomBox.gltf';
const String kRemoteGlbUrl =
    'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/BoxTextured/glTF-Binary/BoxTextured.glb';
const String kRemoteBoxAnimatedUrl =
    'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/BoxAnimated/glTF-Binary/BoxAnimated.glb';
const String kRemoteClearCoatCarPaintUrl =
    'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/ClearCoatCarPaint/glTF-Binary/ClearCoatCarPaint.glb';
const String kRemoteDamagedHelmetUrl =
    'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/DamagedHelmet/glTF-Binary/DamagedHelmet.glb';
const String kRemoteDirectionalLightUrl =
    'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/DirectionalLight/glTF-Binary/DirectionalLight.glb';
const String kRemoteRiggedFigureUrl =
    'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/RiggedFigure/glTF-Binary/RiggedFigure.glb';
const String kRemoteMetalRoughSpheresUrl =
    'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/MetalRoughSpheres/glTF-Binary/MetalRoughSpheres.glb';
const String kIblAssetPath = 'assets/envs/filament_env_ibl.ktx';
const String kSkyboxAssetPath = 'assets/envs/filament_env_skybox.ktx';
const String kHdriRemoteUrl =
    'https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/venice_sunset_4k.hdr';
const bool kAutoHdriSwitch =
    bool.fromEnvironment('FILAMENT_AUTO_HDRI', defaultValue: false);

const double kOrbitMinPitch = -80.0;
const double kOrbitMaxPitch = 80.0;
const double kOrbitMinYaw = -180.0;
const double kOrbitMaxYaw = 180.0;
const double kZoomMinDistance = 0.02;
const double kZoomMaxDistance = 10.0;
const double kInertiaDamping = 0.9;
const double kInertiaSensitivity = 0.2;

enum DemoModelId {
  avocadoGlb,
  boomBoxGltf,
  boxTexturedUrl,
  boxAnimatedUrl,
  clearCoatCarPaintUrl,
  damagedHelmetUrl,
  directionalLightUrl,
  riggedFigureUrl,
  metalRoughSpheresUrl,
  localFile,
}

enum EnvironmentSource {
  ktx,
  hdri,
}

class ModelLoaderState extends Equatable {
  const ModelLoaderState({
    required this.isLoading,
    required this.status,
    required this.errorMessage,
    required this.cacheSizeBytes,
    required this.lastLoadFromCache,
    required this.modelLoaded,
    required this.selectedModelId,
    required this.environmentSource,
  });

  const ModelLoaderState.initial()
      : isLoading = false,
        status = 'Ready.',
        errorMessage = null,
        cacheSizeBytes = 0,
        lastLoadFromCache = false,
        modelLoaded = false,
        selectedModelId = null,
        environmentSource = EnvironmentSource.ktx;

  final bool isLoading;
  final String status;
  final String? errorMessage;
  final int cacheSizeBytes;
  final bool lastLoadFromCache;
  final bool modelLoaded;
  final DemoModelId? selectedModelId;
  final EnvironmentSource environmentSource;

  ModelLoaderState copyWith({
    bool? isLoading,
    String? status,
    String? errorMessage,
    int? cacheSizeBytes,
    bool? lastLoadFromCache,
    bool? modelLoaded,
    DemoModelId? selectedModelId,
    EnvironmentSource? environmentSource,
  }) {
    return ModelLoaderState(
      isLoading: isLoading ?? this.isLoading,
      status: status ?? this.status,
      errorMessage: errorMessage,
      cacheSizeBytes: cacheSizeBytes ?? this.cacheSizeBytes,
      lastLoadFromCache: lastLoadFromCache ?? this.lastLoadFromCache,
      modelLoaded: modelLoaded ?? this.modelLoaded,
      selectedModelId: selectedModelId ?? this.selectedModelId,
      environmentSource: environmentSource ?? this.environmentSource,
    );
  }

  @override
  List<Object?> get props => [
        isLoading,
        status,
        errorMessage,
        cacheSizeBytes,
        lastLoadFromCache,
        modelLoaded,
        selectedModelId,
        environmentSource,
      ];
}

class ModelLoaderCubit extends Cubit<ModelLoaderState> {
  ModelLoaderCubit(this._controller) : super(const ModelLoaderState.initial()) {
    unawaited(refreshCacheSize());
    if (kAutoHdriSwitch) {
      unawaited(_autoSwitchEnvironment());
    }
  }

  final FilamentController _controller;

  Future<void> loadAssetGlb() async {
    await _loadModel(
      modelId: DemoModelId.avocadoGlb,
      label: 'Avocado (GLB asset)',
      load: () => _controller.loadModelFromAsset(kAssetGlbPath),
    );
  }

  Future<void> loadAssetGltf() async {
    await _loadModel(
      modelId: DemoModelId.boomBoxGltf,
      label: 'BoomBox (glTF asset)',
      load: () => _controller.loadModelFromAsset(kAssetGltfPath),
    );
  }

  Future<void> loadRemoteGlb() async {
    final cacheSize = await _controller.getCacheSizeBytes();
    final cached = cacheSize > 0;
    await _loadModel(
      modelId: DemoModelId.boxTexturedUrl,
      label: cached
          ? 'BoxTextured (URL cache hit)'
          : 'BoxTextured (URL download + cache)',
      load: () => _controller.loadModelFromUrl(kRemoteGlbUrl),
      lastLoadFromCache: cached,
    );
  }

  Future<void> loadRemoteBoxAnimated() async {
    await _loadModel(
      modelId: DemoModelId.boxAnimatedUrl,
      label: 'BoxAnimated (URL)',
      load: () => _controller.loadModelFromUrl(kRemoteBoxAnimatedUrl),
    );
  }

  Future<void> loadRemoteClearCoatCarPaint() async {
    await _loadModel(
      modelId: DemoModelId.clearCoatCarPaintUrl,
      label: 'ClearCoatCarPaint (URL)',
      load: () => _controller.loadModelFromUrl(kRemoteClearCoatCarPaintUrl),
    );
  }

  Future<void> loadRemoteDamagedHelmet() async {
    await _loadModel(
      modelId: DemoModelId.damagedHelmetUrl,
      label: 'DamagedHelmet (URL)',
      load: () => _controller.loadModelFromUrl(kRemoteDamagedHelmetUrl),
    );
  }

  Future<void> loadRemoteDirectionalLight() async {
    await _loadModel(
      modelId: DemoModelId.directionalLightUrl,
      label: 'DirectionalLight (URL)',
      load: () => _controller.loadModelFromUrl(kRemoteDirectionalLightUrl),
    );
  }

  Future<void> loadRemoteRiggedFigure() async {
    await _loadModel(
      modelId: DemoModelId.riggedFigureUrl,
      label: 'RiggedFigure (URL)',
      load: () => _controller.loadModelFromUrl(kRemoteRiggedFigureUrl),
    );
  }

  Future<void> loadRemoteMetalRoughSpheres() async {
    await _loadModel(
      modelId: DemoModelId.metalRoughSpheresUrl,
      label: 'MetalRoughSpheres (URL)',
      load: () => _controller.loadModelFromUrl(kRemoteMetalRoughSpheresUrl),
    );
  }

  Future<void> loadLocalFile(String filePath, {String? displayName}) async {
    final name = displayName ?? filePath.split('/').last;
    await _loadModel(
      modelId: DemoModelId.localFile,
      label: 'Local file ($name)',
      load: () => _controller.loadModelFromFile(filePath),
    );
  }

  Future<void> setEnvironmentSource(EnvironmentSource source) async {
    emit(
      state.copyWith(
        isLoading: true,
        status: source == EnvironmentSource.hdri
            ? 'Loading HDRI environment...'
            : 'Loading KTX environment...',
        errorMessage: null,
        environmentSource: source,
      ),
    );
    try {
      await _ensureViewerReady();
      await _applyEnvironment();
      emit(state.copyWith(isLoading: false, status: 'Environment updated.'));
    } catch (e) {
      emit(
        state.copyWith(
          isLoading: false,
          status: 'Environment load failed.',
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> clearCache() async {
    emit(state.copyWith(isLoading: true, status: 'Clearing cache...'));
    try {
      await _controller.clearCache();
      final cacheSize = await _controller.getCacheSizeBytes();
      emit(
        state.copyWith(
          isLoading: false,
          status: 'Cache cleared.',
          cacheSizeBytes: cacheSize,
          errorMessage: null,
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          isLoading: false,
          status: 'Cache clear failed.',
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> refreshCacheSize() async {
    final cacheSize = await _controller.getCacheSizeBytes();
    emit(state.copyWith(cacheSizeBytes: cacheSize));
  }

  Future<void> _loadModel({
    required DemoModelId modelId,
    required String label,
    required Future<void> Function() load,
    bool lastLoadFromCache = false,
  }) async {
    emit(
      state.copyWith(
        isLoading: true,
        status: 'Loading $label...',
        errorMessage: null,
        modelLoaded: false,
      ),
    );
    try {
      await _ensureViewerReady();
      await _applyEnvironment();
      await load();
      await _applyViewDefaults();
      await _controller.frameModel();
      final cacheSize = await _controller.getCacheSizeBytes();
      emit(
        state.copyWith(
          isLoading: false,
          status: 'Loaded $label',
          errorMessage: null,
          cacheSizeBytes: cacheSize,
          lastLoadFromCache: lastLoadFromCache,
          modelLoaded: true,
          selectedModelId: modelId,
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          isLoading: false,
          status: 'Load failed.',
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> _applyEnvironment() async {
    if (state.environmentSource == EnvironmentSource.hdri) {
      await _controller.setHdriFromUrl(kHdriRemoteUrl);
    } else {
      await _controller.setIBLFromAsset(kIblAssetPath);
      await _controller.setSkyboxFromAsset(kSkyboxAssetPath);
    }
  }

  Future<void> _applyViewDefaults() async {
    await _controller.setOrbitConstraints(
      minPitchDeg: kOrbitMinPitch,
      maxPitchDeg: kOrbitMaxPitch,
      minYawDeg: kOrbitMinYaw,
      maxYawDeg: kOrbitMaxYaw,
    );
    await _controller.setInertiaEnabled(true);
    await _controller.setInertiaParams(
      damping: kInertiaDamping,
      sensitivity: kInertiaSensitivity,
    );
    await _controller.setZoomLimits(
      minDistance: kZoomMinDistance,
      maxDistance: kZoomMaxDistance,
    );
  }

  Future<void> _ensureViewerReady() async {
    await _controller.onViewerReady.timeout(const Duration(seconds: 10));
  }

  Future<void> _autoSwitchEnvironment() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    await setEnvironmentSource(EnvironmentSource.hdri);
  }
}
