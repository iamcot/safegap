// Lịch chạy các model theo mức nhiệt và trạng thái xe (docs/DRIVER_ASSIST.md, A2).
// Mở rộng FrameThrottle: mỗi tác vụ một fps mục tiêu. Máy nóng thì cắt tác vụ phụ trước, đo khoảng cách xe trước sau cùng.
import Foundation

public enum InferenceTask: String, CaseIterable, Codable, Sendable {
    /// YOLO xe phía trước + khoảng cách (tính năng chính).
    case vehicles
    /// Dò biển + đèn trên vùng cắt (giai đoạn B/C). Hiện đèn lấy chung lượt YOLO xe nên chưa có model riêng.
    case signsLights
    /// Classifier mẫu xe phía trước (giai đoạn D).
    case carModel
}

public struct InferenceScheduler: Equatable, Sendable {
    /// fps mục tiêu theo tác vụ và mức nhiệt khi xe đang chạy. Thiếu = 0 (tắt).
    public var moving: [InferenceTask: [ThermalLevel: Double]]
    /// fps khi xe đứng yên: xe trước giảm (bớt nóng lúc chờ đèn), đèn/biển giữ.
    public var stopped: [InferenceTask: [ThermalLevel: Double]]
    private var throttles: [InferenceTask: FrameThrottle] = [:]

    public init(moving: [InferenceTask: [ThermalLevel: Double]], stopped: [InferenceTask: [ThermalLevel: Double]]) {
        self.moving = moving
        self.stopped = stopped
    }

    /// Mặc định: xe trước theo ThermalPolicy (chạy mát 15/12/8/5), biển+đèn 4/3/2/0, mẫu xe 1/1/0/0.
    public init(vehicles: ThermalPolicy) {
        let signs: [ThermalLevel: Double] = [.nominal: 4, .fair: 3, .serious: 2, .critical: 0]
        let car: [ThermalLevel: Double] = [.nominal: 1, .fair: 1, .serious: 0, .critical: 0]
        var vStop: [ThermalLevel: Double] = [:]
        for l in ThermalLevel.allCases { vStop[l] = min(5, vehicles.targetFps(l)) }
        self.init(moving: [.vehicles: vehicles.fps, .signsLights: signs, .carModel: car],
                  stopped: [.vehicles: vStop, .signsLights: signs, .carModel: [:]])
    }

    public func targetFps(_ task: InferenceTask, thermal: ThermalLevel, isStopped: Bool) -> Double {
        (isStopped ? stopped : moving)[task]?[thermal] ?? 0
    }

    /// Có chạy tác vụ này ở frame thời điểm t không.
    public mutating func shouldRun(_ task: InferenceTask, t: Double, thermal: ThermalLevel, isStopped: Bool) -> Bool {
        let fps = targetFps(task, thermal: thermal, isStopped: isStopped)
        var th = throttles[task] ?? FrameThrottle()
        let run = th.shouldProcess(t: t, targetFps: fps)
        throttles[task] = th
        return run
    }

    /// Các tác vụ chạy ở frame này.
    public mutating func due(t: Double, thermal: ThermalLevel, isStopped: Bool) -> Set<InferenceTask> {
        var out = Set<InferenceTask>()
        for task in InferenceTask.allCases where shouldRun(task, t: t, thermal: thermal, isStopped: isStopped) {
            out.insert(task)
        }
        return out
    }
}
