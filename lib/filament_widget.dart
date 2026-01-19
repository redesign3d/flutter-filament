import 'filament_widget_platform_interface.dart';

class FilamentWidget {
  Future<String?> getPlatformVersion() {
    return FilamentWidgetPlatform.instance.getPlatformVersion();
  }
}
