import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// What the native camera reports once started.
class CameraInfo {
  final double fps;
  final int width; // portrait: the short side
  final int height;
  final double exposureUs;
  const CameraInfo(this.fps, this.width, this.height, this.exposureUs);
}

/// The finish crossing the native side found.
class CrossingResult {
  /// When the torso crossed the line, on PhoneClock (µs).
  final double crossPhoneUs;

  /// The frame nearest the crossing, line and torso drawn in.
  final Uint8List jpeg;

  /// Interval between the two frames the crossing was interpolated in.
  final double frameGapMs;

  /// Frames really delivered per second around the line (from timestamps).
  final double measuredFps;

  /// How the instant was found (judge.py): "fit", "interpolated" or "frame",
  /// and its uncertainty.
  final String timing;
  final double uncertaintyMs;
  const CrossingResult(
    this.crossPhoneUs,
    this.jpeg,
    this.frameGapMs,
    this.measuredFps,
    this.timing,
    this.uncertaintyMs,
  );
}

/// A video picked from the library, upright size and a first-frame preview.
class VideoInfo {
  final String path;
  final int width;
  final int height;
  final double fps;
  final double durationS;
  final Uint8List preview;
  const VideoInfo(this.path, this.width, this.height, this.fps, this.durationS, this.preview);
}

/// What detect.py prints, for the same video: times from the video's start.
class VideoAnalysis {
  final double timeS; // fitted when possible
  final double interpolatedS;
  final double firstFrameS;
  final double uncertaintyMs;
  final String timing;
  final int frames;
  final int detections;

  /// Diagnostic: detections whose chest front came from the silhouette
  /// (the rest fell back to the anatomical estimate).
  final int silhouette;

  /// The running direction, found from the torso's motion.
  final bool rightward;
  final double fps;
  final Uint8List jpeg;
  const VideoAnalysis({
    required this.silhouette,
    required this.rightward,
    required this.timeS,
    required this.interpolatedS,
    required this.firstFrameS,
    required this.uncertaintyMs,
    required this.timing,
    required this.frames,
    required this.detections,
    required this.fps,
    required this.jpeg,
  });
}

/// The native photofinish camera (ios/Runner/PhotofinishCamera.swift).
///
/// Everything time-critical stays native: frames are stamped by the camera
/// on the host clock (the one PhoneClock reads), buffered in RAM from "go",
/// and the torso crossing is found there with MediaPipe Pose - the model the
/// colleagues' photofinish2.py uses. Dart only places the line and receives
/// the crossing instant.
class PhotofinishCamera {
  static const _ch = MethodChannel('prostart/photofinish');
  static const previewViewType = 'prostart/camera_preview';

  static bool get supported => Platform.isIOS;

  final _status = StreamController<String>.broadcast();
  Stream<String> get status => _status.stream;
  Completer<CrossingResult>? _pending;

  PhotofinishCamera() {
    _ch.setMethodCallHandler(_onNative);
  }

  Future<CameraInfo> start() async {
    final m = (await _ch.invokeMapMethod<String, dynamic>('start'))!;
    return CameraInfo(
      (m['fps'] as num).toDouble(),
      m['width'] as int,
      m['height'] as int,
      (m['exposureUs'] as num).toDouble(),
    );
  }

  Future<void> stop() async {
    _fail('stopped');
    await _ch.invokeMethod('stop');
  }

  /// The finish line through two points, normalised to the portrait image
  /// (0..1, origin top-left).
  Future<void> setLine(Offset a, Offset b) => _ch.invokeMethod('setLine', {
    'x1': a.dx,
    'y1': a.dy,
    'x2': b.dx,
    'y2': b.dy,
  });

  /// From "go" (on PhoneClock): buffer frames, wait for someone to reach the
  /// line, then find the torso crossing. Completes with the crossing, or an
  /// error if nobody crossed within [timeout].
  Future<CrossingResult> arm(int goPhoneUs, {Duration timeout = const Duration(seconds: 30)}) {
    _fail('re-armed');
    final c = _pending = Completer<CrossingResult>();
    _ch.invokeMethod('arm', {
      'goPhoneUs': goPhoneUs.toDouble(),
      'timeoutS': timeout.inMilliseconds / 1000.0,
    });
    return c.future;
  }

  Future<void> disarm() async {
    _fail('cancelled');
    await _ch.invokeMethod('disarm');
  }

  void _fail(String why) {
    final c = _pending;
    _pending = null;
    if (c != null && !c.isCompleted) c.completeError(why);
  }

  Future<dynamic> _onNative(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
    switch (call.method) {
      case 'onStatus':
        _status.add(args['state'] as String);
      case 'onResult':
        final c = _pending;
        _pending = null;
        c?.complete(CrossingResult(
          (args['crossPhoneUs'] as num).toDouble(),
          args['jpeg'] as Uint8List,
          (args['frameGapMs'] as num).toDouble(),
          (args['measuredFps'] as num).toDouble(),
          args['timing'] as String,
          (args['uncertaintyMs'] as num).toDouble(),
        ));
      case 'onError':
        _fail(args['message'] as String? ?? 'camera error');
    }
  }

  /// Opens the library; null if the user cancelled.
  static Future<VideoInfo?> pickVideo() async {
    final m = await _ch.invokeMapMethod<String, dynamic>('pickVideo');
    if (m == null) return null;
    return VideoInfo(
      m['path'] as String,
      m['width'] as int,
      m['height'] as int,
      (m['fps'] as num).toDouble(),
      (m['durationS'] as num).toDouble(),
      m['preview'] as Uint8List,
    );
  }

  /// The video through the photofinish detection, as video.py runs it. The
  /// running direction (detect.py --dir) is found from the torso's motion.
  static Future<VideoAnalysis> analyzeVideo(VideoInfo v, Offset a, Offset b) async {
    final m = (await _ch.invokeMapMethod<String, dynamic>('analyzeVideo', {
      'path': v.path,
      'x1': a.dx,
      'y1': a.dy,
      'x2': b.dx,
      'y2': b.dy,
    }))!;
    return VideoAnalysis(
      timeS: (m['timeS'] as num).toDouble(),
      interpolatedS: (m['interpolatedS'] as num).toDouble(),
      firstFrameS: (m['firstFrameS'] as num).toDouble(),
      uncertaintyMs: (m['uncertaintyMs'] as num).toDouble(),
      timing: m['timing'] as String,
      frames: m['frames'] as int,
      detections: m['detections'] as int,
      silhouette: m['silhouette'] as int,
      rightward: m['rightward'] as bool,
      fps: (m['fps'] as num).toDouble(),
      jpeg: m['jpeg'] as Uint8List,
    );
  }

  void dispose() {
    _ch.setMethodCallHandler(null);
    _status.close();
  }
}
