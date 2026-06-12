import AppKit
import AVFoundation

enum Notifier {
    private static let synth = AVSpeechSynthesizer()

    static func alert(voice: Bool, deviation: Double) {
        NSSound(named: "Sosumi")?.play()
        notification(
            title: tr("🚨 坐姿提醒", "🚨 Posture Alert"),
            body: L10n.isChinese
                ? String(format: "已低头约 %.0f°，请坐直、抬头放松肩颈", -deviation)
                : String(format: "Head down ~%.0f° — sit up and relax your neck", -deviation)
        )
        if voice { speak(tr("请注意坐姿，抬头挺胸", "Please sit up straight")) }
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
        u.voice = bestVoice(for: L10n.speechLanguageCode)
        synth.speak(u)
    }

    /// Highest-quality installed system voice for the language
    /// (premium > enhanced > default — download better ones in
    /// System Settings → Accessibility → Spoken Content → System Voice).
    /// Siri voices are not exposed through this API (verified on macOS 26),
    /// so this is as close to Siri as third-party apps can get.
    private static func bestVoice(for lang: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == lang
                && !$0.identifier.contains("eloquence")               // robotic
                && !$0.identifier.contains("speech.synthesis.voice")  // novelty
        }
        return candidates.max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? AVSpeechSynthesisVoice(language: lang)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
