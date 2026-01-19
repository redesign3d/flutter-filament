import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:filament_widget/filament_widget.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

const String kAssetGlbPath = 'assets/models/DamagedHelmet.glb';
const String kAssetGltfPath = 'assets/models/BoomBox/BoomBox.gltf';
const String kRemoteGlbUrl =
    'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/FlightHelmet/glTF-Binary/FlightHelmet.glb';
const String kIblAssetPath = 'assets/envs/filament_env_ibl.ktx';
const String kSkyboxAssetPath = 'assets/envs/filament_env_skybox.ktx';

class ModelLoaderState extends Equatable {
  const ModelLoaderState({
    required this.isLoading,
    required this.status,
    required this.errorMessage,
    required this.cacheSizeBytes,
    required this.lastLoadFromCache,
    required this.modelLoaded,
  });

  const ModelLoaderState.initial()
    : isLoading = false,
      status = 'Ready.',
      errorMessage = null,
      cacheSizeBytes = 0,
      lastLoadFromCache = false,
      modelLoaded = false;

  final bool isLoading;
  final String status;
  final String? errorMessage;
  final int cacheSizeBytes;
  final bool lastLoadFromCache;
  final bool modelLoaded;

  ModelLoaderState copyWith({
    bool? isLoading,
    String? status,
    String? errorMessage,
    int? cacheSizeBytes,
    bool? lastLoadFromCache,
    bool? modelLoaded,
  }) {
    return ModelLoaderState(
      isLoading: isLoading ?? this.isLoading,
      status: status ?? this.status,
      errorMessage: errorMessage,
      cacheSizeBytes: cacheSizeBytes ?? this.cacheSizeBytes,
      lastLoadFromCache: lastLoadFromCache ?? this.lastLoadFromCache,
      modelLoaded: modelLoaded ?? this.modelLoaded,
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
  ];
}

class ModelLoaderCubit extends Cubit<ModelLoaderState> {
  ModelLoaderCubit(this._controller) : super(const ModelLoaderState.initial()) {
    unawaited(refreshCacheSize());
  }

  final FilamentController _controller;

  Future<void> loadAssetGlb() async {
    await _loadModel(
      label: 'DamagedHelmet (GLB asset)',
      load: () => _controller.loadModelFromAsset(kAssetGlbPath),
    );
  }

  Future<void> loadAssetGltf() async {
    await _loadModel(
      label: 'BoomBox (glTF asset)',
      load: () => _controller.loadModelFromAsset(kAssetGltfPath),
    );
  }

  Future<void> loadRemoteGlb() async {
    final cacheSize = await _controller.getCacheSizeBytes();
    final cached = cacheSize > 0;
    await _loadModel(
      label:
          cached
              ? 'FlightHelmet (URL cache hit)'
              : 'FlightHelmet (URL download + cache)',
      load: () => _controller.loadModelFromUrl(kRemoteGlbUrl),
      lastLoadFromCache: cached,
    );
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
    required String label,
    required Future<void> Function() load,
    bool lastLoadFromCache = false,
  }) async {
    emit(state.copyWith(isLoading: true, status: 'Loading $label...'));
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
    await _controller.setIBLFromAsset(kIblAssetPath);
    await _controller.setSkyboxFromAsset(kSkyboxAssetPath);
  }

  Future<void> _applyViewDefaults() async {
    await _controller.setOrbitConstraints(
      minPitchDeg: -80,
      maxPitchDeg: 80,
      minYawDeg: -180,
      maxYawDeg: 180,
    );
    await _controller.setInertiaEnabled(true);
    await _controller.setInertiaParams(damping: 0.9, sensitivity: 0.2);
    await _controller.setZoomLimits(minDistance: 0.3, maxDistance: 10.0);
  }

  Future<void> _ensureViewerReady() async {
    if (_controller.textureId != null) {
      return;
    }
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_controller.textureId != null) {
        return;
      }
    }
  }
}
