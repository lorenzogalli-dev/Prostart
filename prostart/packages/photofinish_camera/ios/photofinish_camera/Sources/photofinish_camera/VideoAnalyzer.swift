import AVFoundation
import Flutter
import Accelerate
import MediaPipeTasksVision
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// "Analyse a video": a recorded race through the same detection as the live
/// photofinish, run the way Photofinish_Python/finisheye_detection/video.py
/// runs it, so the two can be compared on the same file:
///   - every frame, in order, MediaPipe in VIDEO mode (tracking);
///   - frames upright (the file's rotation applied), resized to 640 px wide;
///   - frame time = the frame's own timestamp in the file, in ms (as
///     video.py now reads CAP_PROP_POS_MSEC: index / nominal fps was 22 %
///     off on iPhone slow-motion files, whose declared rate is not 240);
///   - stop 1 s after the crossing, then the ±160 ms line fit.
/// Portrait and landscape videos both work: the line is placed on the upright
/// first frame, in fractions of it, exactly what detect.py's --line takes.
final class VideoAnalyzer: NSObject, PHPickerViewControllerDelegate {
  private let modelPath: String?
  private let queue = DispatchQueue(label: "prostart.videoanalysis", qos: .userInitiated)
  private var pickCompletion: (([String: Any]?, String?) -> Void)?

  /// video.analyze_video(analysis_width=640, post_roll_s=1.0, max_run_s=60).
  private static let analysisWidth = 640
  private static let postRollS = 1.0
  private static let maxRunS = 60.0

  init(modelPath: String?) {
    self.modelPath = modelPath
    super.init()
  }

  // MARK: - Picking

  func pick(completion: @escaping ([String: Any]?, String?) -> Void) {
    var config = PHPickerConfiguration()
    config.filter = .videos
    config.selectionLimit = 1
    // The original file, not a transcoded copy: a 240 fps slow-motion clip
    // must stay 240 fps.
    config.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    pickCompletion = completion
    guard let top = Self.topViewController() else {
      completion(nil, "No window to show the picker in")
      return
    }
    top.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    let done = pickCompletion
    pickCompletion = nil
    guard let provider = results.first?.itemProvider else {
      done?(nil, nil)  // cancelled
      return
    }
    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
      guard let url = url else {
        done?(nil, error?.localizedDescription ?? "Could not read the video")
        return
      }
      // The provider deletes its file when this returns: keep a copy.
      let copy = FileManager.default.temporaryDirectory
        .appendingPathComponent("prostart-\(UUID().uuidString).\(url.pathExtension)")
      do {
        try FileManager.default.copyItem(at: url, to: copy)
      } catch {
        done?(nil, "Could not copy the video")
        return
      }
      self.queue.async {
        if let info = self.info(copy) {
          done?(info, nil)
        } else {
          done?(nil, "Not a readable video")
        }
      }
    }
  }

  private static func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }.first
    var top = window?.rootViewController
    while let p = top?.presentedViewController { top = p }
    return top
  }

  // MARK: - Geometry

  private struct Geometry {
    let natural: (Int, Int)  // as encoded
    let rotation: Int  // clockwise degrees to make it upright: 0, 90, 180, 270
    var upright: (Int, Int) {
      rotation % 180 == 0 ? natural : (natural.1, natural.0)
    }
  }

  private func geometry(_ track: AVAssetTrack) -> Geometry {
    let t = track.preferredTransform
    let deg = (Int((atan2(Double(t.b), Double(t.a)) * 180 / .pi).rounded()) + 360) % 360
    return Geometry(
      natural: (Int(track.naturalSize.width), Int(track.naturalSize.height)), rotation: deg)
  }

  private func info(_ url: URL) -> [String: Any]? {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else { return nil }
    let g = geometry(track)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 1080, height: 1080)
    guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil),
      let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    else { return nil }
    return [
      "path": url.path,
      "width": g.upright.0,
      "height": g.upright.1,
      "fps": Double(track.nominalFrameRate),
      "durationS": CMTimeGetSeconds(asset.duration),
      "preview": FlutterStandardTypedData(bytes: jpeg),
    ]
  }

  // MARK: - Analysis

  /// Line points are fractions of the upright frame. The running direction
  /// (detect.py --dir) is found here: every frame is judged both ways, and the
  /// torso centre's travel over the clip picks the answer. Choosing it by hand
  /// gave "no crossing" twice on 2026-10-15, once for each of us.
  func analyze(
    path: String, lineA: CGPoint, lineB: CGPoint,
    completion: @escaping ([String: Any]?, String?) -> Void
  ) {
    queue.async {
      do {
        completion(try self.run(path: path, lineA: lineA, lineB: lineB), nil)
      } catch let e as CrossingError {
        completion(nil, e.message)
      } catch {
        completion(nil, error.localizedDescription)
      }
    }
  }

  /// CPU, as the Python: on 2026-10-15 the GPU delegate returned EMPTY
  /// segmentation masks on the iPhone 13 (landmarks fine, silhouette used in
  /// 0/20 frames), so every chest front fell back to the 15% estimate.
  private func makeLandmarker(_ mode: RunningMode = .video) throws -> PoseLandmarker {
    guard let path = modelPath else { throw CrossingError(message: "Pose model missing") }
    let o = PoseLandmarkerOptions()
    o.baseOptions.modelAssetPath = path
    o.runningMode = mode
    o.numPoses = 2
    o.minPoseDetectionConfidence = 0.5
    o.minPosePresenceConfidence = 0.5
    o.minTrackingConfidence = 0.5
    o.shouldOutputSegmentationMasks = true
    o.baseOptions.delegate = .CPU
    return try PoseLandmarker(options: o)
  }

  private func run(path: String, lineA: CGPoint, lineB: CGPoint) throws -> [String: Any] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else {
      throw CrossingError(message: "No video track")
    }
    let g = geometry(track)
    let fps = Double(track.nominalFrameRate) > 0 ? Double(track.nominalFrameRate) : 30
    let (uw, uh) = g.upright
    let aw = Self.analysisWidth
    let ah = Int(Double(uh) * Double(aw) / Double(uw))  // int(), as cv2.resize's size
    let landmarker = try makeLandmarker()

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw CrossingError(message: "Cannot read the video") }

    // Scaled (pre-rotation) and upright analysis buffers, reused.
    let rotated = g.rotation % 180 != 0
    let (sw, sh) = rotated ? (ah, aw) : (aw, ah)
    let scaled = UnsafeMutableRawPointer.allocate(byteCount: sw * sh * 4, alignment: 64)
    let upright = UnsafeMutableRawPointer.allocate(byteCount: aw * ah * 4, alignment: 64)
    defer {
      scaled.deallocate()
      upright.deallocate()
    }

    let line = lineThrough(lineA, lineB)
    // Both directions side by side: index 0 = left to right (+1), 1 = right
    // to left (-1). Each is exactly what detect.py computes with that --dir.
    let dirs: [Double] = [1, -1]
    var samples: [[Sample]] = [[], []]
    var detections: [[Int: Detection]] = [[:], [:]]
    var crossings: [Crossing?] = [nil, nil]
    var firstCentre: Double?, lastCentre = 0.0
    var idx = 0, nDet = 0, lastTs = -1
    var frameTimes: [Int: Double] = [:]  // ms, for the shown frame
    var firstPts: Double?

    while let sb = output.copyNextSampleBuffer() {
      guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
      let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1000
      if firstPts == nil { firstPts = pts }
      let t = pts  // this frame's own timestamp, ms
      let frameIdx = idx
      frameTimes[frameIdx] = t
      idx += 1
      uprightFrame(pb, rotation: g.rotation, scaled: scaled, sw: sw, sh: sh, into: upright, aw: aw, ah: ah)

      var buf: CVPixelBuffer?
      CVPixelBufferCreateWithBytes(
        nil, aw, ah, kCVPixelFormatType_32BGRA, upright, aw * 4, nil, nil, nil, &buf)
      let ts = max(Int(t), lastTs + 1)  // MediaPipe needs increasing timestamps
      lastTs = ts
      if let b = buf, let image = try? MPImage(pixelBuffer: b),
        let res = try? landmarker.detect(videoFrame: image, timestampInMilliseconds: ts),
        let p = framePose(res, w: aw, h: ah)
      {
        var seen = false
        for k in 0..<2 {
          let dir = dirs[k]
          guard let d = locateTorsoSegmentation(lm: p.lm, mask: p.mask, w: aw, h: ah, direction: dir)
          else { continue }
          seen = true
          detections[k][frameIdx] = d
          let s = Sample(t: t, s: dir * (d.x - lineAt(line, d.y)))  // FinishJudge.push
          if crossings[k] == nil, let prev = samples[k].last {
            crossings[k] = crossingBetween(prev, s)
          }
          samples[k].append(s)
        }
        if seen {
          nDet += 1
          if firstCentre == nil { firstCentre = p.centreX }
          lastCentre = p.centreX
        }
      }
      if t > Self.maxRunS * 1000 { break }
    }
    reader.cancelReading()

    guard let fc = firstCentre, abs(lastCentre - fc) > 0.01 else {
      throw CrossingError(
        message: "No runner moving across the frame (\(nDet)/\(idx) frames with a torso)")
    }
    let k = lastCentre > fc ? 0 : 1
    let dir = dirs[k]
    guard let c0 = crossings[k] else {
      throw CrossingError(
        message: "No crossing detected (\(nDet)/\(idx) frames with a torso, runs "
          + (dir > 0 ? "right" : "left") + ")")
    }
    let c = refine(c0, samples: samples[k])

    // The frame nearest the crossing, read again, with the overlay. Its mask
    // is detected again on that one frame (diagnostic only).
    let nearest = detections[k].keys.min {
      abs(frameTimes[$0]! - c.t) < abs(frameTimes[$1]! - c.t)
    }
    var jpeg = Data()
    if let n = nearest {
      let gen = AVAssetImageGenerator(asset: asset)
      gen.appliesPreferredTrackTransform = true
      gen.requestedTimeToleranceBefore = .zero
      gen.requestedTimeToleranceAfter = .zero
      gen.maximumSize = CGSize(width: aw, height: ah)
      if let cg = try? gen.copyCGImage(
        at: CMTime(seconds: frameTimes[n]! / 1000, preferredTimescale: 600_000), actualTime: nil),
        let ctx = CGContext(
          data: upright, width: aw, height: ah, bitsPerComponent: 8, bytesPerRow: aw * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
      {
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: aw, height: ah))
        var mask: [Float]?
        var buf: CVPixelBuffer?
        CVPixelBufferCreateWithBytes(
          nil, aw, ah, kCVPixelFormatType_32BGRA, upright, aw * 4, nil, nil, nil, &buf)
        if let b = buf, let lm = try? makeLandmarker(.image), let image = try? MPImage(pixelBuffer: b),
          let res = try? lm.detect(image: image)
        {
          mask = framePose(res, w: aw, h: ah)?.mask
        }
        jpeg = drawOverlay(
          upright, w: aw, h: ah, rowBytes: aw * 4, detection: detections[k][n], line: line,
          dir: dir, mask: mask)
      }
    }
    return [
      "timeS": c.t / 1000,
      "interpolatedS": c.interpolated / 1000,
      "firstFrameS": c.firstFrameT / 1000,
      "uncertaintyMs": c.uncertaintyMs,
      "timing": c.method,
      "frames": idx,
      "detections": nDet,
      "silhouette": detections[k].values.filter { $0.silhouette }.count,
      "rightward": dir > 0,
      // The rate really in the file, from the timestamps read.
      "fps": idx > 1 ? Double(idx - 1) / ((frameTimes[idx - 1]! - (firstPts ?? 0)) / 1000) : fps,
      "jpeg": FlutterStandardTypedData(bytes: jpeg),
    ]
  }

  /// Encoded BGRA frame -> resized -> rotated upright, into `out` (aw x ah).
  private func uprightFrame(
    _ pb: CVPixelBuffer, rotation: Int, scaled: UnsafeMutableRawPointer, sw: Int, sh: Int,
    into out: UnsafeMutableRawPointer, aw: Int, ah: Int
  ) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
    var src = vImage_Buffer(
      data: base, height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
      width: vImagePixelCount(CVPixelBufferGetWidth(pb)),
      rowBytes: CVPixelBufferGetBytesPerRow(pb))
    var mid = vImage_Buffer(
      data: rotation == 0 ? out : scaled, height: vImagePixelCount(sh),
      width: vImagePixelCount(sw), rowBytes: sw * 4)
    vImageScale_ARGB8888(&src, &mid, nil, vImage_Flags(kvImageNoFlags))
    guard rotation != 0 else { return }
    var dst = vImage_Buffer(
      data: out, height: vImagePixelCount(ah), width: vImagePixelCount(aw), rowBytes: aw * 4)
    let k: Int
    switch rotation {
    case 90: k = kRotate90DegreesClockwise
    case 180: k = kRotate180DegreesClockwise
    default: k = kRotate90DegreesCounterClockwise
    }
    var bg: [UInt8] = [0, 0, 0, 255]
    vImageRotate90_ARGB8888(&mid, &dst, UInt8(k), &bg, vImage_Flags(kvImageNoFlags))
  }
}
