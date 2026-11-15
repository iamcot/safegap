// Bù pitch bằng CoreMotion (Phase 3): tính dòng chân trời trên ảnh từ góc ngẩng của camera,
// để dùng cách đo theo mặt đường (mục 3.4) khi giá gắn chúc lên/xuống hoặc xe nhún.
import Foundation

public enum Horizon {
    /// Góc ngẩng (rad) của trục camera sau so với mặt phẳng ngang, từ vector trọng lực (đơn vị g) trong hệ toạ độ máy.
    /// Camera sau nhìn theo -Z của máy. Dương = camera ngẩng lên. Không phụ thuộc máy cầm dọc hay ngang.
    public static func cameraPitch(gravityX gx: Double, gravityY gy: Double, gravityZ gz: Double) -> Double? {
        let n = (gx * gx + gy * gy + gz * gz).squareRoot()
        guard n > 0.5 else { return nil }  // không đọc được trọng lực
        return asin(max(-1, min(1, gz / n)))
    }

    /// Dòng chân trời (pixel, y từ trên xuống): camera ngẩng lên thì chân trời tụt xuống dưới tâm ảnh.
    /// cy: tâm quang học theo y (intrinsics), không có thì lấy giữa ảnh.
    public static func yPx(fPx: Double, cy: Double, pitchRad: Double) -> Double {
        cy + fPx * tan(pitchRad)
    }

    /// Góc ngẩng suy ra từ dòng chân trời (để hiển thị / kiểm tra).
    public static func pitch(yHorizonPx: Double, fPx: Double, cy: Double) -> Double {
        atan((yHorizonPx - cy) / fPx)
    }
}
