// Lưu hiệu chỉnh theo từng máy trong UserDefaults (không đồng bộ giữa các máy).
import Foundation
import SafeGapCore

enum CalibrationStore {
    static var defaults: UserDefaults { .standard }

    /// Ví dụ "iPhone15,2". Trên Simulator trả về model giả lập.
    static var deviceModel: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: sys.machine)) { String(cString: $0) }
        }
    }

    static func load(key: String) -> DeviceCalibration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DeviceCalibration.self, from: data)
    }

    static func save(_ c: DeviceCalibration) {
        var c = c
        c.updatedAt = Date()
        if let data = try? JSONEncoder().encode(c) { defaults.set(data, forKey: c.storageKey) }
    }

    static func remove(key: String) { defaults.removeObject(forKey: key) }
}
