// YOLO (COCO) chạy qua Vision + CoreML. Model export bằng Ultralytics với nms=True (xem Models/README.md).
import CoreML
import CoreVideo
import SafeGapCore
import Vision

enum DetectorError: LocalizedError {
    case modelMissing

    var errorDescription: String? {
        "Chưa có model YOLO trong app. Export yolo11n.mlpackage rồi kéo vào ios/SafeGap/Models (xem Models/README.md)."
    }
}

final class YOLODetector {
    let modelName: String
    private let request: VNCoreMLRequest

    init() throws {
        let urls = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []
        guard let url = urls.first(where: { $0.lastPathComponent.lowercased().hasPrefix("yolo") }) ?? urls.first else {
            throw DetectorError.modelMissing
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine  // Neural Engine: ít tốn điện / ít nóng hơn GPU
        let ml = try MLModel(contentsOf: url, configuration: cfg)
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: ml))
        // Model export với imgsz 384x640 (gần 16:9) nên scaleFill gần như không méo ảnh
        request.imageCropAndScaleOption = .scaleFill
        modelName = url.deletingPathExtension().lastPathComponent
    }

    /// Box theo pixel của frame, gốc trên-trái (giống bản Python).
    func detect(_ pixelBuffer: CVPixelBuffer, frameWidth w: Double, frameHeight h: Double,
                classes: Set<String>, minConf: Double) throws -> [Detection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
        var out: [Detection] = []
        for o in observations {
            guard let top = o.labels.first, classes.contains(top.identifier), Double(top.confidence) >= minConf else { continue }
            let bb = o.boundingBox  // chuẩn hoá 0..1, gốc dưới-trái
            out.append(Detection(Double(bb.minX) * w, Double(1 - bb.maxY) * h,
                                 Double(bb.maxX) * w, Double(1 - bb.minY) * h,
                                 top.identifier, Double(top.confidence)))
        }
        return out
    }
}
