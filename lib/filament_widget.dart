import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

class FilamentWidget extends StatefulWidget {
  const FilamentWidget({
    super.key,
    required this.controller,
    this.enableGestures = true,
    this.showDevToolsOverlay = false,
  });

  final FilamentController controller;
  final bool enableGestures;
  final bool showDevToolsOverlay;

  @override
  State<FilamentWidget> createState() => _FilamentWidgetState();
}

class _FilamentWidgetState extends State<FilamentWidget>
    with WidgetsBindingObserver {
  Size? _lastSize;
  double? _lastDpr;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.controller.initialize());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleUpdate();
  }

  @override
  void didUpdateWidget(covariant FilamentWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(widget.controller.initialize());
      _lastSize = null;
      _lastDpr = null;
      _scheduleUpdate();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _scheduleUpdate();
  }

  void _scheduleUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) {
        return;
      }
      _updateSize(box.size);
    });
  }

  Future<void> _updateSize(Size size) async {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final widthPx = (size.width * dpr).round();
    final heightPx = (size.height * dpr).round();
    if (widthPx <= 0 || heightPx <= 0) {
      return;
    }
    if (widget.controller.textureId == null && !_creating) {
      _creating = true;
      await widget.controller.createViewer(
        widthPx: widthPx,
        heightPx: heightPx,
        devicePixelRatio: dpr,
      );
      _creating = false;
      if (mounted) {
        setState(() {});
      }
    } else if (_lastSize != size || _lastDpr != dpr) {
      await widget.controller.resize(widthPx, heightPx, dpr);
    }
    _lastSize = size;
    _lastDpr = dpr;
  }

  @override
  Widget build(BuildContext context) {
    final textureId = widget.controller.textureId;
    Widget content;
    if (textureId == null) {
      content = const ColoredBox(color: Colors.black);
    } else {
      content = Texture(textureId: textureId);
    }

    if (widget.enableGestures) {
      content = _FilamentGestureLayer(
        controller: widget.controller,
        child: content,
      );
    }

    if (widget.showDevToolsOverlay) {
      content = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          content,
          _DevToolsOverlay(controller: widget.controller),
        ],
      );
    }

    return content;
  }
}

class _DevToolsOverlay extends StatelessWidget {
  const _DevToolsOverlay({required this.controller});

  final FilamentController controller;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(6.0),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: ValueListenableBuilder<double>(
              valueListenable: controller.fps,
              builder: (context, value, _) {
                return Text(
                  'FPS: ${value.toStringAsFixed(1)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _FilamentGestureLayer extends StatefulWidget {
  const _FilamentGestureLayer({required this.controller, required this.child});

  final FilamentController controller;
  final Widget child;

  @override
  State<_FilamentGestureLayer> createState() => _FilamentGestureLayerState();
}

class _FilamentGestureLayerState extends State<_FilamentGestureLayer> {
  Offset? _lastFocalPoint;
  double _lastScale = 1.0;
  int _lastPointerCount = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: (details) {
        _lastPointerCount = details.pointerCount;
        _lastScale = 1.0;
        _lastFocalPoint = details.focalPoint;
        widget.controller.handleZoomStart();
        if (_lastPointerCount == 1) {
          widget.controller.handleOrbitStart();
        }
      },
      onScaleUpdate: (details) {
        final pointerCount = details.pointerCount;
        if (pointerCount != _lastPointerCount) {
          _lastPointerCount = pointerCount;
          _lastScale = 1.0;
          _lastFocalPoint = details.focalPoint;
          if (pointerCount == 1) {
            widget.controller.handleOrbitStart();
          }
        }
        final scaleDelta = details.scale / _lastScale;
        _lastScale = details.scale;
        if (pointerCount <= 1) {
          final previous = _lastFocalPoint ?? details.focalPoint;
          final delta = details.focalPoint - previous;
          _lastFocalPoint = details.focalPoint;
          widget.controller.handleOrbitDelta(delta.dx, delta.dy);
        } else {
          _lastFocalPoint = details.focalPoint;
          if (scaleDelta.isFinite && scaleDelta != 1.0) {
            widget.controller.handleZoomDelta(scaleDelta);
          }
        }
      },
      onScaleEnd: (details) {
        if (_lastPointerCount == 1) {
          widget.controller.handleOrbitEnd(
            velocityX: details.velocity.pixelsPerSecond.dx,
            velocityY: details.velocity.pixelsPerSecond.dy,
          );
        }
        widget.controller.handleZoomEnd();
        _lastScale = 1.0;
        _lastPointerCount = 0;
        _lastFocalPoint = null;
      },
      child: widget.child,
    );
  }
}

enum FilamentControllerLifecycleState {
  newState,
  initialized,
  viewerReady,
  disposing,
  disposed,
}

extension FilamentControllerLifecycleStateLabel
    on FilamentControllerLifecycleState {
  String get label {
    switch (this) {
      case FilamentControllerLifecycleState.newState:
        return 'New';
      case FilamentControllerLifecycleState.initialized:
        return 'Initialized';
      case FilamentControllerLifecycleState.viewerReady:
        return 'ViewerReady';
      case FilamentControllerLifecycleState.disposing:
        return 'Disposing';
      case FilamentControllerLifecycleState.disposed:
        return 'Disposed';
    }
  }
}

class FilamentController {
  FilamentController({
    this.debugFeaturesEnabled = kDebugMode,
  });

  /// Whether debug components (wireframes, bounds) can be enabled.
  ///
  /// Defaults to `true` in debug builds and `false` in release builds.
  /// If `false`, calls to `setWireframeEnabled` or `setBoundingBoxesEnabled`
  /// will be ignored by the native implementation.
  final bool debugFeaturesEnabled;

  static const MethodChannel _methodChannel = MethodChannel('filament_widget');
  static const EventChannel _eventChannel = EventChannel(
    'filament_widget/events',
  );
  static const BasicMessageChannel<ByteData> _controlChannel =
      BasicMessageChannel<ByteData>(
    'filament_widget/controls',
    BinaryCodec(),
  );

  static final StreamController<Map<dynamic, dynamic>>
      _globalEventStreamController =
      StreamController<Map<dynamic, dynamic>>.broadcast();
  static StreamSubscription<dynamic>? _globalEventSub;
  static int _activeControllerCount = 0;

  int? _controllerId;
  int? _textureId;
  FilamentControllerLifecycleState _state =
      FilamentControllerLifecycleState.newState;
  Future<void>? _initializeFuture;
  Future<void>? _disposeFuture;
  StreamSubscription<Map<dynamic, dynamic>>? _controllerEventSub;
  final StreamController<FilamentEvent> _eventController =
      StreamController<FilamentEvent>.broadcast();
  bool _eventStreamRegistered = false;

  final ValueNotifier<double> fps = ValueNotifier<double>(0.0);
  final Completer<void> _viewerReadyCompleter = Completer<void>();

  // Gesture throttling state
  double _pendingOrbitX = 0;
  double _pendingOrbitY = 0;
  double _pendingZoomScale = 1.0;
  bool _isFrameCallbackScheduled = false;

  int? get textureId => _textureId;

  @visibleForTesting
  int? get debugControllerId => _controllerId;

  Stream<FilamentEvent> get events => _eventController.stream;
  Future<void> get onViewerReady => _viewerReadyCompleter.future;

  bool get _isInitialized =>
      _state == FilamentControllerLifecycleState.initialized ||
      _state == FilamentControllerLifecycleState.viewerReady;

  bool get _isDisposed =>
      _state == FilamentControllerLifecycleState.disposing ||
      _state == FilamentControllerLifecycleState.disposed;

  void _transitionTo(FilamentControllerLifecycleState next) {
    if (_state == next) {
      return;
    }
    if (kDebugMode) {
      debugPrint(
        '[FilamentController] State ${_state.label} -> ${next.label}',
      );
    }
    _state = next;
  }

  PlatformException _disposedException() {
    return const PlatformException(
      code: 'filament_disposed',
      message: 'Controller disposed.',
    );
  }

  PlatformException _noViewerException() {
    return const PlatformException(
      code: 'filament_no_viewer',
      message: 'Viewer not initialized.',
    );
  }

  void _scheduleGestureFlush() {
    if (_isFrameCallbackScheduled) {
      return;
    }
    _isFrameCallbackScheduled = true;
    SchedulerBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushGestureDeltas();
    });
  }

  Future<void> _sendOrbitDelta(double dx, double dy) async {
    await _ensureViewerReady();
    final buffer = ByteData(24);
    buffer.setInt32(0, _controllerId!, Endian.little);
    buffer.setInt32(4, 1, Endian.little); // Opcode ORBIT = 1
    buffer.setFloat32(8, dx, Endian.little);
    buffer.setFloat32(12, dy, Endian.little);
    buffer.setFloat32(16, 0, Endian.little);
    buffer.setInt32(20, 0, Endian.little); // Flags NONE
    await _controlChannel.send(buffer);
  }

  Future<void> _sendZoomDelta(double scaleDelta) async {
    await _ensureViewerReady();
    final buffer = ByteData(24);
    buffer.setInt32(0, _controllerId!, Endian.little);
    buffer.setInt32(4, 2, Endian.little); // Opcode ZOOM = 2
    buffer.setFloat32(8, 0, Endian.little);
    buffer.setFloat32(12, 0, Endian.little);
    buffer.setFloat32(16, scaleDelta, Endian.little);
    buffer.setInt32(20, 0, Endian.little); // Flags NONE
    await _controlChannel.send(buffer);
  }

  Future<void> _flushGestureDeltas() async {
    _isFrameCallbackScheduled = false;

    final dx = _pendingOrbitX;
    final dy = _pendingOrbitY;
    final scaleDelta = _pendingZoomScale;

    _pendingOrbitX = 0;
    _pendingOrbitY = 0;
    _pendingZoomScale = 1.0;

    if (dx != 0 || dy != 0) {
      await _sendOrbitDelta(dx, dy);
    }

    if (scaleDelta != 1.0) {
      await _sendZoomDelta(scaleDelta);
    }
  }

  Future<void> _sendControlMessage({int flags = 0}) async {
    await _ensureViewerReady();
    final buffer = ByteData(24);
    buffer.setInt32(0, _controllerId!, Endian.little);
    buffer.setInt32(4, 0, Endian.little); // Opcode NOOP
    buffer.setFloat32(8, 0, Endian.little);
    buffer.setFloat32(12, 0, Endian.little);
    buffer.setFloat32(16, 0, Endian.little);
    buffer.setInt32(20, flags, Endian.little);
    await _controlChannel.send(buffer);
  }

  Future<void> initialize() async {
    if (_isDisposed) {
      throw _disposedException();
    }
    if (_isInitialized) {
      return;
    }
    if (_initializeFuture != null) {
      await _initializeFuture;
      return;
    }
    final completer = Completer<void>();
    _initializeFuture = completer.future;
    try {
      final controllerId = await _methodChannel.invokeMethod<int>(
        'createController',
        {
          'debugFeaturesEnabled': debugFeaturesEnabled,
        },
      );
      if (_isDisposed) {
        if (controllerId != null) {
          await _methodChannel.invokeMethod<void>('disposeController', {
            'controllerId': controllerId,
          });
        }
        _transitionTo(FilamentControllerLifecycleState.disposed);
        completer.complete();
        return;
      }
      if (controllerId == null) {
        _transitionTo(FilamentControllerLifecycleState.disposed);
        throw StateError('Failed to create native controller.');
      }
      _controllerId = controllerId;
    } finally {
      completer.complete();
    }
    if (_isDisposed) return; // check again after await

    _ensureGlobalEventStream();
    _eventStreamRegistered = true;
    _controllerEventSub = _globalEventStreamController.stream.listen((event) {
      if (event['controllerId'] == _controllerId) {
        _handleEvent(event);
      }
    });

    _transitionTo(FilamentControllerLifecycleState.initialized);
  }

  Future<void> dispose() async {
    if (_disposeFuture != null) {
      await _disposeFuture;
      return;
    }
    final completer = Completer<void>();
    _disposeFuture = completer.future;
    if (_state == FilamentControllerLifecycleState.disposed) {
      completer.complete();
      return;
    }
    if (_state != FilamentControllerLifecycleState.disposing) {
      _transitionTo(FilamentControllerLifecycleState.disposing);
    }
    await _controllerEventSub?.cancel();
    _controllerEventSub = null;

    if (_eventStreamRegistered) {
      _releaseGlobalEventStream();
      _eventStreamRegistered = false;
    }

    if (_controllerId != null) {
      await _methodChannel.invokeMethod<void>('disposeController', {
        'controllerId': _controllerId,
      });
    }
    _textureId = null;
    _controllerId = null;
    _transitionTo(FilamentControllerLifecycleState.disposed);
    await _eventController.close();
    completer.complete();
  }

  static void _ensureGlobalEventStream() {
    if (_activeControllerCount == 0) {
      _globalEventSub = _eventChannel.receiveBroadcastStream().listen((event) {
        if (event is Map) {
          _globalEventStreamController.add(event);
        }
      }, onError: (error) {
        // Forward errors if needed, or log
      });
    }
    _activeControllerCount++;
  }

  static void _releaseGlobalEventStream() {
    _activeControllerCount--;
    if (_activeControllerCount <= 0) {
      _activeControllerCount = 0;
      _globalEventSub?.cancel();
      _globalEventSub = null;
    }
  }

  Future<void> createViewer({
    required int widthPx,
    required int heightPx,
    required double devicePixelRatio,
  }) async {
    if (_isDisposed) {
      throw _disposedException();
    }
    await _ensureInitialized();
    if (_isDisposed) {
      throw _disposedException();
    }

    final textureId = await _methodChannel.invokeMethod<int>('createViewer', {
      'controllerId': _controllerId,
      'width': widthPx,
      'height': heightPx,
      'dpr': devicePixelRatio,
    });
    _textureId = textureId;
    if (textureId != null) {
      _transitionTo(FilamentControllerLifecycleState.viewerReady);
    }
    if (!_viewerReadyCompleter.isCompleted) {
      _viewerReadyCompleter.complete();
    }
  }

  Future<void> resize(int widthPx, int heightPx, double dpr) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('resize', {
      'controllerId': _controllerId,
      'width': widthPx,
      'height': heightPx,
      'dpr': dpr,
    });
  }

  Future<void> clearScene() async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('clearScene', {
      'controllerId': _controllerId,
    });
  }

  Future<void> loadModelFromAsset(String assetPath) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('loadModelFromAsset', {
      'controllerId': _controllerId,
      'assetPath': assetPath,
    });
  }

  Future<void> loadModelFromUrl(String url) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('loadModelFromUrl', {
      'controllerId': _controllerId,
      'url': url,
    });
  }

  Future<void> loadModelFromFile(String filePath) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('loadModelFromFile', {
      'controllerId': _controllerId,
      'filePath': filePath,
    });
  }

  Future<int> getCacheSizeBytes() async {
    await _ensureInitialized();
    final size = await _methodChannel.invokeMethod<int>('getCacheSizeBytes', {
      'controllerId': _controllerId,
    });
    return size ?? 0;
  }

  Future<void> clearCache() async {
    await _ensureInitialized();
    await _methodChannel.invokeMethod<void>('clearCache', {
      'controllerId': _controllerId,
    });
  }

  Future<void> setIBLFromAsset(String ktxPath) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setIBLFromAsset', {
      'controllerId': _controllerId,
      'ktxPath': ktxPath,
    });
  }

  Future<void> setSkyboxFromAsset(String ktxPath) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setSkyboxFromAsset', {
      'controllerId': _controllerId,
      'ktxPath': ktxPath,
    });
  }

  Future<void> setHdriFromAsset(String hdrPath) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setHdriFromAsset', {
      'controllerId': _controllerId,
      'hdrPath': hdrPath,
    });
  }

  Future<void> setIBLFromUrl(String url) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setIBLFromUrl', {
      'controllerId': _controllerId,
      'url': url,
    });
  }

  Future<void> setSkyboxFromUrl(String url) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setSkyboxFromUrl', {
      'controllerId': _controllerId,
      'url': url,
    });
  }

  Future<void> setHdriFromUrl(String url) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setHdriFromUrl', {
      'controllerId': _controllerId,
      'url': url,
    });
  }

  Future<void> setEnvironmentEnabled(bool enabled) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setEnvironmentEnabled', {
      'controllerId': _controllerId,
      'enabled': enabled,
    });
  }

  Future<void> setShadowsEnabled(bool enabled) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setShadowsEnabled', {
      'controllerId': _controllerId,
      'enabled': enabled,
    });
  }

  Future<void> frameModel({bool useWorldOrigin = false}) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('frameModel', {
      'controllerId': _controllerId,
      'useWorldOrigin': useWorldOrigin,
    });
  }

  Future<void> setOrbitConstraints({
    required double minPitchDeg,
    required double maxPitchDeg,
    required double minYawDeg,
    required double maxYawDeg,
  }) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setOrbitConstraints', {
      'controllerId': _controllerId,
      'minPitchDeg': minPitchDeg,
      'maxPitchDeg': maxPitchDeg,
      'minYawDeg': minYawDeg,
      'maxYawDeg': maxYawDeg,
    });
  }

  Future<void> setInertiaEnabled(bool enabled) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setInertiaEnabled', {
      'controllerId': _controllerId,
      'enabled': enabled,
    });
  }

  Future<void> setInertiaParams({
    double damping = 0.9,
    double sensitivity = 1.0,
  }) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setInertiaParams', {
      'controllerId': _controllerId,
      'damping': damping,
      'sensitivity': sensitivity,
    });
  }

  Future<void> setZoomLimits({
    required double minDistance,
    required double maxDistance,
  }) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setZoomLimits', {
      'controllerId': _controllerId,
      'minDistance': minDistance,
      'maxDistance': maxDistance,
    });
  }

  Future<void> setCustomCameraEnabled(bool enabled) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setCustomCameraEnabled', {
      'controllerId': _controllerId,
      'enabled': enabled,
    });
  }

  Future<void> setCustomCameraLookAt({
    required double eyeX,
    required double eyeY,
    required double eyeZ,
    required double centerX,
    required double centerY,
    required double centerZ,
    required double upX,
    required double upY,
    required double upZ,
  }) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setCustomCameraLookAt', {
      'controllerId': _controllerId,
      'eyeX': eyeX,
      'eyeY': eyeY,
      'eyeZ': eyeZ,
      'centerX': centerX,
      'centerY': centerY,
      'centerZ': centerZ,
      'upX': upX,
      'upY': upY,
      'upZ': upZ,
    });
  }

  Future<void> setCustomPerspective({
    required double fovDegrees,
    required double near,
    required double far,
  }) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setCustomPerspective', {
      'controllerId': _controllerId,
      'fovDegrees': fovDegrees,
      'near': near,
      'far': far,
    });
  }

  Future<int> getAnimationCount() async {
    await _ensureViewerReady();
    final count = await _methodChannel.invokeMethod<int>('getAnimationCount', {
      'controllerId': _controllerId,
    });
    return count ?? 0;
  }

  Future<void> playAnimation(int index, {bool loop = true}) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('playAnimation', {
      'controllerId': _controllerId,
      'index': index,
      'loop': loop,
    });
  }

  Future<void> pauseAnimation() async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('pauseAnimation', {
      'controllerId': _controllerId,
    });
  }

  Future<void> seekAnimation(double seconds) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('seekAnimation', {
      'controllerId': _controllerId,
      'seconds': seconds,
    });
  }

  Future<void> setAnimationSpeed(double speed) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setAnimationSpeed', {
      'controllerId': _controllerId,
      'speed': speed,
    });
  }

  Future<double> getAnimationDuration(int index) async {
    await _ensureViewerReady();
    final duration = await _methodChannel.invokeMethod<double>(
      'getAnimationDuration',
      {'controllerId': _controllerId, 'index': index},
    );
    return duration ?? 0.0;
  }

  Future<void> setMsaa(int samples) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setMsaa', {
      'controllerId': _controllerId,
      'samples': samples,
    });
  }

  Future<void> setDynamicResolutionEnabled(bool enabled) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setDynamicResolutionEnabled', {
      'controllerId': _controllerId,
      'enabled': enabled,
    });
  }

  Future<void> setToneMappingFilmic() async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setToneMappingFilmic', {
      'controllerId': _controllerId,
    });
  }

  Future<void> setWireframeEnabled(bool enabled) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setWireframeEnabled', {
      'controllerId': _controllerId,
      'enabled': enabled,
    });
  }

  Future<void> setBoundingBoxesEnabled(bool enabled) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setBoundingBoxesEnabled', {
      'controllerId': _controllerId,
      'enabled': enabled,
    });
  }

  Future<void> setDebugLoggingEnabled(bool enabled) async {
    await _ensureViewerReady();
    await _methodChannel.invokeMethod<void>('setDebugLoggingEnabled', {
      'controllerId': _controllerId,
      'enabled': enabled,
    });
  }

  Future<void> handleOrbitStart() async {
    await _flushGestureDeltas();
    // Use Control Channel for Start
    await _sendControlMessage(flags: 1);
  }

  Future<void> handleOrbitDelta(double dx, double dy) async {
    _pendingOrbitX += dx;
    _pendingOrbitY += dy;
    _scheduleGestureFlush();
  }

  Future<void> handleOrbitEnd({
    required double velocityX,
    required double velocityY,
  }) async {
    await _flushGestureDeltas();
    await _ensureViewerReady();
    // Use Control Channel for End
    await _sendControlMessage(flags: 2);
    // Still send orbitEnd via method channel to pass velocity
    await _methodChannel.invokeMethod<void>('orbitEnd', {
      'controllerId': _controllerId,
      'velocityX': velocityX,
      'velocityY': velocityY,
    });
  }

  Future<void> handleZoomStart() async {
    await _flushGestureDeltas();
    await _sendControlMessage(flags: 1);
  }

  Future<void> handleZoomDelta(double scaleDelta) async {
    _pendingZoomScale *= scaleDelta;
    _scheduleGestureFlush();
  }

  Future<void> handleZoomEnd() async {
    final pendingScale = _pendingZoomScale;
    _pendingZoomScale = 1.0;
    if (pendingScale != 1.0) {
      await _sendZoomDelta(pendingScale);
    }
    await _flushGestureDeltas();
    await _sendControlMessage(flags: 2);
  }

  Future<void> _ensureInitialized() async {
    if (_isDisposed) {
      throw _disposedException();
    }
    if (!_isInitialized) {
      await initialize();
    }
    if (_controllerId == null) {
      throw const PlatformException(
        code: 'filament_native',
        message: 'FilamentController not initialized.',
      );
    }
  }

  Future<void> _ensureViewerReady() async {
    if (_isDisposed) {
      throw _disposedException();
    }
    await _ensureInitialized();
    if (_state != FilamentControllerLifecycleState.viewerReady ||
        _textureId == null) {
      throw _noViewerException();
    }
  }

  void _handleEvent(dynamic event) {
    if (event is! Map) {
      return;
    }
    final type = event['type']?.toString() ?? 'unknown';
    final message = event['message']?.toString() ?? '';
    final filamentEvent = FilamentEvent(type, message);
    if (type == 'fps') {
      final value = double.tryParse(message);
      if (value != null) {
        fps.value = value;
      }
    }
    _eventController.add(filamentEvent);
  }
}

class FilamentEvent {
  FilamentEvent(this.type, this.message);

  final String type;
  final String message;
}
