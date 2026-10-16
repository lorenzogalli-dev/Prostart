import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prostart/start_unit/run_recording.dart';
import 'package:prostart/start_unit/clock_sync.dart';
import 'package:prostart/start_unit/protocol.dart';

List<int> u32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

void main() {
  group('run recording', () {
    test('decodes RUN_INFO', () {
      final i = RunInfo.decode(_info())!;
      expect(i.runId, 7);
      expect(i.n, 30);
      expect(i.armPeakMg, 12.34);
      expect(i.timingOk, isTrue);
      expect(i.armCapped, isFalse);
      expect(i.verdict, Verdict.valid);
      expect(i.reactionUs, 155500);
      expect(i.key, '${0xA1B2C3D4}-7');
    });

    test('finds the hole, fills it, writes capture.py CSV', () {
      final a = RunAssembler()..onPacket(_info());
      a.onPacket(_samples(7, 0, 12));
      a.onPacket(_samples(7, 20, 10));
      a.onPacket([DataKind.end, 7, 0, 30, 0]);
      expect(a.ended, isTrue);
      expect(a.complete, isFalse);
      expect(a.firstMissing(), (12, 20));
      a.onPacket(_samples(7, 12, 8));
      expect(a.complete, isTrue);
      expect(a.firstMissing(), isNull);
      final r = a.build(DateTime(2026, 10, 16, 14, 2, 12));
      expect(r.fileName, '20261016_140212_r00007_0.155s.csv');
      final csv = r.toCsv().split('\n');
      expect(csv, contains('# set_t_s: 0.010000'));
      expect(csv, contains('# board_verdict: valid start'));
      expect(csv, contains('# board_reaction_ms: 155.5'));
      expect(csv, contains('t_s,t_us,x_g,y_g,z_g'));
      expect(csv, contains('0.000000,1990000,-0.1465,0.0488,1.0000'));
    });

    test('samples of another run are ignored', () {
      final a = RunAssembler()..onPacket(_info());
      a.onPacket(_samples(8, 0, 30));
      expect(a.complete, isFalse);
    });
  });

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

// v6: a run's recording over the data characteristic (Ble.h).
List<int> _info({int n = 30, int id = 7}) {
  final b = ByteData(51);
  b.setUint8(0, DataKind.info);
  b.setUint32(1, 0xA1B2C3D4, Endian.little);
  b.setUint16(5, id, Endian.little);
  b.setUint16(7, n, Endian.little);
  b.setUint16(9, 10, Endian.little); // preroll
  b.setUint32(11, 1000, Endian.little); // on
  b.setUint32(15, 2000000, Endian.little); // set
  b.setUint32(19, 3000000, Endian.little); // go
  b.setUint32(23, 2500000, Endian.little); // arm
  b.setUint16(27, 1234, Endian.little); // 12.34 mg
  b.setUint8(29, 1 | 8);
  b.setUint8(30, 0); // valid
  b.setInt32(31, 155500, Endian.little);
  b.setUint32(35, 3155500, Endian.little);
  b.setUint16(49, 800, Endian.little);
  return b.buffer.asUint8List();
}

List<int> _samples(int id, int first, int k) {
  final b = ByteData(5 + 10 * k);
  b.setUint8(0, DataKind.samples);
  b.setUint16(1, id, Endian.little);
  b.setUint16(3, first, Endian.little);
  for (var i = 0; i < k; i++) {
    b.setUint32(5 + 10 * i, 1990000 + 1245 * (first + i), Endian.little);
    b.setInt16(5 + 10 * i + 4, -300, Endian.little);
    b.setInt16(5 + 10 * i + 6, 100, Endian.little);
    b.setInt16(5 + 10 * i + 8, 2048, Endian.little); // 1 g
  }
  return b.buffer.asUint8List();
}

