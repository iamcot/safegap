// 3 tiếng bíp khi vào RED. Phát cả khi gạt im lặng (category .playback), hạ nhỏ nhạc đang phát.
import AVFoundation

final class AlertSound {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private lazy var beeps: AVAudioPCMBuffer? = Self.makeBeeps(format: format)

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func prepare() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.duckOthers, .mixWithOthers])
        try? s.setActive(true)
        if !engine.isRunning { try? engine.start() }
    }

    func play() {
        guard let b = beeps else { return }
        if !engine.isRunning { prepare() }
        player.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private static func makeBeeps(format: AVAudioFormat, count: Int = 3, freq: Double = 1800,
                                  beepS: Double = 0.14, gapS: Double = 0.08) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let beepN = Int(beepS * sr), gapN = Int(gapS * sr)
        let total = count * (beepN + gapN)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let ch = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(total)
        let fade = Int(0.005 * sr)
        for k in 0..<count {
            let start = k * (beepN + gapN)
            for i in 0..<beepN {
                let env = min(1.0, Double(min(i, beepN - 1 - i)) / Double(fade))
                ch[start + i] = Float(0.8 * env * sin(2 * .pi * freq * Double(i) / sr))
            }
            for i in 0..<gapN { ch[start + beepN + i] = 0 }
        }
        return buf
    }
}
