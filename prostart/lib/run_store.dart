import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'start_unit/run_recording.dart';

/// Where the recordings live: one CSV per start in the app's Documents/runs
/// folder (visible in the Files app, "On My iPhone" > ProStart), in the same
/// format capture.py writes, so the Python tools read them as they are.
class RunStore {
  RunStore._();
  static final instance = RunStore._();

  Directory? _dir;
  Set<String>? _keys;

  Future<Directory> _runsDir() async {
    final d = _dir ??= Directory(
      '${(await getApplicationDocumentsDirectory()).path}/runs',
    );
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// "bootId-runId" of every run saved, so one the board sends again after a
  /// reconnect (or an app restart) is not saved twice.
  Future<Set<String>> _savedKeys() async {
    final k = _keys;
    if (k != null) return k;
    final f = File('${(await _runsDir()).path}/.saved_keys');
    _keys = await f.exists()
        ? (await f.readAsLines()).where((l) => l.isNotEmpty).toSet()
        : <String>{};
    return _keys!;
  }

  /// Saves [r] unless it is saved already. The file, or null if it was a
  /// repeat. Throws if the write fails: then the board must not be told.
  Future<File?> save(RunRecording r) async {
    final keys = await _savedKeys();
    if (keys.contains(r.info.key)) return null;
    final dir = await _runsDir();
    final file = File('${dir.path}/${r.fileName}');
    await file.writeAsString(r.toCsv(), flush: true);
    keys.add(r.info.key);
    await File('${dir.path}/.saved_keys')
        .writeAsString('${r.info.key}\n', mode: FileMode.append, flush: true);
    return file;
  }
}
