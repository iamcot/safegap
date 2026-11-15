// Vẽ ROI, box: xe đang đo xanh lá kèm khoảng cách, xe khác hồng tím, box bị bỏ (capo) xám nét đứt.
import SafeGapCore
import SwiftUI

struct DetectionOverlay: View {
    let snapshot: FrameSnapshot
    let calibration: DeviceCalibration

    var body: some View {
        Canvas { ctx, size in
            let m = FrameMapping(frameWidth: snapshot.frameWidth, frameHeight: snapshot.frameHeight, viewSize: size)
            // ROI
            var roi = Path()
            roi.addLines(calibration.roi.map { m.toView(norm: $0) })
            roi.closeSubpath()
            ctx.stroke(roi, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            // vạch đáy: box chạm dưới vạch này là capo xe mình
            let yHood = calibration.maxBottomRatio * snapshot.frameHeight
            var hood = Path()
            hood.move(to: m.toView(0, yHood))
            hood.addLine(to: m.toView(snapshot.frameWidth, yHood))
            ctx.stroke(hood, with: .color(.white.opacity(0.25)), lineWidth: 1)

            let ego = snapshot.result.egoBox
            for (i, d) in snapshot.detections.enumerated() {
                let rect = m.toView(d.box)
                let kept = i < snapshot.kept.count ? snapshot.kept[i] : true
                if d.box == ego {
                    ctx.stroke(Path(rect), with: .color(.green), lineWidth: 3)
                    if let dist = snapshot.result.d {
                        let label = Text(String(format: "%.0f m", dist)).font(.system(size: 16, weight: .bold)).foregroundColor(.black)
                        let pos = CGPoint(x: rect.midX, y: rect.minY - 12)
                        ctx.fill(Path(roundedRect: CGRect(x: pos.x - 30, y: pos.y - 11, width: 60, height: 22), cornerRadius: 5),
                                 with: .color(.green))
                        ctx.draw(label, at: pos)
                    }
                } else if kept {
                    ctx.stroke(Path(rect), with: .color(Color(red: 1, green: 0.3, blue: 0.85)), lineWidth: 1.5)
                } else {
                    ctx.stroke(Path(rect), with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
