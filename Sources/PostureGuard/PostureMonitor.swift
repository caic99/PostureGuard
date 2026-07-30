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
    /// True when this sample is the median result of a camera burst (one per
    /// check), false for continuous 2 Hz samples. The scheduler only reacts
    /// to burst results when planning checks — leftover continuous samples
    /// arriving right after a tracking session ends must not be mistaken for
    /// a fresh check result.
    var fromBurst = false
}

/// A head-pitch measurement plus whether lid compensation was applied.
/// The two are different reference frames (gravity vs camera), so a baseline
/// captured in one must never be compared against samples from the other.
struct HeadPitchReading {
    let deg: Double
    let lidCompensated: Bool
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
    /// Whether the persisted baseline includes lid compensation.
    /// nil = legacy baseline from before this flag existed — adopt the first
    /// sample's reference frame instead of tripping a false mismatch (on
    /// lidless Macs the legacy baseline was numerically uncompensated anyway).
    private var neutralCompensated: Bool?
    private var calibrationBuf: [(deg: Double, comp: Bool)] = []
    private var calibrationStart: Date?
    private var badSince: Date?
    private var lastAlert: Date?
    private var paused = false
    private var noFaceSince: Date?
    /// Brief detection dropouts must not reset the sustained-slouch clock —
    /// mid-slouch is exactly when Vision loses the face intermittently.
    private let noFaceGraceSec: TimeInterval = 5
    /// Consecutive-mismatch weight before warning that lid data no longer
    /// matches the calibration (20 ≈ 10 s realtime, or 2 bursts at weight 10).
    private var mismatchStreak = 0
    /// Re-arm the mismatch warning after a cooldown so a transient HID glitch
    /// can't permanently consume the only notification.
    private var lastMismatchNotice: Date?
    private let mismatchNoticeCooldown: TimeInterval = 1800

    var onSample: ((PostureSample) -> Void)?
    var onAlert: ((Double) -> Void)?
    var onCalibrated: ((Double) -> Void)?
    /// Lid compensation availability flipped vs. the calibrated baseline and
    /// stayed that way — judgment is suspended; the user should recalibrate.
    var onCompensationMismatch: (() -> Void)?

    /// Whether a baseline exists. Synchronous so the scheduler can decide
    /// between a fast calibration burst and a regular check.
    var isCalibrated: Bool { q.sync { neutral != nil } }

    init(config: Config) {
        self.config = config
        if defaults.object(forKey: "neutralDeg") != nil {
            // A baseline calibrated under the opposite pitch sign is meaningless — drop it.
            let storedSign = defaults.object(forKey: "neutralSign") as? Double ?? config.pitchSign
            if storedSign == config.pitchSign {
                neutral = defaults.double(forKey: "neutralDeg")
                neutralCompensated = defaults.object(forKey: "neutralComp") as? Bool
            } else {
                defaults.removeObject(forKey: "neutralDeg")
            }
        }
    }

    func process(face: FaceReading?, lidAngle: Double?) {
        q.async { self._process(face: face, lidAngle: lidAngle) }
    }

    /// Duty-cycle entry point: one median head pitch per camera burst.
    /// A bad check never alerts by itself — it reports `.slouching`, which the
    /// scheduler answers by escalating to continuous tracking (`process`),
    /// where the sustained-duration logic confirms and alerts.
    func processBurst(head: Double?, compensated: Bool, visionPitch: Double?, lidAngle: Double?) {
        q.async {
            self._processBurst(head: head, compensated: compensated,
                               visionPitch: visionPitch, lidAngle: lidAngle)
        }
    }

    /// Reset per-session signal state before a continuous tracking session so
    /// stale smoothing/duration from an earlier session can't trigger instantly.
    func beginContinuous() {
        q.async {
            self.smoothed = nil
            self.badSince = nil
            self.noFaceSince = nil
        }
    }

    func recalibrate() {
        q.async {
            self.neutral = nil
            self.smoothed = nil
            self.calibrationBuf.removeAll()
            self.calibrationStart = nil
            self.badSince = nil
            self.noFaceSince = nil
            self.mismatchStreak = 0
            self.lastMismatchNotice = nil
            self.defaults.removeObject(forKey: "neutralDeg")
            self.defaults.removeObject(forKey: "neutralComp")
            self.neutralCompensated = nil
        }
    }

    func setPaused(_ p: Bool) {
        q.async {
            self.paused = p
            if p { self.badSince = nil }
        }
    }

    func setConfig(_ c: Config) {
        q.async { self.config = c }
    }

    /// Camera-relative face pitch → gravity-referenced head pitch (positive = up).
    /// Returns nil when the head is turned too far sideways for a reliable pitch.
    /// Lid compensation only applies within a sane open-lid range; outside it
    /// (clamshell, sensor glitch) the reading is flagged as uncompensated.
    static func headPitch(face: FaceReading, lid: Double?, config: Config) -> HeadPitchReading? {
        guard let raw = face.pitchDeg else { return nil }
        if let yaw = face.yawDeg, abs(yaw) > 35 { return nil }
        var h = config.pitchSign * raw
        if let lid, (45...180).contains(lid) {
            h += lid - 90
            return HeadPitchReading(deg: h, lidCompensated: true)
        }
        return HeadPitchReading(deg: h, lidCompensated: false)
    }

    // MARK: - Continuous path

    private func _process(face: FaceReading?, lidAngle: Double?) {
        var sample = PostureSample(lidAngle: lidAngle)
        if paused {
            sample.state = .paused
            onSample?(sample)
            return
        }
        guard let face, let rawPitch = face.pitchDeg,
              let reading = Self.headPitch(face: face, lid: lidAngle, config: config) else {
            markNoFace(&sample)
            onSample?(sample)
            return
        }
        if neutral != nil, !frameMatchesBaseline(reading.lidCompensated) {
            // Different reference frame than the baseline (lid sensor failed or
            // recovered mid-session) — comparing would produce a huge phantom
            // deviation. Suspend judgment on this sample instead.
            registerMismatch(weight: 1)
            markNoFace(&sample)
            onSample?(sample)
            return
        }
        mismatchStreak = 0
        noFaceSince = nil

        let head = reading.deg
        sample.visionPitchDeg = rawPitch
        sample.faceCenterY = face.centerY
        sample.headPitchDeg = head

        let a = config.smoothing
        smoothed = smoothed.map { $0 * (1 - a) + head * a } ?? head
        sample.smoothedDeg = smoothed

        guard let neutral else {
            if calibrationStart == nil { calibrationStart = Date() }
            calibrationBuf.append((head, reading.lidCompensated))
            sample.state = .calibrating
            if Date().timeIntervalSince(calibrationStart!) >= config.autoCalibrateSec {
                // Use the majority reference frame — a flaky lid read during
                // the window must not poison the median with ±(lid-90)° jumps.
                let comp = calibrationBuf.filter { $0.comp }
                let uncomp = calibrationBuf.filter { !$0.comp }
                let winner = comp.count >= uncomp.count ? comp : uncomp
                if winner.count >= 6 {
                    let median = winner.map { $0.deg }.sorted()[winner.count / 2]
                    setNeutral(median, compensated: comp.count >= uncomp.count)
                }
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
            if deviation >= -max(0, config.thresholdDeg - config.hysteresisDeg) {
                badSince = nil
            }
            sample.state = .good
        }
        onSample?(sample)
    }

    // MARK: - Burst path

    private func _processBurst(head: Double?, compensated: Bool, visionPitch: Double?, lidAngle: Double?) {
        var sample = PostureSample(lidAngle: lidAngle, visionPitchDeg: visionPitch)
        sample.fromBurst = true
        sample.headPitchDeg = head
        if paused {
            sample.state = .paused
            onSample?(sample)
            return
        }
        guard let head else {
            sample.state = .noFace
            onSample?(sample)
            return
        }
        guard let neutral else {
            // The whole calibration burst (median over ~18 frames) is the baseline.
            setNeutral(head, compensated: compensated)
            sample.neutralDeg = head
            sample.deviationDeg = 0
            sample.state = .good
            onSample?(sample)
            return
        }
        if !frameMatchesBaseline(compensated) {
            registerMismatch(weight: 10)
            sample.state = .noFace
            onSample?(sample)
            return
        }
        mismatchStreak = 0

        sample.neutralDeg = neutral
        let deviation = head - neutral
        sample.deviationDeg = deviation
        sample.state = deviation <= -config.thresholdDeg ? .slouching(seconds: 0) : .good
        onSample?(sample)
    }

    // MARK: - Helpers

    private func setNeutral(_ value: Double, compensated: Bool) {
        neutral = value
        neutralCompensated = compensated
        defaults.set(value, forKey: "neutralDeg")
        defaults.set(config.pitchSign, forKey: "neutralSign")
        defaults.set(compensated, forKey: "neutralComp")
        onCalibrated?(value)
    }

    private func markNoFace(_ sample: inout PostureSample) {
        if noFaceSince == nil { noFaceSince = Date() }
        if Date().timeIntervalSince(noFaceSince!) >= noFaceGraceSec {
            badSince = nil
        }
        sample.state = .noFace
    }

    /// True when the sample's reference frame is usable against the baseline.
    /// A legacy baseline (nil flag) adopts the first sample's frame once.
    private func frameMatchesBaseline(_ compensated: Bool) -> Bool {
        guard let stored = neutralCompensated else {
            neutralCompensated = compensated
            defaults.set(compensated, forKey: "neutralComp")
            return true
        }
        return compensated == stored
    }

    private func registerMismatch(weight: Int) {
        mismatchStreak += weight
        guard mismatchStreak >= 20 else { return }
        if lastMismatchNotice == nil
            || Date().timeIntervalSince(lastMismatchNotice!) >= mismatchNoticeCooldown {
            lastMismatchNotice = Date()
            onCompensationMismatch?()
        }
    }
}
