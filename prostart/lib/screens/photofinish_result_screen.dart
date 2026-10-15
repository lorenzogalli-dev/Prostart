import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../mock_data.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import '../widgets/result_widgets.dart';

/// Result of a photofinish run: gun to finish line.
class PhotofinishResultScreen extends StatelessWidget {
  /// Null: sample data, for `flutter run --dart-define=PAGE=photofinish`.
  final PhotofinishRun? run;
  const PhotofinishResultScreen({super.key, this.run});

  static Route<void> route(PhotofinishRun run) =>
      MaterialPageRoute(builder: (_) => PhotofinishResultScreen(run: run));

  @override
  Widget build(BuildContext context) {
    final r = run ??
        PhotofinishRun(
          when: DateTime(2026),
          totalSeconds: 4.312,
          reactionSeconds: 0.138,
          distanceM: 30,
          image: null,
          syncFloorUs: 30000,
        );
    final session = AppState.instance.photofinishes;
    final previous = session.where((p) => !identical(p, r) && p.distanceM == r.distanceM);
    final best = previous.isEmpty
        ? null
        : previous.map((p) => p.totalSeconds).reduce((a, b) => a < b ? a : b);
    final speed = r.distanceM / r.totalSeconds;
    return Scaffold(
      body: GlowBackground(
        primaryGlow: AppColors.cyan,
        secondaryGlow: AppColors.accent,
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
                title: 'Photofinish',
                subtitle: '${r.distanceM.toStringAsFixed(0)} m'
                    '${run == null ? ' · sample data' : ''}',
              ),
              const SizedBox(height: AppSpacing.xl),
              _TimeHero(run: r, isBest: best != null && r.totalSeconds < best),
              const SizedBox(height: AppSpacing.lg),
              if (r.image != null)
                _FrameCard(jpeg: r.image!)
              else
                const ImageCard(
                  asset: MockData.finishImage,
                  label: 'FINISH LINE',
                  icon: Icons.sports_score_rounded,
                  color: AppColors.cyan,
                  aspectRatio: MockData.finishAspectRatio,
                ),
              const SizedBox(height: AppSpacing.lg),
              InsightsCard(
                insights: [
                  if (best != null)
                    InsightRow(
                      icon: r.totalSeconds < best
                          ? Icons.emoji_events_rounded
                          : Icons.timer_outlined,
                      color: r.totalSeconds < best
                          ? AppColors.gold
                          : AppColors.textSecondary,
                      title: r.totalSeconds < best
                          ? 'Best run of the session'
                          : '${(r.totalSeconds - best).toStringAsFixed(2)} s '
                              'off your session best',
                      detail: 'Session best on ${r.distanceM.toStringAsFixed(0)} m: '
                          '${best.toStringAsFixed(2)} s',
                    ),
                  InsightRow(
                    icon: Icons.speed_rounded,
                    color: AppColors.cyan,
                    title: 'Average speed ${speed.toStringAsFixed(2)} m/s',
                    detail: '${(speed * 3.6).toStringAsFixed(1)} km/h '
                        'from gun to finish line',
                  ),
                  if (r.measuredFps > 0)
                    InsightRow(
                      icon: Icons.videocam_rounded,
                      color: AppColors.cyan,
                      title: '${r.measuredFps.toStringAsFixed(0)} fps measured '
                          'at the line',
                      detail: 'Frames ${r.frameGapMs.toStringAsFixed(1)} ms apart · '
                          '${r.timing == 'fit' ? 'line fit over ±160 ms' : r.timing} · '
                          '±${r.uncertaintyMs.toStringAsFixed(1)} ms',
                    ),
                  InsightRow(
                    icon: Icons.timer_outlined,
                    color: AppColors.textSecondary,
                    title: '${r.totalSeconds.toStringAsFixed(3)} s measured',
                    detail: 'Shown rounded up to the hundredth, as official '
                        'fully automatic times are',
                  ),
                  InsightRow(
                    icon: Icons.sync_rounded,
                    color: AppColors.textSecondary,
                    title: 'Clock sync within '
                        '±${(r.syncFloorUs / 2000).toStringAsFixed(0)} ms',
                    detail: 'Bound on the start-to-phone clock error',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimeHero extends StatelessWidget {
  final PhotofinishRun run;
  final bool isBest;
  const _TimeHero({required this.run, required this.isBest});

  @override
  Widget build(BuildContext context) {
    final rt = run.reactionSeconds;
    return GlassPanel(
      tint: AppColors.cyan,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Eyebrow('Total time'),
              const Spacer(),
              Tag(
                '${run.distanceM.toStringAsFixed(0)} m',
                icon: Icons.straighten_rounded,
                color: AppColors.cyan,
              ),
              if (isBest) ...[
                const SizedBox(width: 6),
                const Tag('SB', icon: Icons.star_rounded, color: AppColors.gold),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          HeroNumber(
            value: run.officialSeconds.toStringAsFixed(2),
            unit: 's',
            color: AppColors.textPrimary,
            size: 64,
          ),
          const SizedBox(height: AppSpacing.xl),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.12)),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: _Metric(
                  label: 'Reaction',
                  value: rt == null ? '–' : rt.toStringAsFixed(3),
                  unit: rt == null ? '' : 's',
                  color: AppColors.accent,
                ),
              ),
              Expanded(
                child: _Metric(
                  label: 'Run',
                  value: rt == null
                      ? '–'
                      : (run.totalSeconds - rt).toStringAsFixed(2),
                  unit: rt == null ? '' : 's',
                ),
              ),
              Expanded(
                child: _Metric(
                  label: 'Avg speed',
                  value: (run.distanceM / run.totalSeconds).toStringAsFixed(2),
                  unit: 'm/s',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The crossing frame, as the camera saw it, with the line and the torso.
class _FrameCard extends StatelessWidget {
  final Uint8List jpeg;
  const _FrameCard({required this.jpeg});

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      tint: AppColors.cyan,
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 6, 8, 10),
            child: Eyebrow('FINISH LINE', color: AppColors.cyan),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Image.memory(
              jpeg,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color color;

  const _Metric({
    required this.label,
    required this.value,
    required this.unit,
    this.color = AppColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Eyebrow(label),
        const SizedBox(height: 6),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: value,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
              TextSpan(
                text: ' $unit',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          style: const TextStyle(fontFeatures: tabular),
        ),
      ],
    );
  }
}
