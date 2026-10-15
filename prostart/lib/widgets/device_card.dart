import 'package:flutter/material.dart';

import '../app_state.dart';
import '../start_unit/start_unit.dart';
import '../theme/app_theme.dart';
import 'glass.dart';

/// The start unit's link, live. Tap: connect / switch / disconnect.
class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppState.instance,
      builder: (context, _) {
        final unit = AppState.instance.unit;
        final (status, color) = switch (unit.link) {
          LinkState.connected => ('Connected', AppColors.success),
          LinkState.scanning => ('Searching…', AppColors.gold),
          LinkState.connecting => ('Connecting…', AppColors.gold),
          LinkState.disconnected => (
            unit.error ?? 'Tap to connect',
            AppColors.textFaint,
          ),
        };
        final busy = unit.link == LinkState.scanning ||
            unit.link == LinkState.connecting;
        return GestureDetector(
          onTap: () => showConnectSheet(context),
          child: GlassPanel(
            tint: AppColors.bluetooth,
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                _BluetoothBadge(active: unit.link == LinkState.connected),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        unit.link == LinkState.disconnected && unit.error == null
                            ? 'ProStart'
                            : unit.name,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (busy)
                            const SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                                color: AppColors.gold,
                              ),
                            )
                          else
                            _Dot(color: color),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              status,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: color,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (unit.link == LinkState.connected) _SyncChip(unit: unit),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BluetoothBadge extends StatelessWidget {
  final bool active;
  const _BluetoothBadge({required this.active});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: AppMotion.normal,
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: active
              ? const [Color(0xFF5B9BFF), AppColors.bluetooth]
              : [Colors.white24, Colors.white10],
        ),
        boxShadow: [
          if (active)
            BoxShadow(
              color: AppColors.bluetooth.withValues(alpha: 0.5),
              blurRadius: 18,
            ),
        ],
      ),
      child: const Icon(Icons.bluetooth_rounded, color: Colors.white),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.8), blurRadius: 6),
        ],
      ),
    );
  }
}

/// Clock sync quality: the round-trip floor bounds the offset's error.
class _SyncChip extends StatelessWidget {
  final StartUnit unit;
  const _SyncChip({required this.unit});

  @override
  Widget build(BuildContext context) {
    final e = unit.sync.estimate;
    final text = e == null
        ? 'sync…'
        : '±${(e.roundTripFloorUs / 2000).toStringAsFixed(0)} ms';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        children: [
          const Icon(Icons.sync_rounded, size: 15, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
              fontFeatures: tabular,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showConnectSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ConnectSheet(),
  );
}

class _ConnectSheet extends StatelessWidget {
  const _ConnectSheet();

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final unit = app.unit;
        final connected = unit.link == LinkState.connected;
        final busy = unit.link == LinkState.scanning ||
            unit.link == LinkState.connecting;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: GlassPanel(
              strength: 1.4,
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    connected ? unit.name : 'Connect your ProStart',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    connected
                        ? (unit.isSimulated
                            ? 'Demo device: the start sequence is simulated on '
                                'this phone. The camera and timing are real.'
                            : 'The start unit runs the start; this phone mirrors '
                                'it and times the finish.')
                        : 'Switch the start unit on and keep it within a few '
                            'metres while connecting.',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  if (!connected)
                    _SheetButton(
                      label: busy ? 'Connecting…' : 'Connect',
                      color: AppColors.bluetooth,
                      onTap: busy ? null : app.useDevice,
                    )
                  else
                    _SheetButton(
                      label: 'Disconnect',
                      color: Colors.white24,
                      onTap: unit.disconnect,
                    ),
                  if (!connected && !busy) ...[
                    const SizedBox(height: AppSpacing.md),
                    TextButton(
                      onPressed: app.useSimulator,
                      child: const Text(
                        'No device? Use the demo start unit',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SheetButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback? onTap;
  const _SheetButton({required this.label, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: AppMotion.normal,
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          height: 54,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
