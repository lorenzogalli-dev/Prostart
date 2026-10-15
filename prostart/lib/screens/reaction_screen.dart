import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../start_unit/simulated_start_unit.dart';
import '../start_unit/start_unit.dart';
import '../theme/app_theme.dart';
import '../widgets/device_card.dart';
import '../widgets/glass.dart';
import 'reaction_result_screen.dart';

/// Reaction-time mode. The board runs the whole start - button, beeps,
/// judging - and this screen only mirrors it, larger and nicer than the
/// board's display, then shows the result the board sent.
class ReactionScreen extends StatelessWidget {
  const ReactionScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const ReactionScreen());

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Scaffold(
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final unit = app.unit;
          final phase = unit.link == LinkState.connected
              ? unit.phase
              : StartPhase.unknown;
          final showResult = phase == StartPhase.result &&
              app.reactions.isNotEmpty;
          return GlowBackground(
            primaryGlow: _glowFor(phase),
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
                  const GlassHeader(
                    title: 'Reaction Time',
                    subtitle: 'Mirrors your ProStart',
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  if (unit.link != LinkState.connected)
                    const _NotConnected()
                  else if (showResult) ...[
                    ReactionResultView(
                      run: app.reactions.last,
                      session: app.reactions,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    _NextStartHint(unit: unit),
                  ] else
                    _LiveStage(unit: unit, phase: phase),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static Color _glowFor(StartPhase p) => switch (p) {
    StartPhase.set => AppColors.gold,
    StartPhase.go => AppColors.accent,
    StartPhase.marks => AppColors.cyan,
    _ => AppColors.accent,
  };
}

/// Shown until the start unit is connected: one centred card, one action.
class _NotConnected extends StatelessWidget {
  const _NotConnected();

  @override
  Widget build(BuildContext context) {
    final unit = AppState.instance.unit;
    final busy = unit.link == LinkState.scanning ||
        unit.link == LinkState.connecting;
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: GlassPanel(
        tint: AppColors.bluetooth,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xxl,
          40,
          AppSpacing.xxl,
          AppSpacing.xxl,
        ),
        child: Column(
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF5B9BFF), AppColors.bluetooth],
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.bluetooth.withValues(alpha: 0.55),
                    blurRadius: 32,
                  ),
                ],
              ),
              child: const Icon(
                Icons.bluetooth_rounded,
                size: 48,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            const Text(
              'Connect your ProStart',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              unit.error ??
                  'The start unit runs the start. Connect it to follow '
                      'every step here, live.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                height: 1.35,
                color: unit.error != null
                    ? AppColors.gold
                    : AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            GestureDetector(
              onTap: busy ? null : () => showConnectSheet(context),
              child: Container(
                height: 58,
                width: double.infinity,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.bluetooth,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.bluetooth.withValues(alpha: 0.45),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Text(
                  busy ? 'Connecting…' : 'Connect',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The big centre of the screen: one state at a time, animated in.
class _LiveStage extends StatelessWidget {
  final StartUnit unit;
  final StartPhase phase;
  const _LiveStage({required this.unit, required this.phase});

  @override
  Widget build(BuildContext context) {
    final (Widget big, String hint, Color color) = switch (phase) {
      StartPhase.countdown => (
        Text(
          '${unit.countdownDigit ?? ''}',
          style: _big(150, AppColors.textPrimary),
        ),
        'Get to the blocks',
        AppColors.textPrimary,
      ),
      StartPhase.marks => (
        Text(
          'On your\nmarks',
          textAlign: TextAlign.center,
          style: _big(58, AppColors.cyan),
        ),
        'Settle in. "Set" comes in 20-25 seconds',
        AppColors.cyan,
      ),
      StartPhase.set => (
        Text('Set', style: _big(110, AppColors.gold)),
        'Hold still',
        AppColors.gold,
      ),
      StartPhase.go || StartPhase.result => (
        Text('GO', style: _big(130, AppColors.accent)),
        'Judging the start…',
        AppColors.accent,
      ),
      StartPhase.off => (
        Text('Off', style: _big(80, AppColors.textFaint)),
        'The start unit was switched off',
        AppColors.textFaint,
      ),
      _ => (
        Text('Ready', style: _big(80, AppColors.accent)),
        'Press the button on the start unit to begin',
        AppColors.accent,
      ),
    };
    if (phase == StartPhase.go) HapticFeedback.heavyImpact();
    return Column(
      children: [
        GlassPanel(
          tint: color,
          child: SizedBox(
            height: 380,
            width: double.infinity,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, anim) => ScaleTransition(
                  scale: Tween(begin: 0.85, end: 1.0).animate(
                    CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
                  ),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: KeyedSubtree(
                  key: ValueKey('${phase.name}${unit.countdownDigit}'),
                  child: big,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          hint,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, color: AppColors.textSecondary),
        ),
        if (unit is SimulatedStartUnit &&
            (phase == StartPhase.ready || phase == StartPhase.unknown)) ...[
          const SizedBox(height: AppSpacing.xl),
          _SimButton(unit: unit as SimulatedStartUnit),
        ],
      ],
    );
  }

  static TextStyle _big(double size, Color color) => TextStyle(
    fontSize: size,
    height: 1.0,
    fontWeight: FontWeight.w900,
    letterSpacing: -2,
    color: color,
    fontFeatures: tabular,
    shadows: [Shadow(color: color.withValues(alpha: 0.5), blurRadius: 30)],
  );
}

class _NextStartHint extends StatelessWidget {
  final StartUnit unit;
  const _NextStartHint({required this.unit});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text(
          'Press the button on the start unit for the next start',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary),
        ),
        if (unit is SimulatedStartUnit) ...[
          const SizedBox(height: AppSpacing.lg),
          _SimButton(unit: unit as SimulatedStartUnit),
        ],
      ],
    );
  }
}

/// The demo unit has no physical button: this is it.
class _SimButton extends StatelessWidget {
  final SimulatedStartUnit unit;
  const _SimButton({required this.unit});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: unit.pressButton,
      child: GlassPanel(
        borderRadius: AppRadius.pill,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.radio_button_checked_rounded, color: AppColors.accent),
            SizedBox(width: 8),
            Text(
              'Press the demo button',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}
