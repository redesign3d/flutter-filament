import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:filament_widget_example/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('load BoomBox and toggle debug overlays', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final boomBoxButton = find.text('Load BoomBox (glTF)');
    expect(boomBoxButton, findsOneWidget);
    await tester.tap(boomBoxButton);
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));

    final wireframeTile = find.text('Wireframe');
    await tester.ensureVisible(wireframeTile);
    await tester.tap(wireframeTile);
    await tester.pump(const Duration(seconds: 1));

    final bboxTile = find.text('Bounding boxes');
    await tester.ensureVisible(bboxTile);
    await tester.tap(bboxTile);
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(wireframeTile);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(bboxTile);
    await tester.pump(const Duration(seconds: 1));
  });
}
