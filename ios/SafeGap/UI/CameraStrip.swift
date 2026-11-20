// Dải camera thật trên màn hình chính (chủ app 20/11): không hiện cả khung hình, chỉ cắt dải từ capo xe trở lên
// (vạch capo = maxBottomRatio của hiệu chỉnh) để so với con đường vẽ lại bên dưới. Box xe / biển vẽ đè như màn camera.
import AVFoundation
import SafeGapCore
import SwiftUI

struct CameraStrip: View {
    let snapshot: FrameSnapshot
    let calibration: DeviceCalibration
    let session: AVCaptureSession

    var body: some View {
        GeometryReader { geo in
            let fw = snapshot.frameWidth > 0 ? snapshot.frameWidth : 1920
            let fh = snapshot.frameHeight > 0 ? snapshot.frameHeight : 1080
            let w = geo.size.width
            let fullH = w * fh / fw                     // cả khung hình nếu vừa bề ngang dải
            let hood = min(max(calibration.maxBottomRatio, 0.5), 1) * fullH
            // đáy dải là vạch capo; dải cao hơn phần trên capo thì dính mép trên khung
            let top = min(max(hood - geo.size.height, 0), max(fullH - geo.size.height, 0))
            ZStack {
                CameraPreview(session: session)
                DetectionOverlay(snapshot: snapshot, calibration: calibration)
            }
            .frame(width: w, height: fullH)
            .offset(y: -top)
            .frame(width: w, height: geo.size.height, alignment: .top)
        }
        .background(Color.black)
        .clipped()
        .allowsHitTesting(false)
    }
}
