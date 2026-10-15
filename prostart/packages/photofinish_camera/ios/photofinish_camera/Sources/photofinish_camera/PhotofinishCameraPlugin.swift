import AVFoundation
import Flutter
import UIKit

/// Channel "prostart/photofinish" and the preview view. The Dart side is
/// lib/photofinish_camera.dart; the camera itself is PhotofinishCamera.swift.
public class PhotofinishCameraPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let camera: PhotofinishCamera
  private let videos: VideoAnalyzer

  init(channel: FlutterMethodChannel, modelPath: String?) {
    self.channel = channel
    self.camera = PhotofinishCamera(modelPath: modelPath)
    self.videos = VideoAnalyzer(modelPath: modelPath)
    super.init()
    camera.onStatus = { [weak self] state in
      self?.send("onStatus", ["state": state])
    }
    camera.onResult = { [weak self] r in
      self?.send("onResult", [
        "crossPhoneUs": r.crossHostUs,
        "jpeg": FlutterStandardTypedData(bytes: r.jpeg),
        "frameGapMs": r.frameGapMs,
        "measuredFps": r.measuredFps,
        "timing": r.timing,
        "uncertaintyMs": r.uncertaintyMs,
      ])
    }
    camera.onError = { [weak self] message in
      self?.send("onError", ["message": message])
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "prostart/photofinish", binaryMessenger: registrar.messenger())
    let key = registrar.lookupKey(
      forAsset: "assets/pose_landmarker_full.task", fromPackage: "photofinish_camera")
    let instance = PhotofinishCameraPlugin(
      channel: channel, modelPath: Bundle.main.path(forResource: key, ofType: nil))
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.register(
      PreviewFactory(camera: instance.camera), withId: "prostart/camera_preview")
  }

  private func send(_ method: String, _ args: [String: Any]) {
    DispatchQueue.main.async { self.channel.invokeMethod(method, arguments: args) }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      camera.start { info, error in
        DispatchQueue.main.async {
          if let info = info {
            UIApplication.shared.isIdleTimerDisabled = true
            result(info)
          } else {
            result(FlutterError(code: "camera", message: error, details: nil))
          }
        }
      }
    case "stop":
      UIApplication.shared.isIdleTimerDisabled = false
      camera.stop()
      result(nil)
    case "setLine":
      camera.setLine(
        CGPoint(x: args["x1"] as? Double ?? 0.5, y: args["y1"] as? Double ?? 0),
        CGPoint(x: args["x2"] as? Double ?? 0.5, y: args["y2"] as? Double ?? 1))
      result(nil)
    case "arm":
      camera.arm(
        goHostUs: args["goPhoneUs"] as? Double ?? 0,
        timeoutS: args["timeoutS"] as? Double ?? 30)
      result(nil)
    case "disarm":
      camera.disarm()
      result(nil)
    case "pickVideo":
      videos.pick { info, error in
        DispatchQueue.main.async {
          if let e = error {
            result(FlutterError(code: "video", message: e, details: nil))
          } else {
            result(info)  // nil: cancelled
          }
        }
      }
    case "analyzeVideo":
      videos.analyze(
        path: args["path"] as? String ?? "",
        lineA: CGPoint(x: args["x1"] as? Double ?? 0.5, y: args["y1"] as? Double ?? 0),
        lineB: CGPoint(x: args["x2"] as? Double ?? 0.5, y: args["y2"] as? Double ?? 1)
      ) { out, error in
        DispatchQueue.main.async {
          if let e = error {
            result(FlutterError(code: "video", message: e, details: nil))
          } else {
            result(out)
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

final class PreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let camera: PhotofinishCamera
  init(camera: PhotofinishCamera) { self.camera = camera }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
    -> FlutterPlatformView
  {
    PreviewPlatformView(camera: camera)
  }
}

final class PreviewPlatformView: NSObject, FlutterPlatformView {
  private let preview: PreviewUIView
  init(camera: PhotofinishCamera) {
    preview = PreviewUIView()
    super.init()
    preview.attach(camera.session)
  }
  func view() -> UIView { preview }
}

/// Shows the whole frame, upright (portrait), without cropping: the Dart side
/// sizes this view to the frame's aspect ratio, so a point on screen and the
/// same normalised point in the analysed frame are the same place.
final class PreviewUIView: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

  func attach(_ session: AVCaptureSession) {
    backgroundColor = .black
    previewLayer.session = session
    previewLayer.videoGravity = .resizeAspect
    rotateUpright()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    rotateUpright()
  }

  private func rotateUpright() {
    guard let c = previewLayer.connection else { return }
    if #available(iOS 17.0, *) {
      if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
    } else if c.isVideoOrientationSupported {
      c.videoOrientation = .portrait
    }
  }
}
