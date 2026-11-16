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
        let vn = try VNCoreMLModel(for: ml)
        // Model export nms=True có sẵn ngưỡng tin cậy 0,25 bên trong: hạ xuống 0,15 để ban đêm còn thấy xe tối màu,
        // còn lọc thật sự theo minConf ở dưới (ngày 0,35, đêm 0,2).
        let inputs = ml.modelDescription.inputDescriptionsByName
        if inputs["confidenceThreshold"] != nil {
            vn.featureProvider = NMSThresholds(confidence: 0.15, iou: inputs["iouThreshold"] != nil ? 0.45 : nil)
        }
        request = VNCoreMLRequest(model: vn)
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

/// Giá trị cho các input ngưỡng của model YOLO có NMS (Vision tự lấy ảnh, các input còn lại lấy ở đây).
private final class NMSThresholds: NSObject, MLFeatureProvider {
    let values: [String: MLFeatureValue]
    init(confidence: Double, iou: Double?) {
        var v = ["confidenceThreshold": MLFeatureValue(double: confidence)]
        if let iou { v["iouThreshold"] = MLFeatureValue(double: iou) }
        values = v
    }
    var featureNames: Set<String> { Set(values.keys) }
    func featureValue(for name: String) -> MLFeatureValue? { values[name] }
}
