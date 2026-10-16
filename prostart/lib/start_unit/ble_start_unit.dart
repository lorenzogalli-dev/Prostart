import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'phone_clock.dart';
import 'protocol.dart';
import 'run_recording.dart';
import 'start_unit.dart';

/// The real start unit over BLE (protocol in protocol.dart / Ble.h).
class BleStartUnit extends StartUnit {
  static const _pingEvery = Duration(milliseconds: 100);
  static const _pingTimeoutUs = 500000;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _ping;
  BluetoothCharacteristic? _ctrl;
  final _run = RunAssembler();
  final _delivered = <String>{}; // runs already handed on this session
  int _refetches = 0;
  final _subs = <StreamSubscription<dynamic>>[];
  Timer? _pingTimer;
  int _seq = 0;
  final _sent = <int, int>{}; // seq -> phone t1
  bool _writing = false;

  @override
  String get name => _device?.platformName.isNotEmpty == true
      ? _device!.platformName
      : StartUnitUuids.advertisedName;

  @override
  bool get isSimulated => false;

  @override
  Future<void> connect() async {
    if (link != LinkState.disconnected) return;
    error = null;
    setLink(LinkState.scanning);
    try {
      if (!await FlutterBluePlus.isSupported) {
        throw 'Bluetooth is not available on this phone';
      }
      // iOS asks for permission on first use and reports "unknown" until the
      // user answers: wait for a definite state.
      final adapter = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 10));
      if (adapter != BluetoothAdapterState.on) {
        throw adapter == BluetoothAdapterState.unauthorized
            ? 'Bluetooth permission denied - allow it in Settings'
            : 'Bluetooth is off';
      }
      final service = Guid(StartUnitUuids.service);
      // A connected peripheral stops advertising, so a link the OS still holds
      // (e.g. after a hot restart) can never be found by scanning: adopt it.
      final held = await FlutterBluePlus.systemDevices([service]);
      var device = held.isNotEmpty ? held.first : null;
      device ??= await _scan(service);
      if (device == null) {
        throw 'No ProStart found - is it on and nearby?';
      }
      _device = device;
      setLink(LinkState.connecting);
      await device.connect(timeout: const Duration(seconds: 10));
      _subs.add(device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) _onDisconnected();
      }));
      if (Platform.isAndroid) {
        // 15 ms interval: the sync's floor is one interval per direction.
        await device.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high,
        );
        // The recording needs packets of 51+ bytes; iOS negotiates by itself.
        await device.requestMtu(247);
      }
      final services = await device.discoverServices();
      final svc = services.firstWhere(
        (s) => s.uuid == service,
        orElse: () => throw 'This device is not a ProStart',
      );
      BluetoothCharacteristic char(String uuid) =>
          svc.characteristics.firstWhere((c) => c.uuid == Guid(uuid));
      final event = char(StartUnitUuids.event);
      final pong = char(StartUnitUuids.pong);
      _ping = char(StartUnitUuids.ping);

      _subs.add(pong.onValueReceived.listen(_onPong));
      _subs.add(event.onValueReceived.listen((v) {
        final e = StartEvent.decode(v);
        if (e != null) emit(e);
      }));
      await pong.setNotifyValue(true);
      await event.setNotifyValue(true);
      // v6 boards send each run's recording; older ones have no such chars.
      final data = svc.characteristics
          .where((c) => c.uuid == Guid(StartUnitUuids.data))
          .firstOrNull;
      final ctrl = svc.characteristics
          .where((c) => c.uuid == Guid(StartUnitUuids.ctrl))
          .firstOrNull;
      if (data != null && ctrl != null) {
        _ctrl = ctrl;
        _subs.add(data.onValueReceived.listen(_onData));
        await data.setNotifyValue(true);
      }
      // Where the board is right now, without waiting for its next event.
      final now = StartEvent.decode(await event.read());
      if (now != null) emit(now);

      setLink(LinkState.connected);
      _pingTimer = Timer.periodic(_pingEvery, (_) => _sendPing());
      // A run the board still holds (we were away when it ended): fetch it.
      await _ctrlWrite(encodeGet(0, 0, 0xFFFF));
    } catch (e) {
      error = e is String ? e : 'Connection failed - move closer and retry';
      await _teardown();
      setLink(LinkState.disconnected);
      try {
        await _device?.disconnect();
      } catch (_) {}
    }
  }

  Future<BluetoothDevice?> _scan(Guid service) async {
    final found = Completer<BluetoothDevice?>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      if (results.isNotEmpty && !found.isCompleted) {
        found.complete(results.first.device);
      }
    });
    await FlutterBluePlus.startScan(
      withServices: [service],
      timeout: const Duration(seconds: 10),
    );
    // startScan returns at once; isScanning drops when the timeout ends it.
    unawaited(FlutterBluePlus.isScanning
        .where((s) => !s)
        .first
        .then((_) => found.isCompleted ? null : found.complete(null)));
    final d = await found.future;
    await sub.cancel();
    await FlutterBluePlus.stopScan();
    return d;
  }

  void _sendPing() async {
    final ping = _ping;
    if (ping == null || _writing) return;
    _writing = true;
    final now = PhoneClock.nowUs();
    _sent.removeWhere((_, t) => now - t > _pingTimeoutUs);
    _seq = (_seq + 1) & 0xFFFF;
    final t1 = PhoneClock.nowUs();
    _sent[_seq] = t1;
    try {
      await ping.write(encodePing(_seq), withoutResponse: true);
    } catch (_) {
      // A lost ping costs nothing: the next one is 100 ms away.
    } finally {
      _writing = false;
    }
  }

  void _onPong(List<int> v) {
    final t4 = PhoneClock.nowUs();
    final p = Pong.decode(v);
    if (p == null) return;
    final t1 = _sent.remove(p.seq);
    if (t1 == null) return;
    sync.addPong(
      t1PhoneUs: t1,
      t4PhoneUs: t4,
      rxBoardUs32: p.rxBoardUs,
      txBoardUs32: p.txBoardUs,
    );
    notifyListeners();
  }

  Future<void> _ctrlWrite(List<int> v) async {
    try {
      await _ctrl?.write(v, withoutResponse: false);
    } catch (_) {}
  }

  void _onData(List<int> v) {
    final kind = _run.onPacket(v);
    final info = _run.info;
    if (kind == DataKind.info && info != null && !_delivered.contains(info.key)) {
      _refetches = 0;
      setRecording(RecordingState.receiving);
    } else if (kind == DataKind.noRun &&
        recordingState == RecordingState.receiving) {
      setRecording(RecordingState.failed);
    } else if (kind == DataKind.end && info != null) {
      _checkRun();
    }
  }

  void _checkRun() {
    final info = _run.info!;
    if (_delivered.contains(info.key)) {
      _ctrlWrite(encodeAck(info.runId)); // a repeat: it is saved already
      return;
    }
    if (_run.complete) {
      _delivered.add(info.key);
      emitRecording(_run.build(DateTime.now()));
      return;
    }
    final hole = _run.firstMissing();
    if (hole == null || ++_refetches > 20) {
      setRecording(RecordingState.failed);
      return;
    }
    _ctrlWrite(encodeGet(info.runId, hole.$1, hole.$2));
  }

  @override
  Future<void> ackRecording(RunRecording r) => _ctrlWrite(encodeAck(r.info.runId));

  void _onDisconnected() {
    if (link == LinkState.disconnected) return;
    error = 'ProStart disconnected';
    _teardown();
    setLink(LinkState.disconnected);
  }

  Future<void> _teardown() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    _ping = null;
    _ctrl = null;
    _sent.clear();
    if (recordingState == RecordingState.receiving) {
      recordingState = RecordingState.failed; // fetched again on reconnect
    }
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  @override
  Future<void> disconnect() async {
    final d = _device;
    await _teardown();
    setLink(LinkState.disconnected);
    error = null;
    await d?.disconnect();
  }
}
