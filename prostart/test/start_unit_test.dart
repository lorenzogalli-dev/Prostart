import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prostart/start_unit/clock_sync.dart';
import 'package:prostart/start_unit/protocol.dart';

List<int> u32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

void main() {
  group('protocol (bytes as Ble.h sends them)', () {
    test('GO carries the beep instant', () {
      final e = StartEvent.decode([4, 9, ...u32(0xFFFFFF00)]);
      expect(e, isA<GoEvent>());
      expect((e as GoEvent).boardUs, 0xFFFFFF00);
      expect(e.counter, 9);
    });

    test('RESULT: verdict, signed reaction, onset, go', () {
      final rt = ByteData(4)..setInt32(0, -45000, Endian.little);
      final e = StartEvent.decode([
        5, 3, 1, ...rt.buffer.asUint8List(), ...u32(1000), ...u32(2000),
      ]) as ResultEvent;
      expect(e.verdict, Verdict.falseStart);
      expect(e.reactionUs, -45000);
      expect(e.onsetBoardUs, 1000);
      expect(e.goBoardUs, 2000);
    });

    test('countdown, short and unknown packets', () {
      expect((StartEvent.decode([1, 1, 2]) as CountdownEvent).digit, 2);
      expect(StartEvent.decode([5, 1, 0]), isNull); // truncated result
      expect(StartEvent.decode([42, 1]), isNull);
      expect(StartEvent.decode([0]), isNull);
    });

    test('pong', () {
      final p = Pong.decode([0x34, 0x12, ...u32(7), ...u32(9)])!;
      expect((p.seq, p.rxBoardUs, p.txBoardUs), (0x1234, 7, 9));
    });
  });

  group('clock sync', () {
    test('unwrap across the 32-bit wrap, and an older stamp', () {
      final u = Unwrap32();
      expect(u(0xFFFFFF00), 0xFFFFFF00);
      expect(u(0x10), 0x100000010);
      expect(u(0xFFFFFFF0), 0xFFFFFFF0); // older than the last: no advance
      expect(u(0x20), 0x100000020);
    });

    test('recovers the offset from asymmetric, jittery delays', () {
      // phone = board - 5 s. Forward 6-30 ms, back 4-30 ms: the minimum of
      // each direction is 6 and 4 ms, so the estimate is off by (6-4)/2 = 1 ms.
      const offset = -5000000;
      final s = ClockSync();
      final fwd = [30000, 6000, 18000, 25000, 9000];
      final back = [4000, 22000, 30000, 11000, 15000];
      for (var i = 0; i < fwd.length; i++) {
        final t1 = 1000000 + i * 100000;
        final rx = t1 + fwd[i] - offset;
        final tx = rx + 300;
        s.addPong(
          t1PhoneUs: t1,
          t4PhoneUs: tx + offset + back[i],
          rxBoardUs32: rx & 0xFFFFFFFF,
          txBoardUs32: tx & 0xFFFFFFFF,
        );
      }
      final e = s.estimate!;
      expect(e.offsetUs, closeTo(offset - 1000, 1));
      expect(e.roundTripFloorUs, 10000);
      expect(s.toPhoneUs(1234567), closeTo(1234567 + offset - 1000, 1));
    });

    test('a go stamped after the board clock wrapped', () {
      final s = ClockSync();
      // Board near the wrap during sync, go after it.
      const boardAtSync = 0xFFFF0000;
      s.addPong(
        t1PhoneUs: 10000000,
        t4PhoneUs: 10020000,
        rxBoardUs32: boardAtSync,
        txBoardUs32: boardAtSync,
      );
      final go = (boardAtSync + 2000000) & 0xFFFFFFFF; // 2 s later, wrapped
      expect(s.toPhoneUs(go)! - s.toPhoneUs(boardAtSync)!, 2000000);
    });
  });
}
