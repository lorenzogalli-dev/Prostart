import 'dart:collection';

/// Board micros() (32 bits, wraps every ~71.6 min) as a 64-bit count. Every
/// stamp it sees is within seconds of the previous one, so the shortest signed
/// step between them is the true one.
class Unwrap32 {
  int? _last;
  int _acc = 0;

  int call(int v) {
    final last = _last;
    if (last == null) {
      _last = v;
      _acc = v;
      return v;
    }
    final step = (v - last) & 0xFFFFFFFF;
    if (step >= 0x80000000) return _acc + step - 0x100000000; // older stamp
    _last = v;
    _acc += step;
    return _acc;
  }
}

class SyncEstimate {
  /// phone_us = board_us + offsetUs.
  final double offsetUs;

  /// Minimum round trip, both directions' floors added: the uncertainty bound.
  final int roundTripFloorUs;
  final int samples;
  const SyncEstimate(this.offsetUs, this.roundTripFloorUs, this.samples);
}

/// Board-to-phone clock offset from ping/pong, as in Ble.h:
///   a = min(t_rx - t1)  (phone -> board)
///   b = min(t4 - t_tx)  (board -> phone)
///   offset = (b - a) / 2
/// Each direction is minimised on its own: a BLE reply waits for the next
/// connection event, so a single round trip is asymmetric by up to one
/// interval (15-30 ms on iOS), while each direction's minimum is a message
/// that just made its event. The window bounds clock drift (20-50 ppm: under
/// 0.5 ms over 10 s).
class ClockSync {
  final Duration window;
  ClockSync({this.window = const Duration(seconds: 10)});

  final unwrap = Unwrap32();
  final _fwd = Queue<(int, int)>(); // (phone t1, board_rx - t1)
  final _back = Queue<(int, int)>(); // (phone t4, t4 - board_tx)
  SyncEstimate? _last;

  /// The newest estimate; kept after the board stops answering (from "set"
  /// to the result), which is exactly when it is needed.
  SyncEstimate? get estimate => _last;

  void addPong({
    required int t1PhoneUs,
    required int t4PhoneUs,
    required int rxBoardUs32,
    required int txBoardUs32,
  }) {
    final rx = unwrap(rxBoardUs32), tx = unwrap(txBoardUs32);
    _fwd.add((t1PhoneUs, rx - t1PhoneUs));
    _back.add((t4PhoneUs, t4PhoneUs - tx));
    final cut = t4PhoneUs - window.inMicroseconds;
    while (_fwd.isNotEmpty && _fwd.first.$1 < cut) {
      _fwd.removeFirst();
    }
    while (_back.isNotEmpty && _back.first.$1 < cut) {
      _back.removeFirst();
    }
    var a = _fwd.first.$2, b = _back.first.$2;
    for (final s in _fwd) {
      if (s.$2 < a) a = s.$2;
    }
    for (final s in _back) {
      if (s.$2 < b) b = s.$2;
    }
    _last = SyncEstimate((b - a) / 2, a + b, _fwd.length);
  }

  /// A board stamp on the phone's clock, or null before the first pong.
  int? toPhoneUs(int boardUs32) {
    final e = _last;
    if (e == null) return null;
    return unwrap(boardUs32) + e.offsetUs.round();
  }

  void reset() {
    _fwd.clear();
    _back.clear();
    _last = null;
  }
}
