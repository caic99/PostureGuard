import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: Config
    private var statusItem: NSStatusItem!
    private var lid: LidAngleSensor?
    private var detector: FacePitchDetector?
    private var monitor: PostureMonitor!
    private var paused = false

    // Duty-cycle (burst) mode state, active when checkIntervalSec > 0: the
    // camera only runs for `burstSec` per check, then a timer schedules the
    // next one. A bad check is rechecked after `recheckSec` before alerting.
    private var burstTimer: Timer?
    private var bursting = false
    private var burstID = 0
    private var burstHeads: [Double] = []
    private var burstVisions: [Double] = []
    private var burstFrames = 0
    private var lastCheck: Date?
    private var lastState: PostureState = .noFace
    private let burstSec: TimeInterval = 8
    private let recheckSec: TimeInterval = 60
    private let burstWarmupFrames = 2

    // On AC power there's no battery to protect — check 3x as often.
    private let power = PowerSource()
    private var effectiveCheckInterval: TimeInterval {
        guard PowerSource.isOnAC() else { return config.checkIntervalSec }
        return min(config.checkIntervalSec, max(30, config.checkIntervalSec / 3))
    }

    private var infoLine: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var voiceItem: NSMenuItem!
    private var showAngleItem: NSMenuItem!
    private var thresholdMenu: NSMenu!
    private var intervalMenu: NSMenu!

    private var isRealtime: Bool { config.checkIntervalSec <= 0 }

    init(config: Config) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🪑…"
        buildMenu()

        if !config.noLid {
            lid = LidAngleSensor()
            if lid == nil {
                log("⚠️ 未找到盖角传感器（需要较新的 Apple Silicon MacBook），将跳过屏幕角度补偿")
            } else if config.debug, let a = lid?.read() {
                log("盖角传感器就绪，当前 \(Int(a))°")
            }
        }

        monitor = PostureMonitor(config: config)
        monitor.onSample = { [weak self] s in
            self?.debugPrint(s)
            DispatchQueue.main.async {
                guard let self else { return }
                self.render(s)
                // In burst mode each check emits exactly one sample after the
                // camera stops — that's the moment to plan the next check.
                if !self.isRealtime && !self.bursting && !self.paused {
                    self.scheduleNextBurst(after: s.state)
                }
            }
        }
        monitor.onAlert = { [weak self] deviation in
            let voice = self?.config.voice ?? false
            DispatchQueue.main.async { Notifier.alert(voice: voice, deviation: deviation) }
        }
        monitor.onCalibrated = { [weak self] n in
            self?.log(String(format: "已校准基准头部俯仰 %.1f°", n))
            DispatchQueue.main.async {
                Notifier.notification(title: "坐姿卫士", body: String(format: "已校准基准姿势（%.1f°），开始监测", n))
            }
        }

        log("摄像头 TCC 状态: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue) (0=未询问 1=受限 2=拒绝 3=已授权)")
        power.onChange = { [weak self] in
            guard let self, !self.isRealtime, !self.paused, !self.bursting,
                  self.burstTimer != nil else { return }
            if self.config.debug { self.log("电源状态变化 (AC=\(PowerSource.isOnAC()))，重新调度") }
            self.scheduleNextBurst(after: self.lastState)
        }
        power.startObserving()

        FacePitchDetector.ensureCameraAccess { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.log("摄像头权限回调: granted=\(granted)")
                if granted {
                    self.startMonitoring()
                } else {
                    self.statusItem.button?.title = "🪑📷✕"
                    self.log("没有摄像头权限：系统设置 → 隐私与安全性 → 摄像头")
                    Notifier.notification(title: "坐姿卫士", body: "没有摄像头权限，请在 系统设置 → 隐私与安全性 → 摄像头 中授权后重启应用")
                }
            }
        }
    }

    // MARK: - Monitoring lifecycle

    private func startMonitoring() {
        if detector == nil {
            let d = FacePitchDetector(interval: config.sampleInterval)
            d.onReading = { [weak self] face in
                guard let self else { return }
                if self.isRealtime {
                    self.monitor.process(face: face, lidAngle: self.lid?.read())
                } else {
                    let head = face.flatMap {
                        PostureMonitor.headPitch(face: $0, lid: self.lid?.read(), config: self.config)
                    }
                    DispatchQueue.main.async { self.collectBurstReading(head: head, vision: face?.pitchDeg) }
                }
            }
            detector = d
        }
        if isRealtime {
            do { try detector?.start() } catch { cameraFailed(error) }
        } else {
            performBurst()
        }
    }

    private func restartMonitoring() {
        burstTimer?.invalidate()
        burstTimer = nil
        bursting = false
        detector?.stop()
        guard !paused else { return }
        startMonitoring()
    }

    private func performBurst() {
        guard !paused, !bursting else { return }
        burstTimer?.invalidate()
        burstTimer = nil
        bursting = true
        burstID += 1
        let id = burstID
        burstHeads.removeAll()
        burstVisions.removeAll()
        burstFrames = 0
        do { try detector?.start() } catch {
            bursting = false
            cameraFailed(error)
            return
        }
        if config.debug { log("burst #\(id) 开始") }
        DispatchQueue.main.asyncAfter(deadline: .now() + burstSec) { [weak self] in
            self?.finishBurst(id: id)
        }
    }

    private func collectBurstReading(head: Double?, vision: Double?) {
        guard bursting else { return }
        burstFrames += 1
        // Skip the first frames while exposure/focus settle.
        guard burstFrames > burstWarmupFrames else { return }
        if let head {
            burstHeads.append(head)
            if let vision { burstVisions.append(vision) }
        }
    }

    private func finishBurst(id: Int) {
        guard bursting, id == burstID else { return }
        bursting = false
        detector?.stop()
        lastCheck = Date()
        if config.debug { log("burst #\(id) 结束: frames=\(burstFrames) 有效=\(burstHeads.count)") }
        // A couple of stray detections (someone walking by) shouldn't count.
        let head = burstHeads.count >= 3 ? median(burstHeads) : nil
        monitor.processBurst(head: head, visionPitch: median(burstVisions), lidAngle: lid?.read())
    }

    private func scheduleNextBurst(after state: PostureState) {
        lastState = state
        burstTimer?.invalidate()
        let delay: TimeInterval
        switch state {
        case .slouching, .alerting:
            delay = recheckSec
        default:
            delay = effectiveCheckInterval
        }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.performBurst()
        }
        RunLoop.main.add(t, forMode: .common)
        burstTimer = t
    }

    private func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.sorted()[xs.count / 2]
    }

    private func cameraFailed(_ error: Error) {
        statusItem.button?.title = "🪑⚠️"
        log("摄像头启动失败: \(error)")
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        infoLine = NSMenuItem(title: "等待数据…", action: nil, keyEquivalent: "")
        infoLine.isEnabled = false
        menu.addItem(infoLine)
        menu.addItem(.separator())

        let cal = NSMenuItem(title: "以当前姿势重新校准", action: #selector(recalibrate), keyEquivalent: "c")
        cal.target = self
        menu.addItem(cal)

        pauseItem = NSMenuItem(title: "暂停监测", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        let thresholdItem = NSMenuItem(title: "提醒阈值", action: nil, keyEquivalent: "")
        thresholdMenu = NSMenu()
        for v in [10.0, 15.0, 20.0, 25.0] {
            let i = NSMenuItem(title: "低头 \(Int(v))°", action: #selector(setThreshold(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = v
            thresholdMenu.addItem(i)
        }
        thresholdItem.submenu = thresholdMenu
        menu.addItem(thresholdItem)

        let intervalItem = NSMenuItem(title: "检测间隔", action: nil, keyEquivalent: "")
        intervalMenu = NSMenu()
        for (label, v) in [("实时（耗电）", 0.0), ("每 1 分钟", 60.0), ("每 3 分钟", 180.0), ("每 5 分钟", 300.0)] {
            let i = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = v
            intervalMenu.addItem(i)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        showAngleItem = NSMenuItem(title: "菜单栏显示角度", action: #selector(toggleShowAngle), keyEquivalent: "")
        showAngleItem.target = self
        menu.addItem(showAngleItem)

        voiceItem = NSMenuItem(title: "语音提醒", action: #selector(toggleVoice), keyEquivalent: "")
        voiceItem.target = self
        menu.addItem(voiceItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        refreshCheckmarks()
    }

    private func refreshCheckmarks() {
        for i in thresholdMenu.items {
            i.state = (i.representedObject as? Double) == config.thresholdDeg ? .on : .off
        }
        for i in intervalMenu.items {
            i.state = (i.representedObject as? Double) == config.checkIntervalSec ? .on : .off
        }
        showAngleItem.state = config.showAngle ? .on : .off
        voiceItem.state = config.voice ? .on : .off
        pauseItem.title = paused ? "继续监测" : "暂停监测"
    }

    // MARK: - Actions

    @objc private func recalibrate() {
        monitor.recalibrate()
        Notifier.notification(title: "坐姿卫士", body: "请以标准坐姿面对屏幕，正在采样校准…")
        if !isRealtime {
            burstTimer?.invalidate()
            burstTimer = nil
            bursting = false
            detector?.stop()
            performBurst()
        }
    }

    @objc private func togglePause() {
        paused.toggle()
        monitor.setPaused(paused)
        if paused {
            burstTimer?.invalidate()
            burstTimer = nil
            bursting = false
            detector?.stop()
            statusItem.button?.title = "🪑⏸"
        } else {
            startMonitoring()
        }
        refreshCheckmarks()
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        config.thresholdDeg = v
        applyConfig()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        config.checkIntervalSec = v
        applyConfig()
        restartMonitoring()
    }

    @objc private func toggleVoice() {
        config.voice.toggle()
        applyConfig()
    }

    @objc private func toggleShowAngle() {
        config.showAngle.toggle()
        applyConfig()
    }

    private func applyConfig() {
        config.persist()
        monitor.setConfig(config)
        refreshCheckmarks()
    }

    // MARK: - Rendering

    private func render(_ s: PostureSample) {
        let title: String
        func withAngle(_ emoji: String) -> String {
            config.showAngle ? String(format: "%@ %+.0f°", emoji, s.deviationDeg ?? 0) : emoji
        }
        switch s.state {
        case .paused:
            title = "🪑⏸"
        case .noFace:
            title = config.showAngle ? "🪑 –" : "🪑"
        case .calibrating:
            title = "🪑📐"
        case .good:
            title = withAngle("🙆")
        case .slouching:
            title = withAngle("🙇")
        case .alerting:
            title = withAngle("🚨")
        }
        statusItem.button?.title = title

        var top: [String] = []
        if let h = s.headPitchDeg { top.append(String(format: "头部 %+.1f°", h)) }
        if let n = s.neutralDeg { top.append(String(format: "基准 %+.1f°", n)) }
        var bottom: [String] = []
        if let lid = s.lidAngle { bottom.append(String(format: "盖角 %.0f°", lid)) }
        if let p = s.visionPitchDeg { bottom.append(String(format: "人脸 %+.1f°", p)) }
        var lines = [top, bottom].filter { !$0.isEmpty }.map { $0.joined(separator: " · ") }
        if !isRealtime {
            let iv = effectiveCheckInterval
            var status = iv >= 60
                ? "每 \(Int(iv / 60)) 分钟"
                : "每 \(Int(iv)) 秒"
            if PowerSource.isOnAC() { status += "⚡" }
            if case .slouching = s.state { status = "1 分钟后复查" }
            if let lc = lastCheck { status += " · 上次 " + Self.timeFmt.string(from: lc) }
            lines.append(status)
        }
        let text = lines.isEmpty ? "未检测到人脸" : lines.joined(separator: "\n")
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        infoLine.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: para,
        ])
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func debugPrint(_ s: PostureSample) {
        guard config.debug else { return }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        func fmt(_ v: Double?) -> String { v.map { String(format: "%+7.2f", $0) } ?? "      –" }
        let line = "\(f.string(from: Date())) lid=\(fmt(s.lidAngle)) vision=\(fmt(s.visionPitchDeg)) " +
              "cy=\(s.faceCenterY.map { String(format: "%.3f", $0) } ?? "–") " +
              "head=\(fmt(s.headPitchDeg)) smooth=\(fmt(s.smoothedDeg)) dev=\(fmt(s.deviationDeg)) \(s.state)"
        print(line)
        // stdout is lost when launched via `open`/LaunchServices — mirror to a file.
        Self.debugLog?.write((line + "\n").data(using: .utf8)!)
    }

    private static let debugLog: FileHandle? = {
        let path = "/tmp/posture-guard.debug.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        let h = FileHandle(forWritingAtPath: path)
        h?.seekToEndOfFile()
        return h
    }()

    private func log(_ msg: String) {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
        // stderr is lost when launched via `open` — mirror diagnostics too.
        Self.debugLog?.write((msg + "\n").data(using: .utf8)!)
    }
}
