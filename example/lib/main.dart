import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:filament_widget/filament_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

import 'bloc/animation_cubit.dart';
import 'bloc/model_loader_cubit.dart';
import 'bloc/settings_cubit.dart';

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
  late final SettingsCubit _settingsCubit = SettingsCubit(_controller);
  late final ModelLoaderCubit _modelLoaderCubit = ModelLoaderCubit(_controller);
  late final AnimationCubit _animationCubit = AnimationCubit(_controller);

  @override
  void dispose() {
    _animationCubit.close();
    _modelLoaderCubit.close();
    _settingsCubit.close();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFE36A4E),
      brightness: Brightness.light,
    );
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      textTheme: GoogleFonts.spaceGroteskTextTheme(),
      scaffoldBackgroundColor: const Color(0xFFF6F2EA),
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFFF6F2EA),
        foregroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: const Color(0xFF1A1A1A),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFE36A4E),
          foregroundColor: Colors.white,
        ),
      ),
    );

    return MultiBlocProvider(
      providers: [
        BlocProvider.value(value: _settingsCubit),
        BlocProvider.value(value: _modelLoaderCubit),
        BlocProvider.value(value: _animationCubit),
      ],
      child: MaterialApp(
        theme: theme,
        home: ExampleHome(controller: _controller),
      ),
    );
  }
}

class ExampleHome extends StatelessWidget {
  const ExampleHome({super.key, required this.controller});

  final FilamentController controller;

  @override
  Widget build(BuildContext context) {
    return BlocListener<ModelLoaderCubit, ModelLoaderState>(
      listenWhen: (previous, current) =>
          !previous.modelLoaded && current.modelLoaded,
      listener: (context, state) {
        context.read<AnimationCubit>().loadAnimations();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Filament Widget Showcase')),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFF6F2EA), Color(0xFFFDFBF7)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 900;
                if (isWide) {
                  return Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 3,
                          child: _ViewerPanel(controller: controller),
                        ),
                        const SizedBox(width: 16),
                        const Expanded(flex: 2, child: _ControlPanel()),
                      ],
                    ),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 5,
                      child: _ViewerPanel(controller: controller),
                    ),
                    const SizedBox(height: 16),
                    const Expanded(
                      flex: 4,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16.0),
                        child: _ControlPanel(),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewerPanel extends StatelessWidget {
  const _ViewerPanel({required this.controller});

  final FilamentController controller;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsCubit, SettingsState>(
      builder: (context, settings) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              FilamentWidget(
                controller: controller,
                enableGestures: true,
                showDevToolsOverlay: settings.fpsOverlayEnabled,
              ),
              BlocBuilder<ModelLoaderCubit, ModelLoaderState>(
                builder: (context, state) {
                  if (!state.isLoading) {
                    return const SizedBox.shrink();
                  }
                  return Container(
                    color: Colors.black.withValues(alpha: 0.35),
                    child: const Center(child: CircularProgressIndicator()),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ControlPanel extends StatelessWidget {
  const _ControlPanel();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          _ModelSection(),
          SizedBox(height: 16),
          _AnimationSection(),
          SizedBox(height: 16),
          _SettingsSection(),
        ],
      ),
    );
  }
}

class _ModelSection extends StatelessWidget {
  const _ModelSection();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Models & Cache',
      child: BlocBuilder<ModelLoaderCubit, ModelLoaderState>(
        builder: (context, state) {
          final cubit = context.read<ModelLoaderCubit>();
          final statusColor = state.errorMessage != null
              ? Colors.redAccent
              : const Color(0xFF1A1A1A);
          Widget modelButton({
            required DemoModelId id,
            required IconData icon,
            required String label,
            required VoidCallback onPressed,
          }) {
            final isSelected = state.selectedModelId == id;
            final effectiveOnPressed = state.isLoading ? null : onPressed;
            final buttonIcon = Icon(isSelected ? Icons.check_circle : icon);
            if (isSelected) {
              return FilledButton.icon(
                onPressed: effectiveOnPressed,
                icon: buttonIcon,
                label: Text(label),
              );
            }
            return OutlinedButton.icon(
              onPressed: effectiveOnPressed,
              icon: buttonIcon,
              label: Text(label),
            );
          }

          Future<void> pickLocalModel() async {
            final result = await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: const ['glb', 'gltf'],
            );
            if (result == null || result.files.isEmpty) {
              return;
            }
            final file = result.files.first;
            final path = file.path;
            if (path == null || path.isEmpty) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Unable to access selected file.')),
                );
              }
              return;
            }
            await cubit.loadLocalFile(path, displayName: file.name);
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state.status,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
              if (state.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    state.errorMessage!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  modelButton(
                    id: DemoModelId.avocadoGlb,
                    icon: Icons.inventory_2,
                    label: 'Load Avocado (GLB)',
                    onPressed: cubit.loadAssetGlb,
                  ),
                  modelButton(
                    id: DemoModelId.boomBoxGltf,
                    icon: Icons.music_note,
                    label: 'Load BoomBox (glTF)',
                    onPressed: cubit.loadAssetGltf,
                  ),
                  modelButton(
                    id: DemoModelId.boxTexturedUrl,
                    icon: Icons.cloud_download,
                    label: 'Load BoxTextured URL',
                    onPressed: cubit.loadRemoteGlb,
                  ),
                  modelButton(
                    id: DemoModelId.boxAnimatedUrl,
                    icon: Icons.cloud_queue,
                    label: 'Load BoxAnimated URL',
                    onPressed: cubit.loadRemoteBoxAnimated,
                  ),
                  modelButton(
                    id: DemoModelId.clearCoatCarPaintUrl,
                    icon: Icons.cloud_queue,
                    label: 'Load ClearCoatCarPaint URL',
                    onPressed: cubit.loadRemoteClearCoatCarPaint,
                  ),
                  modelButton(
                    id: DemoModelId.damagedHelmetUrl,
                    icon: Icons.cloud_queue,
                    label: 'Load DamagedHelmet URL',
                    onPressed: cubit.loadRemoteDamagedHelmet,
                  ),
                  modelButton(
                    id: DemoModelId.directionalLightUrl,
                    icon: Icons.cloud_queue,
                    label: 'Load DirectionalLight URL',
                    onPressed: cubit.loadRemoteDirectionalLight,
                  ),
                  modelButton(
                    id: DemoModelId.riggedFigureUrl,
                    icon: Icons.cloud_queue,
                    label: 'Load RiggedFigure URL',
                    onPressed: cubit.loadRemoteRiggedFigure,
                  ),
                  modelButton(
                    id: DemoModelId.metalRoughSpheresUrl,
                    icon: Icons.cloud_queue,
                    label: 'Load MetalRoughSpheres URL',
                    onPressed: cubit.loadRemoteMetalRoughSpheres,
                  ),
                  modelButton(
                    id: DemoModelId.localFile,
                    icon: Icons.folder_open,
                    label: 'Load Local Model',
                    onPressed: () => unawaited(pickLocalModel()),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Cache size: ${_formatBytes(state.cacheSizeBytes)}',
                style: const TextStyle(color: Color(0xFF4A4A4A)),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  TextButton(
                    onPressed: state.isLoading ? null : cubit.refreshCacheSize,
                    child: const Text('Refresh cache size'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: state.isLoading ? null : cubit.clearCache,
                    child: const Text('Clear cache'),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AnimationSection extends StatelessWidget {
  const _AnimationSection();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Animation',
      child: BlocBuilder<AnimationCubit, AnimationState>(
        builder: (context, state) {
          final cubit = context.read<AnimationCubit>();
          if (state.animationCount == 0) {
            return const Text('No animations detected in the current model.');
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: cubit.togglePlay,
                    icon: Icon(
                      state.isPlaying ? Icons.pause_circle : Icons.play_circle,
                      size: 36,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Loop'),
                      value: state.loop,
                      onChanged: cubit.setLoop,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Seek (${state.positionSeconds.toStringAsFixed(2)}s / ${state.durationSeconds.toStringAsFixed(2)}s)',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              Slider(
                value: state.positionSeconds.clamp(0.0, state.durationSeconds),
                max: state.durationSeconds == 0.0 ? 1.0 : state.durationSeconds,
                onChanged: (value) => cubit.seek(value),
              ),
              const SizedBox(height: 8),
              Text(
                'Speed ${state.speed.toStringAsFixed(2)}x',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              Slider(
                min: 0.25,
                max: 2.0,
                divisions: 7,
                value: state.speed,
                label: '${state.speed.toStringAsFixed(2)}x',
                onChanged: cubit.setSpeed,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Rendering Controls',
      child: BlocBuilder<SettingsCubit, SettingsState>(
        builder: (context, state) {
          final cubit = context.read<SettingsCubit>();
          return Column(
            children: [
              SwitchListTile.adaptive(
                title: const Text('Shadows'),
                value: state.shadowsEnabled,
                onChanged: cubit.setShadowsEnabled,
              ),
              SwitchListTile.adaptive(
                title: const Text('Environment (Skybox)'),
                value: state.environmentEnabled,
                onChanged: cubit.setEnvironmentEnabled,
              ),
              SwitchListTile.adaptive(
                title: const Text('Wireframe'),
                value: state.wireframeEnabled,
                onChanged: cubit.setWireframeEnabled,
              ),
              SwitchListTile.adaptive(
                title: const Text('Bounding boxes'),
                value: state.boundingBoxesEnabled,
                onChanged: cubit.setBoundingBoxesEnabled,
              ),
              SwitchListTile.adaptive(
                title: const Text('Debug logging'),
                value: state.debugLoggingEnabled,
                onChanged: cubit.setDebugLoggingEnabled,
              ),
              SwitchListTile.adaptive(
                title: const Text('FPS overlay'),
                value: state.fpsOverlayEnabled,
                onChanged: cubit.setFpsOverlayEnabled,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'MSAA',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('Off')),
                  ButtonSegment(value: 2, label: Text('2x')),
                  ButtonSegment(value: 4, label: Text('4x')),
                ],
                selected: {state.msaaSamples},
                onSelectionChanged: (selection) {
                  cubit.setMsaaSamples(selection.first);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5DED4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }
  return '${size.toStringAsFixed(1)} ${units[unitIndex]}';
}
