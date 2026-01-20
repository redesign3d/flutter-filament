import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:filament_widget/filament_widget.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class AnimationState extends Equatable {
  const AnimationState({
    required this.animationCount,
    required this.selectedIndex,
    required this.isPlaying,
    required this.loop,
    required this.durationSeconds,
    required this.positionSeconds,
    required this.speed,
  });

  const AnimationState.initial()
      : animationCount = 0,
        selectedIndex = 0,
        isPlaying = false,
        loop = true,
        durationSeconds = 0.0,
        positionSeconds = 0.0,
        speed = 1.0;

  final int animationCount;
  final int selectedIndex;
  final bool isPlaying;
  final bool loop;
  final double durationSeconds;
  final double positionSeconds;
  final double speed;

  AnimationState copyWith({
    int? animationCount,
    int? selectedIndex,
    bool? isPlaying,
    bool? loop,
    double? durationSeconds,
    double? positionSeconds,
    double? speed,
  }) {
    return AnimationState(
      animationCount: animationCount ?? this.animationCount,
      selectedIndex: selectedIndex ?? this.selectedIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      loop: loop ?? this.loop,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      speed: speed ?? this.speed,
    );
  }

  @override
  List<Object> get props => [
        animationCount,
        selectedIndex,
        isPlaying,
        loop,
        durationSeconds,
        positionSeconds,
        speed,
      ];
}

class AnimationCubit extends Cubit<AnimationState> {
  AnimationCubit(this._controller) : super(const AnimationState.initial());

  final FilamentController _controller;
  Timer? _ticker;

  Future<void> loadAnimations() async {
    final count = await _controller.getAnimationCount();
    double duration = 0.0;
    if (count > 0) {
      duration = await _controller.getAnimationDuration(0);
    }
    _stopTicker();
    emit(
      state.copyWith(
        animationCount: count,
        selectedIndex: 0,
        durationSeconds: duration,
        positionSeconds: 0.0,
        isPlaying: false,
      ),
    );
  }

  Future<void> togglePlay() async {
    if (state.animationCount == 0) {
      return;
    }
    if (state.isPlaying) {
      await _controller.pauseAnimation();
      _stopTicker();
      emit(state.copyWith(isPlaying: false));
    } else {
      await _controller.playAnimation(state.selectedIndex, loop: state.loop);
      _startTicker();
      emit(state.copyWith(isPlaying: true));
    }
  }

  Future<void> seek(double seconds) async {
    final clamped = seconds.clamp(0.0, state.durationSeconds);
    await _controller.seekAnimation(clamped);
    emit(state.copyWith(positionSeconds: clamped));
  }

  Future<void> setSpeed(double speed) async {
    await _controller.setAnimationSpeed(speed);
    emit(state.copyWith(speed: speed));
  }

  Future<void> setLoop(bool loop) async {
    emit(state.copyWith(loop: loop));
    if (state.isPlaying) {
      await _controller.playAnimation(state.selectedIndex, loop: loop);
    }
  }

  @override
  Future<void> close() {
    _stopTicker();
    return super.close();
  }

  void _startTicker() {
    _stopTicker();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final duration = state.durationSeconds;
      if (duration <= 0.0 || !state.isPlaying) {
        return;
      }
      final delta = 0.1 * state.speed;
      var next = state.positionSeconds + delta;
      if (state.loop) {
        next %= duration;
        if (next < 0) {
          next += duration;
        }
      } else if (next >= duration) {
        next = duration;
      }
      emit(state.copyWith(positionSeconds: next));
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }
}
