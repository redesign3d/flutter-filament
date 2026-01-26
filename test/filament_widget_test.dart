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
        receivedArgs
            .add(Map<String, Object?>.from(methodCall.arguments as Map));
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

  test('FilamentController dispose is idempotent', () async {
    const MethodChannel channel = MethodChannel('filament_widget');
    var nextId = 1;
    var disposeCalls = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'createController':
          return nextId++;
        case 'disposeController':
          disposeCalls += 1;
          return null;
      }
      return null;
    });

    final controller = FilamentController();
    await controller.initialize();
    await controller.dispose();
    await controller.dispose();

    expect(disposeCalls, 1);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Dispose after createViewer does not crash', () async {
    const MethodChannel channel = MethodChannel('filament_widget');
    var nextId = 1;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'createController':
          return nextId++;
        case 'createViewer':
          return 123;
        case 'disposeController':
          return null;
      }
      return null;
    });

    final controller = FilamentController();
    await controller.initialize();
    await controller.createViewer(
        widthPx: 100, heightPx: 100, devicePixelRatio: 1.0);
    await controller.dispose();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
