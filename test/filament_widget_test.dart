import 'package:flutter_test/flutter_test.dart';
import 'package:filament_widget/filament_widget.dart';
import 'package:filament_widget/filament_widget_platform_interface.dart';
import 'package:filament_widget/filament_widget_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFilamentWidgetPlatform
    with MockPlatformInterfaceMixin
    implements FilamentWidgetPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FilamentWidgetPlatform initialPlatform =
      FilamentWidgetPlatform.instance;

  test('$MethodChannelFilamentWidget is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFilamentWidget>());
  });

  test('getPlatformVersion', () async {
    FilamentWidget filamentWidgetPlugin = FilamentWidget();
    MockFilamentWidgetPlatform fakePlatform = MockFilamentWidgetPlatform();
    FilamentWidgetPlatform.instance = fakePlatform;

    expect(await filamentWidgetPlugin.getPlatformVersion(), '42');
  });
}
