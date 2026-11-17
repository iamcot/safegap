// Một dòng CSV mỗi frame để debug sau chuyến đi.
// 11 cột đầu trùng tên với CSV của proto/run_video.py, nên `python -m proto.eval` đọc được log từ iPhone.
import Foundation

public enum FrameLog {
    public static let header = [
        "frame", "t", "speed_kmh", "cls", "w_px", "d_raw", "d", "d_min", "level", "sound", "track_id",
        "time", "f_px", "f_source", "n_dets", "infer_ms", "speed_acc_kmh", "thermal", "lane", "pitch_deg", "y_horizon",
        "lane_debug", "light_debug",
    ].joined(separator: ",")

    public struct Extra: Sendable {
        public var time: String
        public var fPx: Double
        public var fSource: FocalSource
        public var nDets: Int
        public var inferMs: Double
        public var speedAccuracyKmh: Double?
        public var thermal: ThermalLevel
        /// Vạch làn đang bám: "LR", "L", "R" hoặc rỗng (dùng ROI hiệu chỉnh).
        public var lane: String
        public var pitchDeg: Double?
        public var yHorizon: Double?
        /// Làn: vạch thô (c0/c1 trái, phải), có dò theo cổng không, số vệt bỏ vì trên thân xe, lý do bỏ, mô hình làn.
        public var laneDebug: String = ""
        /// Đèn: màu thô frame này / màu đã chốt, chiều cao khung.
        public var lightDebug: String = ""

        public init(time: String, fPx: Double, fSource: FocalSource, nDets: Int, inferMs: Double, speedAccuracyKmh: Double?,
                    thermal: ThermalLevel = .nominal, lane: String = "",
                    pitchDeg: Double? = nil, yHorizon: Double? = nil) {
            self.time = time; self.fPx = fPx; self.fSource = fSource
            self.nDets = nDets; self.inferMs = inferMs; self.speedAccuracyKmh = speedAccuracyKmh
            self.thermal = thermal
            self.lane = lane
            self.pitchDeg = pitchDeg
            self.yHorizon = yHorizon
        }
    }

    public static func row(_ r: FrameResult, _ e: Extra) -> String {
        [
            String(r.frame), num(r.t, 4), opt(r.speedKmh, 2), r.cls ?? "", opt(r.wPx, 2), opt(r.dRaw, 3), opt(r.d, 3),
            opt(r.dMin, 1), r.level.rawValue, r.sound ? "True" : "False", r.trackId.map(String.init) ?? "",
            e.time, num(e.fPx, 2), e.fSource.rawValue, String(e.nDets), num(e.inferMs, 1), opt(e.speedAccuracyKmh, 2), e.thermal.rawValue, e.lane,
            opt(e.pitchDeg, 2), opt(e.yHorizon, 1), clean(e.laneDebug), clean(e.lightDebug),
        ].joined(separator: ",")
    }

    static func clean(_ s: String) -> String { s.replacingOccurrences(of: ",", with: ";") }

    static func num(_ v: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", v)
    }

    static func opt(_ v: Double?, _ digits: Int) -> String {
        v.map { num($0, digits) } ?? ""
    }
}
