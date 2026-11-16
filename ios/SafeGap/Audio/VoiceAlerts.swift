// Đọc cảnh báo bằng giọng tiếng Việt có sẵn trên máy (offline), theo VoicePolicy trong SafeGapCore
// (ưu tiên, nghỉ, không nói đè). Gọi từ hàng đợi camera; việc nói chạy trên main.
import AVFoundation
import Foundation
import SafeGapCore

final class VoiceAlerts: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var policy = VoicePolicy()
    private var speaking = false
    private lazy var voice: AVSpeechSynthesisVoice? = AVSpeechSynthesisVoice(language: "vi-VN")

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Đưa câu vào hàng chờ (bị bỏ nếu đang trong thời gian nghỉ).
    func offer(_ m: VoiceMessage) {
        lock.lock()
        policy.offer(m)
        lock.unlock()
    }

    /// Gọi mỗi frame: nói câu tiếp theo nếu đến lượt.
    func tick(t: Double) {
        lock.lock()
        let m = policy.next(t: t, speaking: speaking)
        if m != nil { speaking = true }
        lock.unlock()
        guard let m else { return }
        DispatchQueue.main.async { [weak self] in self?.speak(m.text) }
    }

    private func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        u.volume = 1
        synth.speak(u)
    }

    private func done() {
        lock.lock()
        speaking = false
        lock.unlock()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { done() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { done() }
}
