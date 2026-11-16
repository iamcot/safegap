// Ước lượng khoảng cách (port từ proto/distance.py, mục 3.3, 3.4) + tính tiêu cự (proto/calib.py, mục 4).
import Foundation

public enum Distance {
    /// D = f_px * W_real / w_px. nil nếu w_px <= 0.
    public static func fromWidth(fPx: Double, wRealM: Double, wPx: Double) -> Double? {
        guard wPx > 0 else { return nil }
        return fPx * wRealM / wPx
    }

    /// D = f_px * h_cam / (y_bottom - y_horizon). nil nếu đáy xe nằm trên đường chân trời.
    public static func fromGround(fPx: Double, hCamM: Double, yBottomPx: Double, yHorizonPx: Double) -> Double? {
        let dy = yBottomPx - yHorizonPx
        guard dy > 0 else { return nil }
        return fPx * hCamM / dy
    }

    /// Trung bình có trọng số. Trọng số cách mặt đường giảm tuyến tính từ 0.5 (D=0) về 0 (D >= 2*far).
    public static func fuse(dWidth: Double, dGround: Double?, farM: Double = 40.0) -> Double {
        guard let dGround else { return dWidth }
        let wGround = max(0.0, 0.5 * (1.0 - dWidth / (2.0 * farM)))
        return (1.0 - wGround) * dWidth + wGround * dGround
    }

    /// f đo ở fImageWidth → đổi sang độ rộng frame đang xử lý.
    public static func scaleFToFrame(fPx: Double, fImageWidth: Double, frameWidth: Double) -> Double {
        fPx * frameWidth / fImageWidth
    }
}

public enum FocalLength {
    public static let a4LongSideM = 0.297

    /// f = w_px * D / W_real (mặc định tờ A4 dán ngang). nil nếu tham số không hợp lệ.
    public static func fromReference(wPx: Double, distanceM: Double, realWidthM: Double = a4LongSideM) -> Double? {
        guard wPx > 0, distanceM > 0, realWidthM > 0 else { return nil }
        return wPx * distanceM / realWidthM
    }

    /// f = (width/2) / tan(HFOV/2).
    public static func fromHFOV(imageWidthPx: Double, hfovDeg: Double) -> Double? {
        guard hfovDeg > 0, hfovDeg < 180 else { return nil }
        return (imageWidthPx / 2.0) / tan(hfovDeg * .pi / 180.0 / 2.0)
    }

    /// HFOV (độ) từ f, để hiển thị kiểm tra.
    public static func hfovDeg(fPx: Double, imageWidthPx: Double) -> Double {
        2.0 * atan(imageWidthPx / 2.0 / fPx) * 180.0 / .pi
    }
}

extension FocalLength {
    /// f khi zoom số (crop) trên camera 1x. iOS có thể đã nhân zoom vào intrinsics hoặc chưa: so với f gốc
    /// (tính từ HFOV ở 1x) để biết, chưa nhân thì nhân. Không có f gốc thì tin intrinsics.
    public static func zoomAdjusted(fx: Double, zoom: Double, baseF: Double?) -> Double {
        guard zoom > 1.01, let baseF, baseF > 0 else { return fx }
        let midpoint = baseF * (1 + zoom) / 2
        return fx < midpoint ? fx * zoom : fx
    }
}
