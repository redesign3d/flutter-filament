import 'package:filament_widget/filament_widget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FilamentController starts with zero fps', () {
    final controller = FilamentController();
    expect(controller.fps.value, 0.0);
  });
}
