import 'package:filament_widget/filament_widget.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FilamentController starts with zero fps', () {
    final controller = FilamentController();
    expect(controller.fps.value, 0.0);
  });

  test('FilamentController uses native-generated ids', () async {
    const MethodChannel channel = MethodChannel('filament_widget');
    var nextId = 41;
    final receivedArgs = <Map<String, Object?>>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'createController') {
        receivedArgs.add(Map<String, Object?>.from(methodCall.arguments as Map));
        return nextId++;
      }
      return null;
    });

    final controller1 = FilamentController();
    final controller2 = FilamentController();
    await controller1.initialize();
    await controller2.initialize();

    expect(controller1.debugControllerId, isNotNull);
    expect(controller2.debugControllerId, isNotNull);
    expect(controller1.debugControllerId, isNot(controller2.debugControllerId));
    expect(controller1.debugControllerId, 41);
    expect(controller2.debugControllerId, 42);
    for (final args in receivedArgs) {
      expect(args.containsKey('controllerId'), isFalse);
    }

    await controller1.dispose();
    await controller2.dispose();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
