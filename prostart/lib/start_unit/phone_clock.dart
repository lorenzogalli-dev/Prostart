import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The phone's clock, in microseconds - the one the camera stamps its frames
/// with, so a frame and the start unit's "go" can be put on one timeline.
///
///  - iOS: mach_absolute_time(), the host clock. AVFoundation sample buffers
///    are converted to it natively (PhotofinishCamera.swift).
///  - Android: CLOCK_BOOTTIME, what Camera2's SENSOR_TIMESTAMP uses when its
///    timestamp source is REALTIME.
///
/// Read through FFI, synchronously: a platform-channel call would add a
/// variable delay of its own to every ping stamp.
abstract class PhoneClock {
  static final int Function() _now = _bind();

  static int nowUs() => _now();

  static int Function() _bind() {
    if (Platform.isIOS || Platform.isMacOS) {
      final lib = DynamicLibrary.process();
      final mach = lib.lookupFunction<Uint64 Function(), int Function()>(
        'mach_absolute_time',
      );
      final timebase = lib.lookupFunction<
        Int32 Function(Pointer<Uint32>),
        int Function(Pointer<Uint32>)
      >('mach_timebase_info');
      final info = calloc<Uint32>(2);
      timebase(info);
      final numer = info[0], denom = info[1];
      calloc.free(info);
      // ticks * numer / denom = ns. Divide first only when exact enough:
      // on iPhone numer/denom = 125/3, so keep the multiply in 64 bits.
      return () => mach() * numer ~/ (denom * 1000);
    }
    if (Platform.isAndroid) {
      final libc = DynamicLibrary.open('libc.so');
      final clockGettime = libc.lookupFunction<
        Int32 Function(Int32, Pointer<Int64>),
        int Function(int, Pointer<Int64>)
      >('clock_gettime');
      const clockBoottime = 7;
      final ts = calloc<Int64>(2); // struct timespec on 64-bit Android
      return () {
        clockGettime(clockBoottime, ts);
        return ts[0] * 1000000 + ts[1] ~/ 1000;
      };
    }
    final sw = Stopwatch()..start();
    return () => sw.elapsedMicroseconds;
  }
}
