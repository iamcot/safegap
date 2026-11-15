// Đọc Fixtures/golden.json (sinh bởi `python -m proto.fixtures`).
import Foundation
@testable import SafeGapCore

struct DetRow: Decodable {
    let det: Detection

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let x1 = try c.decode(Double.self), y1 = try c.decode(Double.self)
        let x2 = try c.decode(Double.self), y2 = try c.decode(Double.self)
        let cls = try c.decode(String.self)
        var conf = 1.0
        if !c.isAtEnd { conf = try c.decode(Double.self) }
        det = Detection(x1, y1, x2, y2, cls, conf)
    }
}

struct Golden: Decodable {
    struct LawCase: Decodable { let v: Double; let dMin: Double }
    struct ClassifyCase: Decodable { let d: Double; let dMin: Double; let level: Level }
    struct Dist: Decodable {
        struct W: Decodable { let f, wReal, wPx, d: Double }
        struct G: Decodable { let f, h, yBottom, yHorizon: Double; let d: Double? }
        struct F: Decodable { let dWidth: Double; let dGround: Double?; let far, d: Double }
        struct S: Decodable { let f, from, to, d: Double }
        let fromWidth: [W]
        let fromGround: [G]
        let fuse: [F]
        let scaleF: [S]
    }
    struct LaneCases: Decodable {
        struct PIP: Decodable { let x, y: Double; let inside: Bool }
        struct Sel: Decodable { let dets: [DetRow]; let ego: Int? }
        let frameW, frameH: Double
        let roiNorm: [Point]
        let pointInPolygon: [PIP]
        let selectEgo: [Sel]
    }
    struct IouCase: Decodable { let a, b: [Double]; let iou: Double }
    struct KalmanCase: Decodable {
        struct Step: Decodable { let dt, z, d, rate: Double }
        let d0, accelSigma, measRelSigma: Double
        let steps: [Step]
    }
    struct TrackerCase: Decodable {
        struct Step: Decodable { let boxes: [DetRow]; let ids: [Int]; let alive: [Int] }
        let iouMatch: Double
        let maxMissed: Int
        let steps: [Step]
    }
    struct AlertCase: Decodable {
        struct Step: Decodable { let t: Double; let v: Double?; let d: Double?; let level: Level; let sound: Bool; let dMin: Double? }
        let name: String
        let alert: AlertConfig
        let steps: [Step]
    }
    struct PipelineCase: Decodable {
        struct Out: Decodable {
            let frame: Int
            let t: Double
            let speedKmh: Double?
            let cls: String?
            let wPx, dRaw, d, dMin: Double?
            let level: Level
            let sound: Bool
            let trackId: Int?
        }
        struct Frame: Decodable { let frame: Int; let t: Double; let speedKmh: Double?; let dets: [DetRow]; let out: Out }
        let name: String
        let frameW, frameH, fPx: Double
        let config: AppConfig
        let frames: [Frame]
    }

    let law: LawConfig
    let lawCases: [LawCase]
    let classify: [ClassifyCase]
    let distance: Dist
    let lane: LaneCases
    let iou: [IouCase]
    let kalman: KalmanCase
    let tracker: TrackerCase
    let alert: [AlertCase]
    let pipeline: [PipelineCase]

    static func load() throws -> Golden {
        guard let url = Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "Fixtures") else {
            throw NSError(domain: "Golden", code: 1, userInfo: [NSLocalizedDescriptionKey: "thiếu Fixtures/golden.json"])
        }
        return try ConfigJSON.decoder().decode(Golden.self, from: Data(contentsOf: url))
    }
}
