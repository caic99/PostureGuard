import AVFoundation
import Vision

struct FaceReading {
    /// Vision face pitch in degrees (camera-relative). Nil if the OS didn't report it.
    let pitchDeg: Double?
    let yawDeg: Double?
    let rollDeg: Double?
    /// Normalized vertical center of the face in frame (0 = bottom, 1 = top).
    let centerY: Double
}

enum PostureError: Error, CustomStringConvertible {
    case noCamera
    case setupFailed

    var description: String {
        switch self {
        case .noCamera: return tr("找不到摄像头", "No camera found")
        case .setupFailed: return tr("摄像头初始化失败", "Camera setup failed")
        }
    }
}

/// Captures low-res frames from the built-in camera and runs Vision face
/// detection at a throttled interval, reporting the face pose via `onReading`.
/// `onReading(nil)` means no usable face in the frame.
final class FacePitchDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "posture.camera", qos: .utility)
    private var configured = false
    private var lastProcessed = Date.distantPast
    private let interval: TimeInterval
    var onReading: ((FaceReading?) -> Void)?

    init(interval: TimeInterval) {
        self.interval = max(0.2, interval)
        super.init()
    }

    static func ensureCameraAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        default: completion(false)
        }
    }

    func start() throws {
        if !configured {
            try configure()
            configured = true
        }
        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    private func configure() throws {
        session.sessionPreset = .vga640x480
        // Prefer the built-in camera: lid-angle compensation assumes the camera
        // is mounted in the lid, so a Continuity Camera iPhone would be wrong.
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.first
        guard let camera = builtIn ?? AVCaptureDevice.default(for: .video) else {
            throw PostureError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw PostureError.setupFailed }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw PostureError.setupFailed }
        session.addOutput(output)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= interval else { return }
        lastProcessed = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            onReading?(nil)
            return
        }
        // Largest face in frame = the user; ignore people in the background.
        guard let face = (request.results ?? []).max(by: {
            $0.boundingBox.width * $0.boundingBox.height <
            $1.boundingBox.width * $1.boundingBox.height
        }) else {
            onReading?(nil)
            return
        }
        func deg(_ n: NSNumber?) -> Double? { n.map { $0.doubleValue * 180 / .pi } }
        onReading?(FaceReading(
            pitchDeg: deg(face.pitch),
            yawDeg: deg(face.yaw),
            rollDeg: deg(face.roll),
            centerY: face.boundingBox.midY
        ))
    }
}
