import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'filament_widget_method_channel.dart';

abstract class FilamentWidgetPlatform extends PlatformInterface {
  /// Constructs a FilamentWidgetPlatform.
  FilamentWidgetPlatform() : super(token: _token);

  static final Object _token = Object();

  static FilamentWidgetPlatform _instance = MethodChannelFilamentWidget();

  /// The default instance of [FilamentWidgetPlatform] to use.
  ///
  /// Defaults to [MethodChannelFilamentWidget].
  static FilamentWidgetPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FilamentWidgetPlatform] when
  /// they register themselves.
  static set instance(FilamentWidgetPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
