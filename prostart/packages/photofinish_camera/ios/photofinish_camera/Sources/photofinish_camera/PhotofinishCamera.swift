import AVFoundation
import Accelerate
import UIKit

struct CrossingOutput {
  /// When the torso crossed the line, host clock (mach_absolute_time), µs.
  let crossHostUs: Double
  let jpeg: Data
  /// The two frames the crossing was interpolated between, this far apart.
  let frameGapMs: Double
  /// Frames actually delivered per second over the analysed window, from
  /// their own timestamps: what the camera really gave, not what was asked.
  let measuredFps: Double
  /// judge.py: "fit" (line through ±160 ms), "interpolated" or "frame".
  let timing: String
  let uncertaintyMs: Double
}

/// The analysed frames: downscaled, rotated upright, BGRA. Preallocated once
/// per arm so nothing is allocated per frame at 120-240 fps.
final class FrameRing {
  static let width = 288
  static let height = 512
  static let rowBytes = width * 4
  static let frameBytes = rowBytes * height

  let capacity: Int
  private let buffers: [UnsafeMutableRawPointer]
  private var stamps: [Double]
  private(set) var written = 0

  init(capacity: Int) {
    self.capacity = capacity
    buffers = (0..<capacity).map { _ in
      UnsafeMutableRawPointer.allocate(byteCount: FrameRing.frameBytes, alignment: 64)
    }
    stamps = Array(repeating: 0, count: capacity)
  }

  deinit { buffers.forEach { $0.deallocate() } }

  var next: UnsafeMutableRawPointer { buffers[written % capacity] }

  func commit(hostUs: Double) {
    stamps[written % capacity] = hostUs
    written += 1
  }

  /// Frames still held with a stamp at or after `fromUs`, oldest first.
  func frames(fromUs: Double) -> [(UnsafeMutableRawPointer, Double)] {
    let first = max(0, written - capacity)
    return (first..<written)
      .map { (buffers[$0 % capacity], stamps[$0 % capacity]) }
      .filter { $0.1 >= fromUs }
  }
}

/// The photofinish camera. Everything here that touches a frame runs on
/// videoQueue; commands from Flutter hop onto it.
final class PhotofinishCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "prostart.session")
  private let videoQueue = DispatchQueue(label: "prostart.video", qos: .userInteractive)
  private let analysisQueue = DispatchQueue(label: "prostart.analysis", qos: .userInitiated)

  /// Exposure we aim for: 1/1000 s. At 10 m/s that is 1 cm of motion blur,
  /// against ~33 cm at the 1/30 s auto exposure would choose indoors.
  private static let targetExposureS = 1.0 / 1000
  /// Kept before the moment someone enters the line band. After it, frames
  /// are recorded until the band has been clear for bandClearS (the runner
  /// has passed), at least minPostS and at most maxPostS. A fixed 0.5 s lost
  /// slow passes on 2026-10-15: the arm entered the band, the torso centre
  /// crossed after the window had closed.
  private static let preTriggerS = 0.25
  private static let minPostS = 0.3
  private static let maxPostS = 1.5
  private static let bandClearS = 0.15

  private var device: AVCaptureDevice?
  private var configured = false
  private var fps = 0.0
  private var exposureUs = 0.0
  private var nativeW = 0, nativeH = 0

  private let finder: CrossingFinder?

  // videoQueue state
  private enum State { case idle, armed, triggered, analysing }
  private var state = State.idle
  private var lineA = CGPoint(x: 0.5, y: 0), lineB = CGPoint(x: 0.5, y: 1)
  private var goHostUs = 0.0, armHostUs = 0.0, timeoutS = 30.0, triggerHostUs = 0.0
  private var lastMotionHostUs = 0.0
  private var ring: FrameRing?
  private var scaleTmp = UnsafeMutableRawPointer.allocate(
    byteCount: FrameRing.height * FrameRing.width * 4, alignment: 64)
  private var bandOffsets: [Int] = []
  private var bandRef: [Float] = []
  private var motionHits = 0

  var onStatus: ((String) -> Void)?
  var onResult: ((CrossingOutput) -> Void)?
  var onError: ((String) -> Void)?

  init(modelPath: String?) {
    finder = modelPath.flatMap { CrossingFinder(modelPath: $0) }
    super.init()
  }

  deinit { scaleTmp.deallocate() }

  // MARK: - Session

  func start(completion: @escaping ([String: Any]?, String?) -> Void) {
    AVCaptureDevice.requestAccess(for: .video) { granted in
      guard granted else {
        completion(nil, "Camera access denied - allow it in Settings")
        return
      }
      self.sessionQueue.async {
        if !self.configured, let err = self.configure() {
          completion(nil, err)
          return
        }
        if !self.session.isRunning { self.session.startRunning() }
        // Let auto exposure settle on the scene, then shorten it.
        self.sessionQueue.asyncAfter(deadline: .now() + 1.0) {
          self.lockShortExposure()
          completion([
            "fps": self.fps,
            "width": self.nativeH,  // portrait
            "height": self.nativeW,
            "exposureUs": self.exposureUs,
          ], nil)
        }
      }
    }
  }

  func stop() {
    videoQueue.async {
      self.state = .idle
      self.ring = nil
    }
    sessionQueue.async {
      if self.session.isRunning { self.session.stopRunning() }
    }
  }

  /// The format with the highest frame rate, 16:9 up to 1080p; at equal rate
  /// the one closest to 720p (more pixels cost time per frame, not accuracy:
  /// the analysis runs at 288x512).
  private func configure() -> String? {
    guard
      let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    else { return "No back camera" }
    var best: (format: AVCaptureDevice.Format, range: AVFrameRateRange, w: Int32)?
    for f in dev.formats {
      let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
      guard d.width <= 1920, d.width >= 640, Int(d.width) * 9 == Int(d.height) * 16 else {
        continue
      }
      guard let r = f.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
      else { continue }
      if let b = best {
        if r.maxFrameRate < b.range.maxFrameRate { continue }
        if r.maxFrameRate == b.range.maxFrameRate && abs(d.width - 1280) >= abs(b.w - 1280) {
          continue
        }
      }
      best = (f, r, d.width)
    }
    guard let pick = best else { return "No usable camera format" }

    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = .inputPriority
    guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
      return "Camera input unavailable"
    }
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    // Keep frames: a dropped frame near the line is lost resolution.
    output.alwaysDiscardsLateVideoFrames = false
    output.setSampleBufferDelegate(self, queue: videoQueue)
    guard session.canAddOutput(output) else { return "Camera output unavailable" }
    session.addOutput(output)
    if let c = output.connection(with: .video), c.isVideoStabilizationSupported {
      // Stabilisation crops and delays frames; the phone is on a tripod.
      c.preferredVideoStabilizationMode = .off
    }
    do {
      try dev.lockForConfiguration()
      dev.activeFormat = pick.format
      dev.activeVideoMinFrameDuration = pick.range.minFrameDuration
      dev.activeVideoMaxFrameDuration = pick.range.minFrameDuration
      if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
      if dev.isExposureModeSupported(.continuousAutoExposure) {
        dev.exposureMode = .continuousAutoExposure
      }
      dev.unlockForConfiguration()
    } catch {
      return "Camera busy"
    }
    let d = CMVideoFormatDescriptionGetDimensions(pick.format.formatDescription)
    nativeW = Int(d.width)
    nativeH = Int(d.height)
    fps = pick.range.maxFrameRate
    device = dev
    configured = true
    return nil
  }

  /// Short exposure at the same brightness: ISO up as the time goes down. If
  /// ISO runs out, the exposure stays as short as the light allows.
  private func lockShortExposure() {
    guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
    defer { dev.unlockForConfiguration() }
    let f = dev.activeFormat
    let cur = dev.exposureDuration.seconds
    let iso = dev.iso
    let frame = 1.0 / fps
    var target = max(Self.targetExposureS, f.minExposureDuration.seconds)
    var newIso = iso * Float(cur / target)
    if newIso > f.maxISO {
      target = cur * Double(iso / f.maxISO)
      newIso = f.maxISO
    }
    target = min(target, frame)
    newIso = max(f.minISO, min(f.maxISO, newIso))
    if target < cur && dev.isExposureModeSupported(.custom) {
      dev.setExposureModeCustom(
        duration: CMTime(seconds: target, preferredTimescale: 1_000_000), iso: newIso)
      exposureUs = target * 1e6
    } else {
      exposureUs = cur * 1e6
    }
  }

  // MARK: - Commands

  func setLine(_ a: CGPoint, _ b: CGPoint) {
    videoQueue.async {
      self.lineA = a
      self.lineB = b
    }
  }

  func arm(goHostUs: Double, timeoutS: Double) {
    videoQueue.async {
      guard self.state == .idle || self.state == .armed else { return }
      guard self.finder != nil else {
        self.onError?("Pose model missing from the app")
        return
      }
      let capacity = Int(((Self.preTriggerS + Self.maxPostS) * self.fps).rounded(.up)) + 4
      if self.ring?.capacity != capacity { self.ring = FrameRing(capacity: capacity) }
      self.goHostUs = goHostUs
      self.armHostUs = CACurrentMediaTime() * 1e6
      self.timeoutS = timeoutS
      self.motionHits = 0
      self.bandRef = []
      self.bandOffsets = self.makeBand()
      self.state = .armed
      self.onStatus?("armed")
    }
  }

  func disarm() {
    videoQueue.async {
      if self.state == .armed || self.state == .triggered { self.state = .idle }
    }
  }

  // MARK: - Frames

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard state == .armed || state == .triggered, let ring = ring else { return }
    let host = hostUs(of: sampleBuffer)
    if state == .armed && CACurrentMediaTime() * 1e6 - armHostUs > timeoutS * 1e6 {
      state = .idle
      onError?("timeout")
      return
    }
    if host < goHostUs { return }  // a frame from before "go"
    guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let slot = ring.next
    downscaleUpright(pb, into: slot)
    ring.commit(hostUs: host)

    if state == .armed {
      if bandMoved(slot) {
        motionHits += 1
        if motionHits >= 2 {
          state = .triggered
          triggerHostUs = host
          lastMotionHostUs = host
          onStatus?("triggered")
        }
      } else {
        motionHits = 0
      }
    } else {
      if bandMoved(slot) { lastMotionHostUs = host }
      let since = host - triggerHostUs
      let passed = since > Self.minPostS * 1e6 && host - lastMotionHostUs > Self.bandClearS * 1e6
      guard passed || since > Self.maxPostS * 1e6 else { return }
      state = .analysing
      onStatus?("analysing")
      let frames = ring.frames(fromUs: triggerHostUs - Self.preTriggerS * 1e6)
      let a = lineA, b = lineB  // fractions, as judge.line_through takes them
      let stride = max(1, Int((fps / 60).rounded()))
      analysisQueue.async {
        let out = self.finder?.findCrossing(frames: frames, lineA: a, lineB: b, coarseStride: stride)
        self.videoQueue.async {
          self.state = .idle
          switch out {
          case .success(let r): self.onResult?(r)
          case .failure(let e): self.onError?(e.message)
          case nil: self.onError?("Pose model missing from the app")
          }
        }
      }
    }
  }

  /// The frame's instant on the host clock - mach_absolute_time, the clock
  /// the Dart side's PhoneClock reads - in µs.
  private func hostUs(of sb: CMSampleBuffer) -> Double {
    var t = CMSampleBufferGetPresentationTimeStamp(sb)
    let clock: CMClock?
    if #available(iOS 15.4, *) {
      clock = session.synchronizationClock
    } else {
      clock = session.masterClock
    }
    if let c = clock { t = CMSyncConvertTime(t, from: c, to: CMClockGetHostTimeClock()) }
    return CMTimeGetSeconds(t) * 1e6
  }

  /// Native landscape BGRA -> 512x288 -> rotated 90° clockwise to 288x512,
  /// upright for a phone held in portrait (back camera).
  private func downscaleUpright(_ pb: CVPixelBuffer, into dst: UnsafeMutableRawPointer) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
    var src = vImage_Buffer(
      data: base, height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
      width: vImagePixelCount(CVPixelBufferGetWidth(pb)),
      rowBytes: CVPixelBufferGetBytesPerRow(pb))
    var tmp = vImage_Buffer(
      data: scaleTmp, height: vImagePixelCount(FrameRing.width),
      width: vImagePixelCount(FrameRing.height), rowBytes: FrameRing.height * 4)
    vImageScale_ARGB8888(&src, &tmp, nil, vImage_Flags(kvImageNoFlags))
    var out = vImage_Buffer(
      data: dst, height: vImagePixelCount(FrameRing.height),
      width: vImagePixelCount(FrameRing.width), rowBytes: FrameRing.rowBytes)
    var bg: [UInt8] = [0, 0, 0, 255]
    vImageRotate90_ARGB8888(
      &tmp, &out, UInt8(kRotate90DegreesClockwise), &bg, vImage_Flags(kvImageNoFlags))
  }

  // MARK: - Trigger: someone entering a band around the line

  /// Byte offsets of the pixels within ±6 px of the line, every 4th row.
  private func makeBand() -> [Int] {
    let w = FrameRing.width, h = FrameRing.height
    let a = CGPoint(x: lineA.x * Double(w), y: lineA.y * Double(h))
    let b = CGPoint(x: lineB.x * Double(w), y: lineB.y * Double(h))
    var offs: [Int] = []
    for y in stride(from: 0, to: h, by: 4) {
      let x: Double =
        abs(b.y - a.y) < 1e-6
        ? a.x : a.x + (Double(y) - a.y) * (b.x - a.x) / (b.y - a.y)
      for dx in stride(from: -6, through: 6, by: 2) {
        let xi = Int(x.rounded()) + dx
        if xi >= 0 && xi < w { offs.append(y * FrameRing.rowBytes + xi * 4) }
      }
    }
    return offs
  }

  /// True when enough of the band differs from its learnt background. The
  /// background follows the scene slowly while nothing is there.
  private func bandMoved(_ frame: UnsafeMutableRawPointer) -> Bool {
    let p = frame.assumingMemoryBound(to: UInt8.self)
    if bandRef.count != bandOffsets.count {
      bandRef = bandOffsets.map { o in
        (Float(p[o]) + 2 * Float(p[o + 1]) + Float(p[o + 2])) / 4
      }
      return false
    }
    var changed = 0
    for (i, o) in bandOffsets.enumerated() {
      let l = (Float(p[o]) + 2 * Float(p[o + 1]) + Float(p[o + 2])) / 4
      if abs(l - bandRef[i]) > 30 { changed += 1 }
    }
    let moved = Double(changed) > 0.06 * Double(bandOffsets.count)
    if !moved {
      for (i, o) in bandOffsets.enumerated() {
        let l = (Float(p[o]) + 2 * Float(p[o + 1]) + Float(p[o + 2])) / 4
        bandRef[i] += 0.1 * (l - bandRef[i])
      }
    }
    return moved
  }
}
