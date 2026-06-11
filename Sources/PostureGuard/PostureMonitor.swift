import Foundation

enum PostureState: Equatable {
    case paused
    case noFace
    case calibrating
    case good
    case slouching(seconds: Double)
    case alerting
}

struct PostureSample {
    var lidAngle: Double?
    var visionPitchDeg: Double?
    /// Normalized vertical face center in frame (0 bottom, 1 top), for debugging.
    var faceCenterY: Double?
    /// Lid-compensated head pitch relative to horizontal, positive = up.
    var headPitchDeg: Double?
    var smoothedDeg: Double?
    var neutralDeg: Double?
    /// smoothed - neutral; negative = head lower than calibrated posture.
    var deviationDeg: Double?
    var state: PostureState = .noFace
}

/// Combines lid angle and face pitch into a gravity-referenced head pitch,
/// tracks deviation from a calibrated neutral posture, and decides when to alert.
///
/// Geometry: with the base flat on a desk, the camera tilts up from horizontal
/// by (lidAngle - 90)°. Vision reports the face pitch relative to the camera,
/// so trueHeadPitch = cameraRelativePitch + (lidAngle - 90). This makes the
/// measurement invariant to the user re-tilting the screen.
final class PostureMonitor {
    private let q = DispatchQueue(label: "posture.monitor")
    private let defaults = UserDefaults.standard
    private var config: Config

    private var smoothed: Double?
    private var neutral: Double?
    private var calibrationBuf: [Double] = []
    private var calibrationStart: Date?
    private var badSince: Date?
    private var lastAlert: Date?
    private var paused = false
    /// Burst mode: the previous check found bad posture; the next one confirms.
    private var suspect = false

    var onSample: ((PostureSample) -> Void)?
    var onAlert: ((Double) -> Void)?
    var onCalibrated: ((Double) -> Void)?

    init(config: Config) {
        self.config = config
        if defaults.object(forKey: "neutralDeg") != nil {
            // A baseline calibrated under the opposite pitch sign is meaningless — drop it.
            let storedSign = defaults.object(forKey: "neutralSign") as? Double ?? config.pitchSign
            if storedSign == config.pitchSign {
                neutral = defaults.double(forKey: "neutralDeg")
            } else {
                defaults.removeObject(forKey: "neutralDeg")
            }
        }
    }

    func process(face: FaceReading?, lidAngle: Double?) {
        q.async { self._process(face: face, lidAngle: lidAngle) }
    }

    /// Duty-cycle entry point: one median head pitch per camera burst.
    /// First bad check only marks suspicion; the follow-up check confirms and
    /// alerts — the burst-mode equivalent of "sustained for N seconds".
    func processBurst(head: Double?, visionPitch: Double?, lidAngle: Double?) {
        q.async { self._processBurst(head: head, visionPitch: visionPitch, lidAngle: lidAngle) }
    }

    private func _processBurst(head: Double?, visionPitch: Double?, lidAngle: Double?) {
        var sample = PostureSample(lidAngle: lidAngle, visionPitchDeg: visionPitch)
        sample.headPitchDeg = head
        if paused {
            sample.state = .paused
            onSample?(sample)
            return
        }
        guard let head else {
            suspect = false
            sample.state = .noFace
            onSample?(sample)
            return
        }
        guard let neutral else {
            // The whole burst (median over ~8 s) doubles as the calibration sample.
            self.neutral = head
            defaults.set(head, forKey: "neutralDeg")
            defaults.set(config.pitchSign, forKey: "neutralSign")
            onCalibrated?(head)
            sample.neutralDeg = head
            sample.deviationDeg = 0
            sample.state = .good
            onSample?(sample)
            return
        }
        sample.neutralDeg = neutral
        let deviation = head - neutral
        sample.deviationDeg = deviation

        if deviation <= -config.thresholdDeg {
            if suspect {
                sample.state = .alerting
                if lastAlert == nil || Date().timeIntervalSince(lastAlert!) >= config.cooldownSec {
                    lastAlert = Date()
                    onAlert?(deviation)
                }
            } else {
                suspect = true
                sample.state = .slouching(seconds: 0)
            }
        } else {
            suspect = false
            sample.state = .good
        }
        onSample?(sample)
    }

    func recalibrate() {
        q.async {
            self.neutral = nil
            self.smoothed = nil
            self.calibrationBuf.removeAll()
            self.calibrationStart = nil
            self.badSince = nil
            self.suspect = false
            self.defaults.removeObject(forKey: "neutralDeg")
        }
    }

    func setPaused(_ p: Bool) {
        q.async {
            self.paused = p
            if p {
                self.badSince = nil
                self.suspect = false
            }
        }
    }

    func setConfig(_ c: Config) {
        q.async { self.config = c }
    }

    /// Camera-relative face pitch → gravity-referenced head pitch (positive = up).
    /// Returns nil when the head is turned too far sideways for a reliable pitch.
    /// Lid compensation only applies within a sane open-lid range; outside it
    /// (clamshell, sensor glitch) the camera-relative value is used as-is.
    static func headPitch(face: FaceReading, lid: Double?, config: Config) -> Double? {
        guard let raw = face.pitchDeg else { return nil }
        if let yaw = face.yawDeg, abs(yaw) > 35 { return nil }
        var h = config.pitchSign * raw
        if let lid, (45...180).contains(lid) { h += lid - 90 }
        return h
    }

    private func _process(face: FaceReading?, lidAngle: Double?) {
        var sample = PostureSample(lidAngle: lidAngle)
        if paused {
            sample.state = .paused
            onSample?(sample)
            return
        }
        guard let face, let rawPitch = face.pitchDeg,
              let head = Self.headPitch(face: face, lid: lidAngle, config: config) else {
            badSince = nil
            sample.state = .noFace
            onSample?(sample)
            return
        }
        sample.visionPitchDeg = rawPitch
        sample.faceCenterY = face.centerY
        sample.headPitchDeg = head

        let a = config.smoothing
        smoothed = smoothed.map { $0 * (1 - a) + head * a } ?? head
        sample.smoothedDeg = smoothed

        guard let neutral else {
            if calibrationStart == nil { calibrationStart = Date() }
            calibrationBuf.append(head)
            sample.state = .calibrating
            if Date().timeIntervalSince(calibrationStart!) >= config.autoCalibrateSec,
               calibrationBuf.count >= 6 {
                let median = calibrationBuf.sorted()[calibrationBuf.count / 2]
                self.neutral = median
                defaults.set(median, forKey: "neutralDeg")
                defaults.set(config.pitchSign, forKey: "neutralSign")
                onCalibrated?(median)
            }
            onSample?(sample)
            return
        }

        sample.neutralDeg = neutral
        let deviation = smoothed! - neutral
        sample.deviationDeg = deviation

        if deviation <= -config.thresholdDeg {
            if badSince == nil { badSince = Date() }
            let dur = Date().timeIntervalSince(badSince!)
            if dur >= config.durationSec {
                sample.state = .alerting
                if lastAlert == nil || Date().timeIntervalSince(lastAlert!) >= config.cooldownSec {
                    lastAlert = Date()
                    onAlert?(deviation)
                }
            } else {
                sample.state = .slouching(seconds: dur)
            }
        } else {
            if deviation >= -(config.thresholdDeg - config.hysteresisDeg) {
                badSince = nil
            }
            sample.state = .good
        }
        onSample?(sample)
    }
}
