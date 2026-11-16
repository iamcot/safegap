// Ghi CSV mỗi frame vào Documents/logs (mở được trong app Tệp: Trên iPhone > SafeGap > logs).
import Foundation
import SafeGapCore

final class CSVLogger {
    private let queue = DispatchQueue(label: "safegap.csv")
    private var handle: FileHandle?
    private var buffer: [String] = []
    private var currentURL: URL?

    static var logsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("logs", isDirectory: true)
    }

    var url: URL? { queue.sync { currentURL } }
    var isRunning: Bool { queue.sync { handle != nil } }

    /// Mở file mới. Trả về đường dẫn file.
    @discardableResult
    func start() throws -> URL {
        try queue.sync {
            if let u = currentURL, handle != nil { return u }
            let dir = Self.logsDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd_HHmmss"
            let url = dir.appendingPathComponent("safegap_\(fmt.string(from: Date())).csv")
            FileManager.default.createFile(atPath: url.path, contents: Data((FrameLog.header + "\n").utf8))
            handle = try FileHandle(forWritingTo: url)
            try handle?.seekToEnd()
            currentURL = url
            return url
        }
    }

    func append(_ line: String) {
        queue.async {
            guard self.handle != nil else { return }
            self.buffer.append(line)
            if self.buffer.count >= 30 { self.flushLocked() }
        }
    }

    func flush() { queue.async { self.flushLocked() } }

    func stop() {
        queue.sync {
            flushLocked()
            try? handle?.close()
            handle = nil
            currentURL = nil
        }
    }

    private func flushLocked() {
        guard let h = handle, !buffer.isEmpty else { return }
        let data = Data((buffer.joined(separator: "\n") + "\n").utf8)
        buffer.removeAll(keepingCapacity: true)
        try? h.write(contentsOf: data)
    }
}
