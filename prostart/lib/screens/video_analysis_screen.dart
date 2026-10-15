import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photofinish_camera/photofinish_camera.dart';

import '../theme/app_theme.dart';
import '../widgets/finish_line_overlay.dart';
import '../widgets/glass.dart';
import '../widgets/result_widgets.dart';

/// A recorded race through the same detection as the live photofinish, run
/// the way the colleagues' detect.py runs it - so the app and the Python can
/// be compared on the same file. Times are from the start of the video, as
/// detect.py prints them with --start 0. Portrait or landscape.
class VideoAnalysisScreen extends StatefulWidget {
  const VideoAnalysisScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const VideoAnalysisScreen());

  @override
  State<VideoAnalysisScreen> createState() => _VideoAnalysisScreenState();
}

class _VideoAnalysisScreenState extends State<VideoAnalysisScreen> {
  VideoInfo? _video;
  Offset _a = const Offset(0.5, 0.2);
  Offset _b = const Offset(0.5, 0.8);
  bool _busy = false;
  String? _error;
  VideoAnalysis? _result;

  Future<void> _pick() async {
    setState(() => _error = null);
    try {
      final v = await PhotofinishCamera.pickVideo();
      if (v == null || !mounted) return;
      setState(() {
        _video = v;
        _result = null;
        _a = const Offset(0.5, 0.2);
        _b = const Offset(0.5, 0.8);
      });
    } on PlatformException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _analyse() async {
    final v = _video;
    if (v == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final r = await PhotofinishCamera.analyzeVideo(v, _a, _b);
      if (mounted) setState(() => _result = r);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return Scaffold(
      body: GlowBackground(
        primaryGlow: AppColors.cyan,
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              AppSpacing.md,
              AppSpacing.xl,
              48,
            ),
            children: [
              GlassHeader(
                title: 'Analyse a video',
                subtitle: v == null
                    ? 'Same detection as the colleagues\' detect.py'
                    : '${v.width}×${v.height} · ${v.fps.toStringAsFixed(0)} fps · '
                        '${v.durationS.toStringAsFixed(1)} s',
              ),
              const SizedBox(height: AppSpacing.xl),
              if (v == null)
                _PickCard(onPick: _pick)
              else ...[
                _preview(v),
                const SizedBox(height: AppSpacing.md),
                const Text(
                  'Drag the two points onto the finish line. Camera off to the '
                  'side, not tilted? Keep it vertical, where the feet land.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.lg),
                _controls(),
              ],
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(_error!, style: const TextStyle(color: AppColors.gold)),
              ],
              if (_result != null) ...[
                const SizedBox(height: AppSpacing.lg),
                _ResultCard(r: _result!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _preview(VideoInfo v) {
    // Landscape videos fill the width; portrait ones are kept to a height
    // that fits the screen.
    final maxH = MediaQuery.of(context).size.height * 0.55;
    final aspect = v.width / v.height;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH, maxWidth: maxH * aspect),
        child: AspectRatio(
          aspectRatio: aspect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(v.preview, fit: BoxFit.fill, gaplessPlayback: true),
                FinishLineOverlay(
                  a: _a,
                  b: _b,
                  locked: _busy,
                  onChanged: (a, b) => setState(() {
                    _a = a;
                    _b = b;
                  }),
                  onDone: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.video_library_rounded),
                label: const Text('Other video'),
              ),
            ),
            Expanded(
              flex: 2,
              child: GestureDetector(
                onTap: _busy ? null : _analyse,
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _busy ? Colors.white24 : AppColors.cyan,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Analyse',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: AppColors.onAccent,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PickCard extends StatelessWidget {
  final VoidCallback onPick;
  const _PickCard({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPick,
      child: GlassPanel(
        tint: AppColors.cyan,
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: const Column(
          children: [
            Icon(Icons.video_library_rounded, size: 56, color: AppColors.cyan),
            SizedBox(height: AppSpacing.lg),
            Text(
              'Choose a race video',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 6),
            Text(
              'Side-on, portrait or landscape. Slow-motion clips keep their '
              'full frame rate.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final VideoAnalysis r;
  const _ResultCard({required this.r});

  @override
  Widget build(BuildContext context) {
    // judge.official_hundredths: rounded UP to the hundredth.
    final official = ((r.timeS * 1e4).round() / 100).ceil() / 100;
    TextStyle mono(double size, [Color? c]) => TextStyle(
      fontSize: size,
      fontWeight: FontWeight.w800,
      color: c,
      fontFeatures: tabular,
    );
    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(k, style: const TextStyle(color: AppColors.textSecondary)),
          const Spacer(),
          Text(v, style: mono(14)),
        ],
      ),
    );
    return GlassPanel(
      tint: AppColors.cyan,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Eyebrow('Torso crossing, from the start of the video'),
          const SizedBox(height: AppSpacing.md),
          Text('${r.timeS.toStringAsFixed(3)} s', style: mono(44)),
          Text(
            'official ${official.toStringAsFixed(2)} s (rounded up)',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          row('interpolated', '${r.interpolatedS.toStringAsFixed(3)} s'),
          row('first frame past line', '${r.firstFrameS.toStringAsFixed(3)} s'),
          row('timing', '${r.timing} · ±${r.uncertaintyMs.toStringAsFixed(1)} ms'),
          row('runs', '${r.rightward ? 'left → right' : 'right → left'} (detected)'),
          row('frames with a torso', '${r.detections}/${r.frames}'),
          row('chest front from silhouette', '${r.silhouette}/${r.detections}'),
          row('frame rate', '${r.fps.toStringAsFixed(0)} fps'),
          const SizedBox(height: AppSpacing.lg),
          if (r.jpeg.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Image.memory(r.jpeg, fit: BoxFit.contain),
            ),
        ],
      ),
    );
  }
}
