import 'package:flutter/material.dart';

import '../app_state.dart';
import '../start_unit/protocol.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import '../widgets/result_widgets.dart';

/// Seconds the way a start is reported: 0.138, -0.045.
String formatSeconds(double s) => s.toStringAsFixed(3);

/// One start's result and how it compares with this session. Embedded in the
/// live reaction screen; [ReactionResultScreen] wraps it for screenshots.
class ReactionResultView extends StatelessWidget {
  final ReactionRun run;
  final List<ReactionRun> session;

  const ReactionResultView({
    super.key,
    required this.run,
    required this.session,
  });

  @override
  Widget build(BuildContext context) {
    final valid = session
        .where((r) => r.result.verdict == Verdict.valid)
        .map((r) => r.result.reactionSeconds)
        .toList();
    final recent = valid.length > 8 ? valid.sublist(valid.length - 8) : valid;
    final avg = valid.isEmpty
        ? 0.0
        : valid.reduce((a, b) => a + b) / valid.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReactionHero(result: run.result),
        if (recent.length >= 2) ...[
          const SizedBox(height: AppSpacing.lg),
          RecentStartsChart(values: recent, average: avg),
        ],
        const SizedBox(height: AppSpacing.lg),
        InsightsCard(insights: _insights(run.result, valid, avg)),
      ],
    );
  }

  static List<InsightRow> _insights(
    ResultEvent r,
    List<double> valid,
    double avg,
  ) {
    final rt = r.reactionSeconds;
    switch (r.verdict) {
      case Verdict.falseStart:
        return [
          InsightRow(
            icon: Icons.front_hand_rounded,
            color: const Color(0xFFFF6B5C),
            title: rt < 0 ? 'Moved before the gun' : 'Too fast to be a reaction',
            detail: rt < 0
                ? 'Movement ${formatSeconds(-rt)} s before "go"'
                : 'Under 0.100 s after "go" counts as a false start',
          ),
        ];
      case Verdict.noMovement:
        return const [
          InsightRow(
            icon: Icons.hourglass_empty_rounded,
            color: AppColors.gold,
            title: 'No start detected',
            detail: 'The block did not move within a second of "go"',
          ),
        ];
      case Verdict.unusable:
        return const [
          InsightRow(
            icon: Icons.error_outline_rounded,
            color: Color(0xFFFF6B5C),
            title: 'This start could not be judged',
            detail: 'The block was moving when "set" was given. Try again.',
          ),
        ];
      case Verdict.valid:
        final best = valid.reduce((a, b) => a < b ? a : b);
        return [
          if (valid.length >= 2)
            InsightRow(
              icon: rt <= avg
                  ? Icons.trending_down_rounded
                  : Icons.trending_up_rounded,
              color: rt <= avg ? AppColors.success : AppColors.gold,
              title: rt <= avg
                  ? '${formatSeconds(avg - rt)} s faster than your average'
                  : '${formatSeconds(rt - avg)} s slower than your average',
              detail: 'Session average ${formatSeconds(avg)} s over '
                  '${valid.length} starts',
            ),
          if (valid.length >= 2 && rt == best)
            const InsightRow(
              icon: Icons.emoji_events_rounded,
              color: AppColors.gold,
              title: 'Best start of the session',
              detail: 'Fastest legal reaction so far today',
            ),
          const InsightRow(
            icon: Icons.verified_rounded,
            color: AppColors.cyan,
            title: 'Clean set position',
            detail: 'No movement detected before the gun',
          ),
        ];
    }
  }
}

class _ReactionHero extends StatelessWidget {
  final ResultEvent result;
  const _ReactionHero({required this.result});

  @override
  Widget build(BuildContext context) {
    final rt = result.reactionSeconds;
    final (tag, tagColor, tagIcon) = switch (result.verdict) {
      Verdict.valid => ('Legal start', AppColors.success, Icons.check_rounded),
      Verdict.falseStart => (
        'False start',
        const Color(0xFFFF6B5C),
        Icons.close_rounded,
      ),
      Verdict.noMovement => ('No start', AppColors.gold, Icons.remove_rounded),
      Verdict.unusable => (
        'Not judged',
        const Color(0xFFFF6B5C),
        Icons.error_outline_rounded,
      ),
    };
    final showTime = result.verdict == Verdict.valid ||
        result.verdict == Verdict.falseStart;
    return GlassPanel(
      tint: result.verdict == Verdict.valid
          ? AppColors.accent
          : const Color(0xFFFF6B5C),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Eyebrow('Reaction time'),
              const Spacer(),
              Tag(tag, icon: tagIcon, color: tagColor),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          HeroNumber(
            value: showTime ? formatSeconds(rt) : '—',
            unit: showTime ? 's' : '',
            color: result.verdict == Verdict.valid
                ? AppColors.accent
                : const Color(0xFFFF6B5C),
            size: 72,
          ),
          if (result.verdict == Verdict.valid) ...[
            const SizedBox(height: AppSpacing.lg),
            _GaugeBar(value: rt),
            const SizedBox(height: 6),
            const Row(
              children: [
                Text('0.100', style: _gaugeLabel),
                Spacer(),
                Text('elite  < 0.130', style: _gaugeLabel),
                Spacer(),
                Text('0.200', style: _gaugeLabel),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static const _gaugeLabel = TextStyle(
    fontSize: 11,
    color: AppColors.textFaint,
    fontFeatures: tabular,
  );
}

/// Where this reaction sits between the false-start limit and a slow start.
class _GaugeBar extends StatelessWidget {
  final double value;
  const _GaugeBar({required this.value});

  @override
  Widget build(BuildContext context) {
    const lo = 0.100, hi = 0.200;
    final t = ((value - lo) / (hi - lo)).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, c) {
        return SizedBox(
          height: 18,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerLeft,
            children: [
              Container(
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  gradient: const LinearGradient(
                    colors: [
                      AppColors.accent,
                      AppColors.gold,
                      Color(0xFFFF6B5C),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: c.maxWidth * t - 9,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border: Border.all(color: AppColors.background, width: 3),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Standalone, with sample data: `flutter run --dart-define=PAGE=reaction`.
class ReactionResultScreen extends StatelessWidget {
  const ReactionResultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final session = [
      for (final (i, us) in [162000, 155000, 149000, 171000, 144000, 138000].indexed)
        ReactionRun(
          now,
          ResultEvent(
            i,
            verdict: Verdict.valid,
            reactionUs: us,
            onsetBoardUs: 0,
            goBoardUs: 0,
          ),
        ),
    ];
    return Scaffold(
      body: GlowBackground(
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
              const GlassHeader(title: 'Reaction Time', subtitle: 'Sample data'),
              const SizedBox(height: AppSpacing.xl),
              ReactionResultView(run: session.last, session: session),
            ],
          ),
        ),
      ),
    );
  }
}
