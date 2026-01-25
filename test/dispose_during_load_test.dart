import 'dart:async';

import 'package:filament_widget/filament_widget.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('filament_widget');

  final List<Completer<void>> pendingLoads = <Completer<void>>[];

  setUp(() {
    pendingLoads.clear();
    var nextId = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) {
      switch (methodCall.method) {
        case 'createController':
          return Future<Object?>.value(nextId++);
        case 'disposeController':
          for (final completer in pendingLoads) {
            if (!completer.isCompleted) {
              completer.completeError(PlatformException(
                code: 'filament_disposed',
                message: 'Controller disposed.',
              ));
            }
          }
          pendingLoads.clear();
          return Future<Object?>.value(null);
        case 'loadModelFromAsset':
        case 'loadModelFromUrl':
        case 'loadModelFromFile':
          final completer = Completer<Object?>();
          pendingLoads.add(completer);
          return completer.future;
      }
      return Future<Object?>.value(null);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> expectDisposed(Future<void> future) async {
    await expectLater(
      future.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'filament_disposed'),
      ),
    );
  }

  test('loadModelFromAsset completes when disposed', () async {
    final controller = FilamentController();
    await controller.initialize();

    final loadFuture = controller.loadModelFromAsset('assets/model.glb');
    final expectation = expectDisposed(loadFuture);
    await controller.dispose();
    await expectation;
  });

  test('loadModelFromUrl completes when disposed', () async {
    final controller = FilamentController();
    await controller.initialize();

    final loadFuture = controller.loadModelFromUrl('https://example.com/a.glb');
    final expectation = expectDisposed(loadFuture);
    await controller.dispose();
    await expectation;
  });
}
