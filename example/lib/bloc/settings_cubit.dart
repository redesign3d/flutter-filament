import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:filament_widget/filament_widget.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class SettingsState extends Equatable {
  const SettingsState({
    required this.shadowsEnabled,
    required this.msaaSamples,
    required this.wireframeEnabled,
    required this.boundingBoxesEnabled,
    required this.debugLoggingEnabled,
    required this.fpsOverlayEnabled,
  });

  const SettingsState.initial()
      : shadowsEnabled = true,
        msaaSamples = 2,
        wireframeEnabled = false,
        boundingBoxesEnabled = false,
        debugLoggingEnabled = false,
        fpsOverlayEnabled = false;

  final bool shadowsEnabled;
  final int msaaSamples;
  final bool wireframeEnabled;
  final bool boundingBoxesEnabled;
  final bool debugLoggingEnabled;
  final bool fpsOverlayEnabled;

  SettingsState copyWith({
    bool? shadowsEnabled,
    int? msaaSamples,
    bool? wireframeEnabled,
    bool? boundingBoxesEnabled,
    bool? debugLoggingEnabled,
    bool? fpsOverlayEnabled,
  }) {
    return SettingsState(
      shadowsEnabled: shadowsEnabled ?? this.shadowsEnabled,
      msaaSamples: msaaSamples ?? this.msaaSamples,
      wireframeEnabled: wireframeEnabled ?? this.wireframeEnabled,
      boundingBoxesEnabled: boundingBoxesEnabled ?? this.boundingBoxesEnabled,
      debugLoggingEnabled: debugLoggingEnabled ?? this.debugLoggingEnabled,
      fpsOverlayEnabled: fpsOverlayEnabled ?? this.fpsOverlayEnabled,
    );
  }

  @override
  List<Object> get props => [
        shadowsEnabled,
        msaaSamples,
        wireframeEnabled,
        boundingBoxesEnabled,
        debugLoggingEnabled,
        fpsOverlayEnabled,
      ];
}

class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit(this._controller) : super(const SettingsState.initial()) {
    unawaited(_applyDefaults());
  }

  final FilamentController _controller;

  Future<void> setShadowsEnabled(bool enabled) async {
    emit(state.copyWith(shadowsEnabled: enabled));
    await _controller.setShadowsEnabled(enabled);
  }

  Future<void> setMsaaSamples(int samples) async {
    final normalized = samples == 4 || samples == 2 ? samples : 1;
    emit(state.copyWith(msaaSamples: normalized));
    await _controller.setMsaa(normalized);
  }

  Future<void> setWireframeEnabled(bool enabled) async {
    emit(state.copyWith(wireframeEnabled: enabled));
    await _controller.setWireframeEnabled(enabled);
  }

  Future<void> setBoundingBoxesEnabled(bool enabled) async {
    emit(state.copyWith(boundingBoxesEnabled: enabled));
    await _controller.setBoundingBoxesEnabled(enabled);
  }

  Future<void> setDebugLoggingEnabled(bool enabled) async {
    emit(state.copyWith(debugLoggingEnabled: enabled));
    await _controller.setDebugLoggingEnabled(enabled);
  }

  void setFpsOverlayEnabled(bool enabled) {
    emit(state.copyWith(fpsOverlayEnabled: enabled));
  }

  Future<void> _applyDefaults() async {
    await _controller.setMsaa(state.msaaSamples);
    await _controller.setDynamicResolutionEnabled(true);
    await _controller.setToneMappingFilmic();
    await _controller.setShadowsEnabled(state.shadowsEnabled);
    await _controller.setWireframeEnabled(state.wireframeEnabled);
    await _controller.setBoundingBoxesEnabled(state.boundingBoxesEnabled);
    await _controller.setDebugLoggingEnabled(state.debugLoggingEnabled);
  }
}
