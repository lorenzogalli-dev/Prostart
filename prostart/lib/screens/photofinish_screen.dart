import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'package:photofinish_camera/photofinish_camera.dart';
import '../start_unit/protocol.dart';
import '../start_unit/simulated_start_unit.dart';
import '../start_unit/start_unit.dart';
import '../theme/app_theme.dart';
import '../widgets/device_card.dart';
import '../widgets/finish_line_overlay.dart';
import '../widgets/glass.dart';
import 'photofinish_result_screen.dart';
import 'video_analysis_screen.dart';

/// Photofinish mode. The phone stands upright at the finish, the camera runs
/// at the highest frame rate it has, and the red line is dragged onto the
/// finish line. The start unit runs the start; at its "go" the camera starts
/// buffering and the torso crossing is timed against the go instant, both on
/// this phone's clock through the BLE clock sync.
class PhotofinishScreen extends StatefulWidget {
  const PhotofinishScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const PhotofinishScreen());

  @override
  State<PhotofinishScreen> createState() => _PhotofinishScreenState();
}

enum _Stage { starting, ready, timing, analysing, failed }

class _PhotofinishScreenState extends State<PhotofinishScreen> {
  final _camera = PhotofinishCamera();
  CameraInfo? _info;
  String? _error;
  _Stage _stage = _Stage.starting;
  String? _note;

  // The line, normalised to the portrait image (0..1, origin top-left).
  Offset _a = const Offset(0.5, 0.15);
  Offset _b = const Offset(0.5, 0.85);

  StartUnit? _unit;
  StreamSubscription<StartEvent>? _eventsSub;

  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_onAppState);
    _onAppState();
    if (PhotofinishCamera.supported) _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      final info = await _camera.start();
      await _camera.setLine(_a, _b);
      if (!mounted) return;
      setState(() {
        _info = info;
        _stage = _Stage.ready;
      });
    } on PlatformException catch (e) {
      setState(() {
        _error = e.message ?? 'Camera unavailable';
        _stage = _Stage.failed;
      });
    }
  }

  void _onAppState() {
    final unit = AppState.instance.unit;
    if (identical(unit, _unit)) return;
    _eventsSub?.cancel();
    _unit = unit;
    _eventsSub = unit.events.listen(_onEvent);
  }

  void _onEvent(StartEvent e) {
    if (e is GoEvent) _onGo(e);
    if (e is AbortEvent && _stage == _Stage.timing) {
      _camera.disarm();
      setState(() => _stage = _Stage.ready);
    }
  }

  Future<void> _onGo(GoEvent go) async {
    if (_stage != _Stage.ready) return;
    final unit = _unit!;
    final goPhoneUs = unit.sync.toPhoneUs(go.boardUs);
    if (goPhoneUs == null) {
      setState(() => _note = 'No clock sync with the start unit: run not timed');
      return;
    }
    final syncFloor = unit.sync.estimate!.roundTripFloorUs;
    HapticFeedback.heavyImpact();
    setState(() {
      _stage = _Stage.timing;
      _note = null;
    });
    final sub = _camera.status.listen((s) {
      if (s == 'analysing' && mounted) {
        setState(() => _stage = _Stage.analysing);
      }
    });
    try {
      final c = await _camera.arm(goPhoneUs);
      final total = (c.crossPhoneUs - goPhoneUs) / 1e6;
      final result = unit.lastResult;
      final run = PhotofinishRun(
        when: DateTime.now(),
        totalSeconds: total,
        reactionSeconds: result != null &&
                result.goBoardUs == go.boardUs &&
                result.verdict == Verdict.valid
            ? result.reactionSeconds
            : null,
        distanceM: AppState.instance.distanceM,
        image: c.jpeg,
        syncFloorUs: syncFloor,
        measuredFps: c.measuredFps,
        frameGapMs: c.frameGapMs,
        timing: c.timing,
        uncertaintyMs: c.uncertaintyMs,
      );
      AppState.instance.addPhotofinish(run);
      if (!mounted) return;
      setState(() => _stage = _Stage.ready);
      await Navigator.of(context).push(PhotofinishResultScreen.route(run));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.ready;
        _note = e == 'timeout'
            ? 'Nobody crossed the line within 30 s of "go"'
            : e is String && e != 'stopped' && e != 'cancelled'
                ? e
                : null;
      });
    } finally {
      await sub.cancel();
    }
  }

  void _moveLine(Offset a, Offset b) {
    setState(() {
      _a = a;
      _b = b;
    });
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onAppState);
    _eventsSub?.cancel();
    _camera.stop();
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: GlassHeader(
                title: 'Photofinish',
                subtitle: _info == null
                    ? 'Starting camera…'
                    : '${_info!.fps.toStringAsFixed(0)} fps · '
                        'exposure 1/${(1e6 / _info!.exposureUs).round()} s',
              ),
            ),
            Expanded(child: Center(child: _cameraBox())),
            _BottomBar(stage: _stage, note: _note),
          ],
        ),
      ),
    );
  }

  Widget _cameraBox() {
    if (!PhotofinishCamera.supported) {
      return const _Message('The photofinish camera runs on iPhone for now.');
    }
    if (_error != null) return _Message(_error!);
    final info = _info;
    if (info == null) {
      return const CircularProgressIndicator(color: AppColors.cyan);
    }
    return AspectRatio(
      aspectRatio: info.width / info.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const UiKitView(viewType: PhotofinishCamera.previewViewType),
            FinishLineOverlay(
              a: _a,
              b: _b,
              locked: _stage != _Stage.ready,
              onChanged: _moveLine,
              onDone: () => _camera.setLine(_a, _b),
            ),
            if (_stage == _Stage.timing || _stage == _Stage.analysing)
              _StageBadge(
                text: _stage == _Stage.timing ? 'Timing… run!' : 'Analysing…',
              ),
          ],
        ),
      ),
    );
  }
}

class _StageBadge extends StatelessWidget {
  final String text;
  const _StageBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: const Alignment(0, -0.85),
      child: GlassPanel(
        borderRadius: AppRadius.pill,
        tint: AppColors.cyan,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Text(
          text,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  const _Message(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.xl),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(color: AppColors.textSecondary),
    ),
  );
}

/// Board state, distance, and the demo button.
class _BottomBar extends StatelessWidget {
  final _Stage stage;
  final String? note;
  const _BottomBar({required this.stage, required this.note});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppState.instance,
      builder: (context, _) {
        final app = AppState.instance;
        final unit = app.unit;
        final connected = unit.link == LinkState.connected;
        final phaseText = !connected
            ? 'Start unit not connected'
            : switch (unit.phase) {
                StartPhase.countdown => 'Countdown ${unit.countdownDigit}',
                StartPhase.marks => 'On your marks',
                StartPhase.set => 'Set',
                StartPhase.go => 'GO',
                StartPhase.result => 'Start judged',
                StartPhase.off => 'Start unit off',
                _ => 'Waiting for the start',
              };
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (note != null) ...[
                Text(
                  note!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.gold),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: connected ? null : () => showConnectSheet(context),
                      child: GlassPanel(
                        borderRadius: AppRadius.pill,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.bluetooth_rounded,
                              size: 18,
                              color: connected
                                  ? AppColors.success
                                  : AppColors.textFaint,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                phaseText,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  _DistanceStepper(app: app, enabled: stage == _Stage.ready),
                ],
              ),
              TextButton.icon(
                onPressed: stage == _Stage.ready || stage == _Stage.failed
                    ? () => Navigator.of(context).push(VideoAnalysisScreen.route())
                    : null,
                icon: const Icon(Icons.video_library_rounded, size: 18),
                label: const Text('Analyse a recorded video'),
              ),
              if (unit is SimulatedStartUnit &&
                  connected &&
                  stage == _Stage.ready &&
                  (unit.phase == StartPhase.ready ||
                      unit.phase == StartPhase.result)) ...[
                const SizedBox(height: AppSpacing.sm),
                TextButton.icon(
                  onPressed: unit.pressButton,
                  icon: const Icon(Icons.radio_button_checked_rounded),
                  label: const Text('Start the demo sequence'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DistanceStepper extends StatelessWidget {
  final AppState app;
  final bool enabled;
  const _DistanceStepper({required this.app, required this.enabled});

  static const _steps = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 100.0];

  @override
  Widget build(BuildContext context) {
    void step(int dir) {
      final i = _steps.indexOf(app.distanceM);
      final next = (i < 0 ? 2 : i) + dir;
      if (next < 0 || next >= _steps.length) return;
      app.setDistance(_steps[next]);
    }

    return GlassPanel(
      borderRadius: AppRadius.pill,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          IconButton(
            onPressed: enabled ? () => step(-1) : null,
            icon: const Icon(Icons.remove_rounded, size: 18),
          ),
          Text(
            '${app.distanceM.toStringAsFixed(0)} m',
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontFeatures: tabular,
            ),
          ),
          IconButton(
            onPressed: enabled ? () => step(1) : null,
            icon: const Icon(Icons.add_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}
