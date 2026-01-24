import 'package:filament_widget/filament_widget.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('filament_widget');
  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      log.add(methodCall);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('Orbit deltas are aggregated per frame', (WidgetTester tester) async {
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
    final calls = log.where((c) => c.method == 'orbitDelta').toList();
    expect(calls.length, 1);
    expect(calls.first.arguments['dx'], 11.0); // 10 + 2 - 1
    expect(calls.first.arguments['dy'], 10.0); // 5 + 2 + 3
  });

  testWidgets('Zoom deltas are aggregated per frame (multiplicative)', (WidgetTester tester) async {
    final controller = FilamentController();
    await controller.initialize();
    log.clear();

    await controller.handleZoomDelta(1.1);
    await controller.handleZoomDelta(1.1);
    
    expect(log.where((c) => c.method == 'zoomDelta'), isEmpty);

    tester.binding.scheduleFrame();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    final calls = log.where((c) => c.method == 'zoomDelta').toList();
    expect(calls.length, 1);
    // 1.1 * 1.1 = 1.21
    expect(calls.first.arguments['scaleDelta'], closeTo(1.21, 0.0001));
  });

  testWidgets('OrbitEnd forces flush of pending deltas', (WidgetTester tester) async {
    final controller = FilamentController();
    await controller.initialize();
    log.clear();

    await controller.handleOrbitDelta(5.0, 0.0);
    
    // Call End immediately
    await controller.handleOrbitEnd(velocityX: 0, velocityY: 0);

    // Expect orbitDelta THEN orbitEnd
    final importantCalls = log.where((c) => c.method == 'orbitDelta' || c.method == 'orbitEnd').toList();
    expect(importantCalls.length, 2);
    expect(importantCalls[0].method, 'orbitDelta');
    expect(importantCalls[0].arguments['dx'], 5.0);
    expect(importantCalls[1].method, 'orbitEnd');
  });

  testWidgets('ZoomEnd forces flush of pending deltas', (WidgetTester tester) async {
    final controller = FilamentController();
    await controller.initialize();
    log.clear();

    await controller.handleZoomDelta(2.0);
    
    // Call End immediately
    await controller.handleZoomEnd();

    final importantCalls = log.where((c) => c.method == 'zoomDelta' || c.method == 'zoomEnd').toList();
    expect(importantCalls.length, 2);
    expect(importantCalls[0].method, 'zoomDelta');
    expect(importantCalls[0].arguments['scaleDelta'], 2.0);
    expect(importantCalls[1].method, 'zoomEnd');
  });
}
