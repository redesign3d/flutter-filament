import 'dart:typed_data';

import 'package:filament_widget/filament_widget.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('filament_widget');
  const BasicMessageChannel<ByteData> controlChannel =
      BasicMessageChannel<ByteData>('filament_widget/controls', BinaryCodec());
  final List<MethodCall> log = <MethodCall>[];
  final List<ByteData> controlMessages = <ByteData>[];

  setUp(() {
    log.clear();
    controlMessages.clear();
    var nextId = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      log.add(methodCall);
      if (methodCall.method == 'createController') {
        return nextId++;
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<ByteData>(controlChannel,
            (ByteData? message) async {
      if (message != null) {
        controlMessages.add(message);
      }
      return ByteData(0);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<ByteData>(controlChannel, null);
  });

  Map<String, dynamic> decodeControl(ByteData data) {
    return {
      'controllerId': data.getInt32(0, Endian.little),
      'opcode': data.getInt32(4, Endian.little),
      'a': data.getFloat32(8, Endian.little),
      'b': data.getFloat32(12, Endian.little),
      'c': data.getFloat32(16, Endian.little),
      'flags': data.getInt32(20, Endian.little),
    };
  }

  testWidgets('Orbit deltas are aggregated per frame',
      (WidgetTester tester) async {
    final controller = FilamentController();
    await controller.initialize();
    log.clear(); // remove createController call

    // Simulate 3 small moves
    await controller.handleOrbitDelta(10.0, 5.0);
    await controller.handleOrbitDelta(2.0, 2.0);
    await controller.handleOrbitDelta(-1.0, 3.0);

    // Should not have sent anything yet
    expect(log.where((c) => c.method == 'orbitDelta'), isEmpty);

    // Process frame
    tester.binding.scheduleFrame();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    // Should have sent one aggregated event
    final orbitMessages = controlMessages
        .map(decodeControl)
        .where((m) => m['opcode'] == 1)
        .toList();
    expect(orbitMessages.length, 1);
    expect(orbitMessages.first['a'], 11.0); // 10 + 2 - 1
    expect(orbitMessages.first['b'], 10.0); // 5 + 2 + 3
  });

  testWidgets('Zoom deltas are aggregated per frame (multiplicative)',
      (WidgetTester tester) async {
    final controller = FilamentController();
    await controller.initialize();
    log.clear();

    await controller.handleZoomDelta(1.1);
    await controller.handleZoomDelta(1.1);

    expect(log.where((c) => c.method == 'zoomDelta'), isEmpty);

    tester.binding.scheduleFrame();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    final zoomMessages = controlMessages
        .map(decodeControl)
        .where((m) => m['opcode'] == 2)
        .toList();
    expect(zoomMessages.length, 1);
    // 1.1 * 1.1 = 1.21
    expect(zoomMessages.first['c'], closeTo(1.21, 0.0001));
  });

  testWidgets('OrbitEnd forces flush of pending deltas',
      (WidgetTester tester) async {
    final controller = FilamentController();
    await controller.initialize();
    log.clear();

    await controller.handleOrbitDelta(5.0, 0.0);

    // Call End immediately
    await controller.handleOrbitEnd(velocityX: 0, velocityY: 0);

    // Expect orbitDelta THEN orbitEnd
    final orbitMessages = controlMessages
        .map(decodeControl)
        .where((m) => m['opcode'] == 1)
        .toList();
    expect(orbitMessages.length, 1);
    expect(orbitMessages.first['a'], 5.0);
    final endCalls = log.where((c) => c.method == 'orbitEnd').toList();
    expect(endCalls.length, 1);
  });

  testWidgets('ZoomEnd forces flush of pending deltas',
      (WidgetTester tester) async {
    final controller = FilamentController();
    await controller.initialize();
    log.clear();

    await controller.handleZoomDelta(2.0);

    // Call End immediately
    await controller.handleZoomEnd();
    await tester.pump();

    final zoomMessages = controlMessages
        .map(decodeControl)
        .where((m) => m['opcode'] == 2)
        .toList();
    expect(zoomMessages.length, 1);
    expect(zoomMessages.first['c'], 2.0);
    final endMessages = controlMessages
        .map(decodeControl)
        .where((m) => m['opcode'] == 0 && m['flags'] == 2)
        .toList();
    expect(endMessages.length, 1);
  });
}
