import Foundation

struct Config {
    /// Deviation below the calibrated neutral pitch (degrees) that counts as slouching.
    var thresholdDeg: Double = 15
    /// Slouching must persist this long (seconds) before an alert fires.
    var durationSec: Double = 10
    /// Minimum time between alerts (seconds).
    var cooldownSec: Double = 60
    /// Recovery margin: posture counts as recovered at -(threshold - hysteresis).
    var hysteresisDeg: Double = 5
    /// Maps Vision pitch to "positive = head up". Flip with --invert-pitch if
    /// the sign turns out to be reversed on your OS version.
    var pitchSign: Double = -1
    /// EMA smoothing factor for the head pitch signal.
    var smoothing: Double = 0.3
    /// Seconds of camera frames to collect before auto-calibrating.
    var autoCalibrateSec: Double = 5
    /// Seconds between processed camera frames.
    var sampleInterval: TimeInterval = 0.5
    /// Seconds between duty-cycle checks; 0 keeps the camera running continuously.
    var checkIntervalSec: Double = 180
    var voice = false
    /// Show the live deviation angle next to the menu bar emoji.
    var showAngle = false
    var noLid = false
    var debug = false

    private static let defaultsKeys = ["thresholdDeg", "durationSec", "invertPitch", "voice"]

    /// Settings persisted from the menu UI, overridden by CLI flags.
    static func load(arguments: [String]) -> Config {
        var c = Config()
        let d = UserDefaults.standard
        if d.object(forKey: "thresholdDeg") != nil { c.thresholdDeg = d.double(forKey: "thresholdDeg") }
        if d.object(forKey: "durationSec") != nil { c.durationSec = d.double(forKey: "durationSec") }
        if d.object(forKey: "checkIntervalSec") != nil { c.checkIntervalSec = d.double(forKey: "checkIntervalSec") }
        if d.bool(forKey: "voice") { c.voice = true }
        if d.bool(forKey: "showAngle") { c.showAngle = true }

        var args = arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--debug": c.debug = true
            case "--voice": c.voice = true
            case "--no-lid": c.noLid = true
            case "--invert-pitch": c.pitchSign = 1
            case "--threshold": c.thresholdDeg = args.next().flatMap(Double.init) ?? c.thresholdDeg
            case "--duration": c.durationSec = args.next().flatMap(Double.init) ?? c.durationSec
            case "--interval": c.sampleInterval = args.next().flatMap(Double.init) ?? c.sampleInterval
            case "--check-interval": c.checkIntervalSec = args.next().flatMap(Double.init) ?? c.checkIntervalSec
            case "--reset":
                ["neutralDeg", "neutralSign", "thresholdDeg", "durationSec", "invertPitch",
                 "voice", "showAngle", "checkIntervalSec"]
                    .forEach { d.removeObject(forKey: $0) }
                print("已清除校准数据与设置")
                exit(0)
            case "--help", "-h":
                print("""
                PostureGuard 坐姿卫士 — 盖角传感器 + 人脸朝向的低头监测

                选项:
                  --threshold N       低头超过基准 N 度视为不良坐姿 (默认 15)
                  --check-interval N  间歇检测周期秒数, 0 = 摄像头常开实时监测 (默认 180)
                  --duration N        [仅实时模式] 持续 N 秒后才提醒 (默认 10)
                  --interval N        摄像头采样间隔秒 (默认 0.5)
                  --voice          语音提醒
                  --invert-pitch   反转俯仰方向 (调试时若发现抬头反而报警, 用这个)
                  --no-lid         禁用盖角补偿
                  --debug          在终端打印每次采样的角度数据
                  --reset          清除校准与设置后退出
                """)
                exit(0)
            default:
                FileHandle.standardError.write("未知参数: \(a)\n".data(using: .utf8)!)
                exit(2)
            }
        }
        return c
    }

    func persist() {
        let d = UserDefaults.standard
        d.set(thresholdDeg, forKey: "thresholdDeg")
        d.set(durationSec, forKey: "durationSec")
        d.set(checkIntervalSec, forKey: "checkIntervalSec")
        d.set(voice, forKey: "voice")
        d.set(showAngle, forKey: "showAngle")
    }
}
