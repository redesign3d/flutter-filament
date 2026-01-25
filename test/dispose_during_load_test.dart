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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'createController':
          return;
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
          return;
        case 'loadModelFromAsset':
        case 'loadModelFromUrl':
        case 'loadModelFromFile':
          final completer = Completer<void>();
          pendingLoads.add(completer);
          return completer.future;
      }
      return;
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
    await controller.dispose();

    await expectDisposed(loadFuture);
  });

  test('loadModelFromUrl completes when disposed', () async {
    final controller = FilamentController();
    await controller.initialize();

    final loadFuture = controller.loadModelFromUrl('https://example.com/a.glb');
    await controller.dispose();

    await expectDisposed(loadFuture);
  });
}
