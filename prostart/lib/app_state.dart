import 'package:flutter/foundation.dart';

import 'start_unit/ble_start_unit.dart';
import 'start_unit/protocol.dart';
import 'start_unit/simulated_start_unit.dart';
import 'start_unit/start_unit.dart';

/// One finished photofinish run.
class PhotofinishRun {
  final DateTime when;
  final double totalSeconds;
  final double? reactionSeconds;
  final double distanceM;

  /// JPEG of the crossing frame, line and torso drawn in.
  final Uint8List? image;

  /// The sync's uncertainty bound when the time was taken.
  final int syncFloorUs;

  /// Frames per second really delivered around the line, and the gap between
  /// the two frames the crossing was interpolated in.
  final double measuredFps;
  final double frameGapMs;

  /// judge.py's method ("fit", "interpolated", "frame") and uncertainty.
  final String timing;
  final double uncertaintyMs;

  const PhotofinishRun({
    required this.when,
    required this.totalSeconds,
    required this.reactionSeconds,
    required this.distanceM,
    required this.image,
    required this.syncFloorUs,
    this.measuredFps = 0,
    this.frameGapMs = 0,
    this.timing = '',
    this.uncertaintyMs = 0,
  });

  /// World Athletics TR 19 (judge.official_hundredths): fully automatic
  /// times are rounded UP to the next hundredth.
  double get officialSeconds => (((totalSeconds * 1e4).round()) / 100).ceil() / 100;
}

class ReactionRun {
  final DateTime when;
  final ResultEvent result;
  const ReactionRun(this.when, this.result);
}

/// App-wide state: which start unit is in use and this session's runs. Kept
/// in memory only; nothing is stored between launches yet.
class AppState extends ChangeNotifier {
  AppState._();
  static final instance = AppState._();

  StartUnit _unit = BleStartUnit();
  StartUnit get unit => _unit;

  final reactions = <ReactionRun>[];
  final photofinishes = <PhotofinishRun>[];

  /// Race distance for the photofinish, set on its screen.
  double distanceM = 30;

  void setDistance(double m) {
    distanceM = m;
    notifyListeners();
  }

  Future<void> useDevice() => _switchTo(BleStartUnit());
  Future<void> useSimulator() => _switchTo(SimulatedStartUnit());

  Future<void> _switchTo(StartUnit next) async {
    await _unit.disconnect();
    _unit.removeListener(notifyListeners);
    _unit.dispose();
    _unit = next..addListener(notifyListeners);
    _listenForResults();
    notifyListeners();
    await next.connect();
  }

  void _listenForResults() {
    _unit.events.listen((e) {
      if (e is ResultEvent) {
        reactions.add(ReactionRun(DateTime.now(), e));
        notifyListeners();
      }
    });
  }

  void addPhotofinish(PhotofinishRun run) {
    photofinishes.add(run);
    notifyListeners();
  }

  void init() {
    _unit.addListener(notifyListeners);
    _listenForResults();
  }
}
