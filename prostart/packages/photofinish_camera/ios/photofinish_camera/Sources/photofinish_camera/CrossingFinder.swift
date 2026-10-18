import CoreVideo
import MediaPipeTasksVision
import UIKit

struct CrossingError: Error { let message: String }

// A Swift port of the colleagues' reference implementation,
// AI_Torso_Detector/finisheye_detection (detector.py "segmentation" method and
// judge.py). It is meant to give the same answer as the Python on the same
// frames: change the Python first, then this, and keep the names aligned.
//
// What is NOT from the Python, because the phone needs it:
//  - which frames are analysed: ~60 fps across the recorded window, then
//    every frame between the two around the crossing (the Python analyses
//    every frame of a 25-60 fps video; at 240 fps that is too slow here);
//  - the running direction, from the torso centre's motion (the Python takes
//    --dir from the user).

// MARK: - detector.py

private let LS = 11, RS = 12, LH = 23, RH = 24
private let ARMS = [(11, 13, 15), (12, 14, 16)]  // shoulder, elbow, wrist

/// detector.Detection: x/y as fractions of the frame (0 = left / top).
struct Detection {
  let x: Double
  let y: Double
  let confidence: Double
  let torso: [CGPoint]  // shoulders + hips, fractions
  /// Diagnostic, not in the Python: the silhouette gave the edge (false: the
  /// anatomical estimate was used).
  var silhouette = false
}

/// One frame's MediaPipe output, kept so the direction can be decided first.
struct FramePose {
  let lm: [NormalizedLandmark]
  let mask: [Float]
  let centreX: Double  // fraction of width
}

private func vis(_ p: NormalizedLandmark) -> Double {
  guard let v = p.visibility?.doubleValue else { return 1 }
  return v
}

private func segDist(_ px: Double, _ py: Double, _ a: CGPoint, _ b: CGPoint) -> Double {
  let vx = b.x - a.x, vy = b.y - a.y
  let den = vx * vx + vy * vy
  let t = max(0, min(1, ((px - a.x) * vx + (py - a.y) * vy) / (den == 0 ? 1 : den)))
  return hypot(px - (a.x + t * vx), py - (a.y + t * vy))
}

private func torsoLen(_ lm: [NormalizedLandmark], _ w: Double, _ h: Double) -> Double {
  let sx = Double(lm[LS].x + lm[RS].x) / 2 * w, sy = Double(lm[LS].y + lm[RS].y) / 2 * h
  let hx = Double(lm[LH].x + lm[RH].x) / 2 * w, hy = Double(lm[LH].y + lm[RH].y) / 2 * h
  return hypot(sx - hx, sy - hy)
}

/// detector.locate_torso(method="segmentation", chest_factor=0.15).
func locateTorsoSegmentation(
  lm: [NormalizedLandmark], mask: [Float], w: Int, h: Int, direction d: Double,
  chestFactor: Double = 0.15
) -> Detection? {
  let W = Double(w), H = Double(h)
  let pts = [lm[LS], lm[RS], lm[RH], lm[LH]]
  let torso = pts.map { CGPoint(x: Double($0.x), y: Double($0.y)) }
  let conf = pts.map(vis).min()!
  if conf < 0.3 { return nil }
  let sh = CGPoint(x: Double(lm[LS].x + lm[RS].x) / 2 * W, y: Double(lm[LS].y + lm[RS].y) / 2 * H)
  let hp = CGPoint(x: Double(lm[LH].x + lm[RH].x) / 2 * W, y: Double(lm[LH].y + lm[RH].y) / 2 * H)
  let L = hypot(sh.x - hp.x, sh.y - hp.y)
  if L < 8 { return nil }  // too small / far away
  let xs = pts.map { Double($0.x) * W }
  let front = d > 0 ? xs.max()! : xs.min()!
  let lmEdge = front + d * chestFactor * L  // anatomical estimate
  var edge = lmEdge
  var fromSilhouette = false
  if let seg = silhouetteFront(
    lm: lm, mask: mask, w: w, h: h, sh: sh, hp: hp, L: L, d: d, lmEdge: lmEdge)
  {
    edge = seg
    fromSilhouette = true
  }
  let chestY = (sh.y + (hp.y - sh.y) * 0.25) / H  // a quarter of the way down the torso
  return Detection(
    x: edge / W, y: chestY, confidence: conf, torso: torso, silhouette: fromSilhouette)
}

/// detector._silhouette_front: rows between shoulders and hips scanned
/// forward from the torso axis until the silhouette ends; arms cut with the
/// elbow/wrist landmarks beyond the torso core; 80th percentile of the row
/// edges; clamped around the anatomical estimate.
private func silhouetteFront(
  lm: [NormalizedLandmark], mask: [Float], w: Int, h: Int, sh: CGPoint, hp: CGPoint,
  L: Double, d: Double, lmEdge: Double
) -> Double? {
  let W = Double(w), H = Double(h)
  let mw = w, mh = h  // the mask is the frame's size here: sx = sy = 1
  let armR = 0.1 * L
  var segs: [(CGPoint, CGPoint)] = []
  for (s, e, wr) in ARMS {
    let S = CGPoint(x: Double(lm[s].x) * W, y: Double(lm[s].y) * H)
    let E = CGPoint(x: Double(lm[e].x) * W, y: Double(lm[e].y) * H)
    let Wr = CGPoint(x: Double(lm[wr].x) * W, y: Double(lm[wr].y) * H)
    let hand = CGPoint(x: Wr.x + (Wr.x - E.x) * 0.4, y: Wr.y + (Wr.y - E.y) * 0.4)
    segs += [(S, E), (E, Wr), (Wr, hand)]
  }
  var clean: [Double] = [], blocked: [Double] = []
  let core = 0.12 * L  // an arm may overlap the torso core in side view; cut only beyond it
  var f = 0.12
  while f <= 0.88 {  // rows between just below the shoulders and just above the hips
    let y = sh.y + (hp.y - sh.y) * f
    let cx = sh.x + (hp.x - sh.x) * f
    f += 0.04
    let my = Int(y.rounded(.toNearestOrEven))
    if !(0 <= my && my < mh) { continue }
    var x = cx, gap = 0
    var last: Double?
    var hitArm = false
    while abs(x - cx) <= 0.75 * L {
      let mx = Int(x.rounded(.toNearestOrEven))
      if !(0 <= mx && mx < mw) { break }
      if d * (x - cx) > core && segs.contains(where: { segDist(x, y, $0.0, $0.1) < armR }) {
        hitArm = true
        break
      }
      if mask[my * mw + mx] >= 0.5 {
        last = x
        gap = 0
      } else {
        gap += 1
        if gap > 2 { break }
      }
      x += d
    }
    if let l = last {
      if hitArm { blocked.append(l) } else { clean.append(l) }
    }
  }
  var edges = clean.count >= 4 ? clean : clean + blocked
  if edges.count < 4 { return nil }
  edges.sort { d * $0 < d * $1 }
  let e = edges[Int(Double(edges.count) * 0.8)]  // 80th percentile: robust to a stray forearm
  let lo = lmEdge - d * 0.3 * L, hi = lmEdge + d * 0.15 * L
  return d > 0 ? min(max(e, lo), hi) : max(min(e, lo), hi)
}

// MARK: - judge.py

private let MAX_GAP_MS = 250.0  // don't interpolate across frames further apart than this
private let REFINE_MS = 160.0  // half-window for the line fit (short: athletes dip at the line)
private let MIN_FIT_PTS = 5

/// judge.line_at: x of the line at height y; line = (x at top, x at bottom).
func lineAt(_ line: (Double, Double), _ y: Double) -> Double { line.0 + (line.1 - line.0) * y }

/// judge.line_through: (x at top, x at bottom) of the line through two points.
func lineThrough(_ p1: CGPoint, _ p2: CGPoint) -> (Double, Double) {
  if abs(p2.y - p1.y) < 1e-9 { return ((p1.x + p2.x) / 2, (p1.x + p2.x) / 2) }
  let slope = (p2.x - p1.x) / (p2.y - p1.y)
  let top = p1.x - slope * p1.y
  return (top, top + slope)
}

struct Sample {
  let t: Double  // ms
  let s: Double  // signed distance past the line (fraction of frame width)
}

struct Crossing {
  var t: Double  // best estimate (ms) - fitted when possible
  let interpolated: Double
  let firstFrameT: Double
  var method: String  // "fit" | "interpolated" | "frame"
  var uncertaintyMs: Double
  let frameGapMs: Double
  var fitPoints = 0
}

/// judge.FinishJudge.push for one pair of consecutive samples: the crossing
/// between them, or nil.
func crossingBetween(_ prev: Sample, _ cur: Sample) -> Crossing? {
  if !(prev.s < 0 && 0 <= cur.s) || cur.s - prev.s > 0.35 { return nil }  // jump: another person
  let gap = cur.t - prev.t
  let (tc, method) =
    gap <= MAX_GAP_MS
    ? (prev.t + gap * (-prev.s) / (cur.s - prev.s), "interpolated") : (cur.t, "frame")
  return Crossing(
    t: tc, interpolated: tc, firstFrameT: cur.t, method: method, uncertaintyMs: gap / 2,
    frameGapMs: gap)
}

private func fit(_ pts: [Sample]) -> (Double, Double)? {
  guard pts.count >= 2 else { return nil }
  let n = Double(pts.count)
  let t0 = pts[0].t
  let st = pts.reduce(0) { $0 + $1.t - t0 }
  let ss = pts.reduce(0) { $0 + $1.s }
  let stt = pts.reduce(0) { $0 + ($1.t - t0) * ($1.t - t0) }
  let sts = pts.reduce(0) { $0 + ($1.t - t0) * $1.s }
  let den = n * stt - st * st
  if den == 0 { return nil }
  let b = (n * sts - st * ss) / den
  return ((ss - b * st) / n - b * t0, b)
}

/// judge.FinishJudge.refine: straight-line fit within ±160 ms, outliers ahead
/// of the trend (arms) trimmed one-sidedly.
func refine(_ c0: Crossing, samples: [Sample]) -> Crossing {
  var c = c0
  var use = samples.filter { abs($0.t - c.interpolated) <= REFINE_MS }
  if use.count < MIN_FIT_PTS { return c }
  var f = fit(use)
  for _ in 0..<3 {
    guard let (a, b) = f else { break }
    let res = use.map { $0.s - (a + b * $0.t) }
    var mad = res.map(abs).sorted()[res.count / 2]
    if mad == 0 { mad = 1e-4 }
    let keep = zip(use, res).filter { -4.0 * mad < $0.1 && $0.1 < 2.0 * mad }.map { $0.0 }
    if keep.count < MIN_FIT_PTS || keep.count == use.count { break }
    use = keep
    f = fit(keep)
  }
  guard let (a, b) = f, b > 0 else { return c }
  let t = -a / b
  if abs(t - c.interpolated) > REFINE_MS { return c }
  let n = Double(use.count)
  let rms = (use.reduce(0) { $0 + pow($1.s - a - b * $1.t, 2) } / n).squareRoot()
  c.t = t
  c.method = "fit"
  c.fitPoints = use.count
  c.uncertaintyMs = max(2 * rms / b / n.squareRoot(), c.frameGapMs / 4)
  return c
}

// MARK: - The phone's driver

final class CrossingFinder {
  private let landmarker: PoseLandmarker

  init?(modelPath: String) {
    let o = PoseLandmarkerOptions()
    o.baseOptions.modelAssetPath = modelPath
    o.runningMode = .image
    // As detector.TorsoDetector: two people (coach, official) and keep the
    // largest torso, the nearest athlete.
    o.numPoses = 2
    o.minPoseDetectionConfidence = 0.5
    o.minPosePresenceConfidence = 0.5
    o.shouldOutputSegmentationMasks = true
    // CPU, as the Python: the GPU delegate returned empty segmentation masks
    // on the iPhone 13 (2026-10-15), so the chest front never came from the
    // silhouette. See VideoAnalyzer.makeLandmarker.
    o.baseOptions.delegate = .CPU
    guard let lm = try? PoseLandmarker(options: o) else { return nil }
    landmarker = lm
  }

  /// frames: upright BGRA FrameRing frames with host µs stamps, oldest first.
  /// lineA/lineB: the two points the user placed, as fractions of the frame.
  func findCrossing(
    frames: [(UnsafeMutableRawPointer, Double)], lineA: CGPoint, lineB: CGPoint,
    coarseStride: Int
  ) -> Result<CrossingOutput, CrossingError> {
    guard frames.count > 1 else { return .failure(CrossingError(message: "No frames recorded")) }
    let line = lineThrough(lineA, lineB)
    let w = FrameRing.width, h = FrameRing.height
    let t0 = frames[0].1

    var poses: [Int: FramePose?] = [:]
    func pose(_ i: Int) -> FramePose? {
      if let p = poses[i] { return p }
      let p = detectPose(frames[i].0)
      poses[i] = p
      return p
    }

    // Coarse pass (~60 fps). The direction comes from the torso centre.
    let coarseIdx = Array(stride(from: 0, to: frames.count, by: coarseStride))
    let seen = coarseIdx.compactMap { i in pose(i).map { (i, $0) } }
    guard let firstSeen = seen.first, let lastSeen = seen.last, seen.count >= 2 else {
      return .failure(CrossingError(message: "No runner found at the line"))
    }
    let travel = lastSeen.1.centreX - firstSeen.1.centreX
    guard abs(travel) > 0.01 else {
      return .failure(CrossingError(message: "The runner did not move across the line"))
    }
    let dir: Double = travel > 0 ? 1 : -1

    var detections: [Int: Detection?] = [:]
    func sample(_ i: Int) -> Sample? {
      let det: Detection?
      if let d = detections[i] {
        det = d
      } else {
        det = pose(i).flatMap {
          locateTorsoSegmentation(lm: $0.lm, mask: $0.mask, w: w, h: h, direction: dir)
        }
        detections[i] = det
      }
      guard let d = det else { return nil }
      return Sample(t: (frames[i].1 - t0) / 1000, s: dir * (d.x - lineAt(line, d.y)))
    }

    // First crossing among the coarse samples, as FinishJudge.push would see it.
    var prev: (Int, Sample)?
    var bracket: (Int, Int)?
    for i in coarseIdx {
      guard let s = sample(i) else { continue }
      if let p = prev, crossingBetween(p.1, s) != nil {
        bracket = (p.0, i)
        break
      }
      prev = (i, s)
    }
    guard let (lo, hi) = bracket else {
      return .failure(CrossingError(message: "Saw the runner but not the torso crossing the line"))
    }
    // Every frame inside the bracket, for the adjacent pair.
    var a = (lo, sample(lo)!), b = (hi, sample(hi)!)
    if hi - lo > 1 {
      for i in (lo + 1)..<hi {
        guard let s = sample(i) else { continue }
        if crossingBetween(a.1, s) != nil {
          b = (i, s)
          break
        }
        a = (i, s)
      }
    }
    guard let crossing = crossingBetween(a.1, b.1) else {
      return .failure(CrossingError(message: "Saw the runner but not the torso crossing the line"))
    }
    // Samples for the fit: everything analysed within ±160 ms, plus the coarse
    // frames there not yet analysed (the Python has every frame).
    for i in coarseIdx
    where abs((frames[i].1 - t0) / 1000 - crossing.interpolated) <= REFINE_MS {
      _ = sample(i)
    }
    let all = detections.keys.sorted().compactMap { sample($0) }
    let c = refine(crossing, samples: all)

    let ta = (frames[a.0].1 - t0) / 1000, tb = (frames[b.0].1 - t0) / 1000
    let shownIdx = abs(ta - c.t) <= abs(tb - c.t) ? a.0 : b.0
    let jpeg = render(
      frames[shownIdx].0, detection: detections[shownIdx] ?? nil, line: line, dir: dir,
      mask: (poses[shownIdx] ?? nil)?.mask)
    let span = frames.last!.1 - frames.first!.1
    let measured = span > 0 ? Double(frames.count - 1) / (span / 1e6) : 0
    return .success(
      CrossingOutput(
        crossHostUs: t0 + c.t * 1000, jpeg: jpeg, frameGapMs: c.frameGapMs,
        measuredFps: measured, timing: c.method, uncertaintyMs: c.uncertaintyMs))
  }

  private func detectPose(_ frame: UnsafeMutableRawPointer) -> FramePose? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreateWithBytes(
      nil, FrameRing.width, FrameRing.height, kCVPixelFormatType_32BGRA, frame,
      FrameRing.rowBytes, nil, nil, nil, &pb)
    guard let buffer = pb, let image = try? MPImage(pixelBuffer: buffer),
      let result = try? landmarker.detect(image: image)
    else { return nil }
    return framePose(result, w: FrameRing.width, h: FrameRing.height)
  }

  private func render(
    _ frame: UnsafeMutableRawPointer, detection: Detection?, line: (Double, Double), dir: Double,
    mask: [Float]?
  ) -> Data {
    drawOverlay(
      frame, w: FrameRing.width, h: FrameRing.height, rowBytes: FrameRing.rowBytes,
      detection: detection, line: line, dir: dir, mask: mask)
  }
}

/// The largest torso (detector.TorsoDetector: the nearest athlete) with its
/// mask, or nil.
func framePose(_ result: PoseLandmarkerResult, w: Int, h: Int) -> FramePose? {
  guard !result.landmarks.isEmpty else { return nil }
  let best = (0..<result.landmarks.count).max {
    torsoLen(result.landmarks[$0], Double(w), Double(h))
      < torsoLen(result.landmarks[$1], Double(w), Double(h))
  }!
  let lm = result.landmarks[best]
  guard lm.count > 24, best < result.segmentationMasks.count else { return nil }
  let m = result.segmentationMasks[best]
  guard m.width == w, m.height == h else { return nil }
  let mask = Array(UnsafeBufferPointer(start: m.float32Data, count: w * h))
  let cx = Double(lm[LS].x + lm[RS].x + lm[LH].x + lm[RH].x) / 4
  return FramePose(lm: lm, mask: mask, centreX: cx)
}

/// video.draw: red finish line, torso outline, dot (yellow before / green
/// after the line). BGRA frame of w x h in, JPEG out.
func drawOverlay(
  _ frame: UnsafeRawPointer, w: Int, h: Int, rowBytes: Int, detection: Detection?,
  line: (Double, Double), dir: Double, mask: [Float]? = nil
) -> Data {
  let W = Double(w), H = Double(h)
  guard
    let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rowBytes,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue),
    let data = ctx.data
  else { return Data() }
  memcpy(data, frame, rowBytes * h)
  // Diagnostic: the person's segmentation mask, tinted cyan, to check it
  // lies on the body (it is what the chest front is read from).
  if let m = mask, m.count == w * h {
    let px = data.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h {
      for x in 0..<w where m[y * w + x] >= 0.5 {
        let o = y * rowBytes + x * 4
        px[o] = UInt8((Int(px[o]) + 255) / 2)  // B
        px[o + 1] = UInt8((Int(px[o + 1]) + 210) / 2)  // G
        px[o + 2] = UInt8(Int(px[o + 2]) / 2)  // R
      }
    }
  }
  ctx.translateBy(x: 0, y: CGFloat(h))  // draw in top-left coordinates
  ctx.scaleBy(x: 1, y: -1)
  ctx.setStrokeColor(UIColor.systemRed.cgColor)
  ctx.setLineWidth(2)
  ctx.move(to: CGPoint(x: line.0 * W, y: 0))
  ctx.addLine(to: CGPoint(x: line.1 * W, y: H))
  ctx.strokePath()
  if let d = detection {
    ctx.setStrokeColor(UIColor(red: 0.24, green: 0.65, blue: 1, alpha: 1).cgColor)
    ctx.setLineWidth(1.5)
    let pts = d.torso.map { CGPoint(x: $0.x * W, y: $0.y * H) }
    ctx.addLines(between: pts + [pts[0]])
    ctx.strokePath()
    let past = dir * (d.x - lineAt(line, d.y)) >= 0
    ctx.setFillColor(past ? UIColor.systemGreen.cgColor : UIColor.systemYellow.cgColor)
    ctx.fillEllipse(in: CGRect(x: d.x * W - 5, y: d.y * H - 5, width: 10, height: 10))
  }
  guard let cg = ctx.makeImage() else { return Data() }
  return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) ?? Data()
}
