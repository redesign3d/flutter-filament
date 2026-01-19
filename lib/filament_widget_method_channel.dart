import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'filament_widget_platform_interface.dart';

/// An implementation of [FilamentWidgetPlatform] that uses method channels.
class MethodChannelFilamentWidget extends FilamentWidgetPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('filament_widget');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
