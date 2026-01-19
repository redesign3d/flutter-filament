import 'package:filament_widget/filament_widget.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const FilamentExampleApp());
}

class FilamentExampleApp extends StatefulWidget {
  const FilamentExampleApp({super.key});

  @override
  State<FilamentExampleApp> createState() => _FilamentExampleAppState();
}

class _FilamentExampleAppState extends State<FilamentExampleApp> {
  final FilamentController _controller = FilamentController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Filament Widget Example')),
        body: FilamentWidget(controller: _controller),
      ),
    );
  }
}
