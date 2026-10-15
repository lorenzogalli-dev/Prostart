import 'dart:async';
import 'dart:math';

import 'phone_clock.dart';
import 'protocol.dart';
import 'start_unit.dart';

/// A start unit with no hardware: the board's sequence, events and clock sync,
/// faked on the phone. For developing and demoing the app; the camera, the
/// photofinish and every screen run exactly as with the real board, which is
/// the point - only the source of the events changes.
///
/// Differences from the board, on purpose: "on your marks" lasts 6 s instead
/// of 20-25 s, and there is no physical button, so the app shows one.
class SimulatedStartUnit extends StartUnit {
  final _rng = Random();
  final _timers = <Timer>[];
  Timer? _syncTimer;
  int _counter = 0;

  /// The fake board's micros() runs this far behind the phone's clock, and
  /// wraps at 32 bits like the real one.
  static const _boardBehindUs = 4000000000;

  @override
  String get name => 'ProStart (demo)';

  @override
  bool get isSimulated => true;

  int _boardNow() => (PhoneClock.nowUs() - _boardBehindUs) & 0xFFFFFFFF;

  @override
  Future<void> connect() async {
    if (link != LinkState.disconnected) return;
    error = null;
    setLink(LinkState.scanning);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    setLink(LinkState.connecting);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    setLink(LinkState.connected);
    _emit((c) => ReadyEvent(c));
    // Pongs as the real link would give them: 4-30 ms each way.
    _syncTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (phase == StartPhase.set || phase == StartPhase.go) return;
      final t1 = PhoneClock.nowUs();
      final fwd = 4000 + _rng.nextInt(26000), back = 4000 + _rng.nextInt(26000);
      final rx = (t1 + fwd - _boardBehindUs) & 0xFFFFFFFF;
      sync.addPong(
        t1PhoneUs: t1,
        t4PhoneUs: t1 + fwd + 200 + back,
        rxBoardUs32: rx,
        txBoardUs32: (rx + 200) & 0xFFFFFFFF,
      );
      notifyListeners();
    });
  }

  /// The board's button. A press during a start does nothing (the board needs
  /// two to abort; the demo has no use for it).
  void pressButton() {
    if (link != LinkState.connected) return;
    if (phase != StartPhase.ready && phase != StartPhase.result) return;
    _cancelSequence();
    var at = Duration.zero;
    void after(Duration d, void Function() f) {
      at += d;
      _timers.add(Timer(at, f));
    }

    _emit((c) => CountdownEvent(c, 3));
    after(const Duration(seconds: 1), () => _emit((c) => CountdownEvent(c, 2)));
    after(const Duration(seconds: 1), () => _emit((c) => CountdownEvent(c, 1)));
    after(const Duration(seconds: 1), () => _emit((c) => MarksEvent(c, _boardNow())));
    after(const Duration(seconds: 6), () => _emit((c) => SetEvent(c, _boardNow())));
    late int go;
    after(Duration(milliseconds: 1700 + _rng.nextInt(800)), () {
      go = _boardNow();
      _emit((c) => GoEvent(c, go));
    });
    after(const Duration(seconds: 1), () {
      final rt = 120000 + _rng.nextInt(70000);
      _emit((c) => ResultEvent(
            c,
            verdict: Verdict.valid,
            reactionUs: rt,
            onsetBoardUs: (go + rt) & 0xFFFFFFFF,
            goBoardUs: go,
          ));
    });
  }

  void _emit(StartEvent Function(int counter) make) {
    _counter = (_counter + 1) & 0xFF;
    emit(make(_counter));
  }

  void _cancelSequence() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  @override
  Future<void> disconnect() async {
    _cancelSequence();
    _syncTimer?.cancel();
    _syncTimer = null;
    setLink(LinkState.disconnected);
  }
}
