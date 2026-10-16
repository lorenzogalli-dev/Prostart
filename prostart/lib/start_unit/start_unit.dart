import 'dart:async';

import 'package:flutter/foundation.dart';

import 'clock_sync.dart';
import 'protocol.dart';
import 'run_recording.dart';

enum LinkState { disconnected, scanning, connecting, connected }

/// Where the start is, as the board last said. The app only mirrors this.
enum StartPhase { unknown, ready, countdown, marks, set, go, result, off }

/// The last start's recording on its way from the board (v6: the board keeps
/// nothing; the phone is where runs are saved).
enum RecordingState { none, receiving, received, failed }

/// The start unit as the app sees it: a link state, the board's events, and
/// the clock sync. Two implementations: BleStartUnit (the real board) and
/// SimulatedStartUnit (no hardware, for developing and demoing the app).
abstract class StartUnit extends ChangeNotifier {
  LinkState _link = LinkState.disconnected;
  LinkState get link => _link;

  /// Why the last connect failed, for the UI. Cleared on the next attempt.
  String? error;

  String get name;
  bool get isSimulated;

  final sync = ClockSync();

  StartEvent? _lastEvent;
  StartEvent? get lastEvent => _lastEvent;

  /// The last "go", once per start. Kept so screens opened late still see it.
  GoEvent? lastGo;
  ResultEvent? lastResult;

  final _events = StreamController<StartEvent>.broadcast();
  Stream<StartEvent> get events => _events.stream;

  RecordingState recordingState = RecordingState.none;
  final _recordings = StreamController<RunRecording>.broadcast();

  /// Each complete recording, once. Whoever saves it calls [ackRecording].
  Stream<RunRecording> get recordings => _recordings.stream;

  /// Tells the board the run is safely stored, so it may let it go.
  Future<void> ackRecording(RunRecording r) async {}

  StartPhase get phase => switch (_lastEvent) {
    null => StartPhase.unknown,
    ReadyEvent() => StartPhase.ready,
    CountdownEvent() => StartPhase.countdown,
    MarksEvent() => StartPhase.marks,
    SetEvent() => StartPhase.set,
    GoEvent() => StartPhase.go,
    ResultEvent() => StartPhase.result,
    AbortEvent() => StartPhase.ready,
    OffEvent() => StartPhase.off,
  };

  int? get countdownDigit => switch (_lastEvent) {
    CountdownEvent(:final digit) => digit,
    _ => null,
  };

  Future<void> connect();
  Future<void> disconnect();

  @protected
  void setLink(LinkState s) {
    if (_link == s) return;
    _link = s;
    if (s == LinkState.disconnected) sync.reset();
    notifyListeners();
  }

  @protected
  void setRecording(RecordingState s) {
    if (recordingState == s) return;
    recordingState = s;
    notifyListeners();
  }

  @protected
  void emitRecording(RunRecording r) {
    recordingState = RecordingState.received;
    _recordings.add(r);
    notifyListeners();
  }

  @protected
  void emit(StartEvent e) {
    // The same event read on connect and then notified: drop the repeat.
    if (_lastEvent != null && _lastEvent.runtimeType == e.runtimeType &&
        _lastEvent!.counter == e.counter) {
      return;
    }
    _lastEvent = e;
    switch (e) {
      case CountdownEvent(digit: 3):
        lastGo = null;
        lastResult = null;
        recordingState = RecordingState.none;
      case GoEvent():
        lastGo = e;
      case ResultEvent():
        lastResult = e;
      default:
    }
    _events.add(e);
    notifyListeners();
  }

  @override
  void dispose() {
    _events.close();
    _recordings.close();
    super.dispose();
  }
}
