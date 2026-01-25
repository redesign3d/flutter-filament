import 'package:filament_widget/filament_widget.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Use the exact mock class expected by flutter_test
import 'package:flutter_test/src/mock_event_channel.dart' as test_mocks;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel methodChannel = MethodChannel('filament_widget');
  const EventChannel eventChannel = EventChannel('filament_widget/events');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall methodCall) async {
      if (methodCall.method == 'createController') {
        return null;
      }
      return null;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(eventChannel, MyMockStreamHandler());
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(eventChannel, null);
  });

  test('Event routing correctly dispatches events to the right controller',
      () async {
    final controller1 = FilamentController();
    final controller2 = FilamentController();

    await controller1.initialize();
    await controller2.initialize();

    final c1Events = <FilamentEvent>[];
    final c2Events = <FilamentEvent>[];

    final sub1 = controller1.events.listen(c1Events.add);
    final sub2 = controller2.events.listen(c2Events.add);

    // Simulate events from native side via the mock stream handler
    // Native sends: {controllerId: ..., type: ..., message: ...}
    MyMockStreamHandler.sink?.success({
      'controllerId': 1, // Assuming controller1 gets ID 1
      'type': 'test_event',
      'message': 'hello c1',
    });

    MyMockStreamHandler.sink?.success({
      'controllerId': 2, // Assuming controller2 gets ID 2
      'type': 'test_event',
      'message': 'hello c2',
    });

    // Wait for stream propagation
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero); // Extra tick for good measure

    // We do not check exact IDs since they are static and might increment if tests run together
    // Instead we check we got 'hello c1' in c1Events and 'hello c2' in c2Events

    expect(c1Events.any((e) => e.message == 'hello c1'), isTrue);
    expect(c2Events.any((e) => e.message == 'hello c2'), isTrue);

    // Ensure cross-talk didn't happen
    expect(c1Events.any((e) => e.message == 'hello c2'), isFalse);
    expect(c2Events.any((e) => e.message == 'hello c1'), isFalse);

    await sub1.cancel();
    await sub2.cancel();
    await controller1.dispose();
    await controller2.dispose();
  });
}

class MyMockStreamHandler extends test_mocks.MockStreamHandler {
  static test_mocks.MockStreamHandlerEventSink? sink;

  @override
  void onListen(
      Object? arguments, test_mocks.MockStreamHandlerEventSink events) {
    sink = events;
  }

  @override
  void onCancel(Object? arguments) {
    sink = null;
  }
}
