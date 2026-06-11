import AppKit
import AVFoundation

enum Notifier {
    private static let synth = AVSpeechSynthesizer()

    static func alert(voice: Bool, deviation: Double) {
        NSSound(named: "Sosumi")?.play()
        notification(
            title: "🚨 坐姿提醒",
            body: String(format: "已低头约 %.0f°，请坐直、抬头放松肩颈", -deviation)
        )
        if voice { speak("请注意坐姿，抬头挺胸") }
    }

    static func notification(title: String, body: String) {
        // osascript works without an app bundle or UNUserNotification entitlements.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        try? p.run()
    }

    static func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        synth.speak(u)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
