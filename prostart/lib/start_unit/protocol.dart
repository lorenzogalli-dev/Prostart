/// The BLE protocol of the start unit. The board side, and the reference for
/// every byte here, is Arduino/AlgorithmRealTimeESP32/Ble.h. Change both or
/// neither.
library;

import 'dart:typed_data';

abstract class StartUnitUuids {
  static const service = 'f7280000-22eb-44d8-be12-ecd2b6bdd709';
  static const event = 'f7280001-22eb-44d8-be12-ecd2b6bdd709';
  static const ping = 'f7280002-22eb-44d8-be12-ecd2b6bdd709';
  static const pong = 'f7280003-22eb-44d8-be12-ecd2b6bdd709';
  static const advertisedName = 'ProStart';
}

enum Verdict { valid, falseStart, noMovement, unusable }

/// One state change of the board, as it sends it. Times are board micros(),
/// 32-bit and wrapping: convert them with ClockSync, never compare them raw.
sealed class StartEvent {
  /// +1 per event on the board; a jump means one was missed.
  final int counter;
  const StartEvent(this.counter);

  static StartEvent? decode(List<int> bytes) {
    if (bytes.length < 2) return null;
    final b = ByteData.sublistView(Uint8List.fromList(bytes));
    final counter = bytes[1];
    u32(int at) => bytes.length >= at + 4 ? b.getUint32(at, Endian.little) : 0;
    switch (bytes[0]) {
      case 0:
        return ReadyEvent(counter);
      case 1:
        return CountdownEvent(counter, bytes.length > 2 ? bytes[2] : 0);
      case 2:
        return MarksEvent(counter, u32(2));
      case 3:
        return SetEvent(counter, u32(2));
      case 4:
        return GoEvent(counter, u32(2));
      case 5:
        if (bytes.length < 15) return null;
        final v = bytes[2];
        return ResultEvent(
          counter,
          verdict: v < Verdict.values.length ? Verdict.values[v] : Verdict.unusable,
          reactionUs: b.getInt32(3, Endian.little),
          onsetBoardUs: u32(7),
          goBoardUs: u32(11),
        );
      case 6:
        return AbortEvent(counter);
      case 7:
        return OffEvent(counter);
    }
    return null;
  }
}

class ReadyEvent extends StartEvent {
  const ReadyEvent(super.counter);
}

class CountdownEvent extends StartEvent {
  final int digit;
  const CountdownEvent(super.counter, this.digit);
}

/// A beep: "on your marks", "set" or "go", at boardUs on the board's clock.
sealed class BeepEvent extends StartEvent {
  final int boardUs;
  const BeepEvent(super.counter, this.boardUs);
}

class MarksEvent extends BeepEvent {
  const MarksEvent(super.counter, super.boardUs);
}

class SetEvent extends BeepEvent {
  const SetEvent(super.counter, super.boardUs);
}

class GoEvent extends BeepEvent {
  const GoEvent(super.counter, super.boardUs);
}

class ResultEvent extends StartEvent {
  final Verdict verdict;

  /// Negative: moved before "go".
  final int reactionUs;
  final int onsetBoardUs;
  final int goBoardUs;

  const ResultEvent(
    super.counter, {
    required this.verdict,
    required this.reactionUs,
    required this.onsetBoardUs,
    required this.goBoardUs,
  });

  double get reactionSeconds => reactionUs / 1e6;
}

class AbortEvent extends StartEvent {
  const AbortEvent(super.counter);
}

class OffEvent extends StartEvent {
  const OffEvent(super.counter);
}

/// A pong: the board's receive and transmit instants for ping [seq].
class Pong {
  final int seq;
  final int rxBoardUs;
  final int txBoardUs;
  const Pong(this.seq, this.rxBoardUs, this.txBoardUs);

  static Pong? decode(List<int> bytes) {
    if (bytes.length < 10) return null;
    final b = ByteData.sublistView(Uint8List.fromList(bytes));
    return Pong(
      b.getUint16(0, Endian.little),
      b.getUint32(2, Endian.little),
      b.getUint32(6, Endian.little),
    );
  }
}

List<int> encodePing(int seq) => [seq & 0xFF, (seq >> 8) & 0xFF];
