import 'dart:typed_data';

import 'protocol.dart';

/// One start's recording as the board sent it: the samples from 3 s before
/// "set" to 1 s after "go", on the board's micros() clock.
class RunRecording {
  final RunInfo info;
  final Uint32List t;
  final Int16List x, y, z;

  /// When the phone received it: the start's date, which the board does not
  /// know.
  final DateTime receivedAt;

  RunRecording(this.info, this.t, this.x, this.y, this.z, this.receivedAt);

  static const _lsbG = 16.0 / 32768.0;

  /// capture.py's result_tag: '0.160s', 'FS-0.045s', 'nomove', 'error'.
  String get resultTag => switch (info.verdict) {
    Verdict.valid => '${(info.reactionUs / 1e6).toStringAsFixed(3)}s',
    Verdict.falseStart =>
      'FS${info.reactionUs >= 0 ? '+' : '-'}${(info.reactionUs.abs() / 1e6).toStringAsFixed(3)}s',
    Verdict.noMovement => 'nomove',
    Verdict.unusable => 'error',
  };

  String get fileName {
    final d = receivedAt;
    two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}'
        '${two(d.second)}_r${info.runId.toString().padLeft(5, '0')}_$resultTag.csv';
  }

  /// The same file capture.py writes from the serial dump, so every tool
  /// (start_detector.py, sweep_threshold.py) reads it unchanged.
  String toCsv() {
    final i = info;
    final b = StringBuffer();
    final t0 = t.isEmpty ? 0 : t[0];
    String rel(int us) => ((us - t0) / 1e6).toStringAsFixed(6);
    const verdicts = ['valid start', 'FALSE START', 'no movement', 'UNUSABLE'];
    b
      ..writeln('# AccelStream v4 capture')
      ..writeln('# written_utc: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln("# t_us is the board's raw micros() reading for that sample.")
      ..writeln('# t_s is relative to the first row of this file.')
      ..writeln("# on/set/go are the firmware's own beep timestamps, on the same")
      ..writeln('# micros() clock as every sample - no host or keypress latency.');
    for (final (k, us) in [('on', i.onUs), ('set', i.setUs), ('go', i.goUs)]) {
      b.writeln('# ${k}_t_us: $us');
      if (us != 0) b.writeln('# ${k}_t_s: ${rel(us)}');
    }
    if (i.armValid) {
      b
        ..writeln('# arm_t_us: ${i.armUs}')
        ..writeln('# arm_t_s: ${rel(i.armUs)}');
    }
    b
      ..writeln('# sensor: bmi270')
      ..writeln('# odr_hz: ${i.odrHz}');
    if (i.armValid) {
      b
        ..writeln('# arm_peak_mg: ${i.armPeakMg}')
        ..writeln('# arm_capped: ${i.armCapped ? 1 : 0}');
    }
    b
      ..writeln('# preroll_samples: ${i.preroll}')
      ..writeln('# truncated: ${i.truncated ? 1 : 0}')
      ..writeln('# dropped: ${i.dropped}')
      ..writeln('# clockstep_us: ${i.clockStepUs}')
      ..writeln('# gaps: ${i.gaps}')
      ..writeln('# max_gap_us: ${i.maxGapUs}')
      ..writeln('# board_run_id: ${i.runId}')
      ..writeln('# board_boot_id: ${i.bootId}')
      ..writeln('# board_verdict: ${verdicts[i.verdict.index]}')
      ..writeln('# board_reaction_ms: ${i.reactionUs / 1000.0}')
      ..writeln('# board_onset_t_us: ${i.onsetUs}')
      ..writeln('# timing_check: ${i.timingOk ? 'ok' : 'failed'}')
      ..writeln('# recorded_local: ${receivedAt.toIso8601String()}')
      ..writeln('t_s,t_us,x_g,y_g,z_g');
    for (var k = 0; k < t.length; k++) {
      b.writeln('${rel(t[k])},${t[k]},${(x[k] * _lsbG).toStringAsFixed(4)},'
          '${(y[k] * _lsbG).toStringAsFixed(4)},${(z[k] * _lsbG).toStringAsFixed(4)}');
    }
    return b.toString();
  }
}

/// Puts a run together from data packets that may arrive with holes (a
/// notification the stack dropped); [missing] says what to GET again.
class RunAssembler {
  RunInfo? info;
  Uint32List _t = Uint32List(0);
  Int16List _x = Int16List(0), _y = Int16List(0), _z = Int16List(0);
  Uint8List _have = Uint8List(0);
  int _count = 0;
  bool ended = false;

  /// The packet's kind, after taking it in.
  int onPacket(List<int> bytes) {
    if (bytes.isEmpty) return 0;
    final kind = bytes[0];
    switch (kind) {
      case DataKind.info:
        final i = RunInfo.decode(bytes);
        if (i == null) return 0;
        if (info?.key != i.key) {
          _t = Uint32List(i.n);
          _x = Int16List(i.n);
          _y = Int16List(i.n);
          _z = Int16List(i.n);
          _have = Uint8List(i.n);
          _count = 0;
        }
        info = i;
        ended = false;
      case DataKind.samples:
        final i = info;
        if (i == null || bytes.length < 5) return kind;
        final b = ByteData.sublistView(Uint8List.fromList(bytes));
        if (b.getUint16(1, Endian.little) != i.runId) return kind;
        final first = b.getUint16(3, Endian.little);
        for (var k = 0; 5 + 10 * k + 10 <= bytes.length; k++) {
          final idx = first + k;
          if (idx >= i.n) break;
          final o = 5 + 10 * k;
          _t[idx] = b.getUint32(o, Endian.little);
          _x[idx] = b.getInt16(o + 4, Endian.little);
          _y[idx] = b.getInt16(o + 6, Endian.little);
          _z[idx] = b.getInt16(o + 8, Endian.little);
          if (_have[idx] == 0) {
            _have[idx] = 1;
            _count++;
          }
        }
      case DataKind.end:
        ended = true;
    }
    return kind;
  }

  bool get complete => info != null && _count == info!.n;

  /// The first hole as [from, to), or null.
  (int, int)? firstMissing() {
    final n = info?.n ?? 0;
    for (var i = 0; i < n; i++) {
      if (_have[i] == 0) {
        var j = i;
        while (j < n && _have[j] == 0) {
          j++;
        }
        return (i, j);
      }
    }
    return null;
  }

  RunRecording build(DateTime at) => RunRecording(info!, _t, _x, _y, _z, at);
}
