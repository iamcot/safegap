// HUD: số D lớn, d_min, tốc độ, nền theo màu cảnh báo. Không cần chạm khi đang lái.
import SafeGapCore
import SwiftUI

struct HUDPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool

    var body: some View {
        let s = model.snapshot
        let r = s.result
        let fg = r.level.textColor
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(r.level.label).font(.system(size: 22, weight: .heavy))
                Spacer()
                Button { model.beginCalibration() } label: { Image(systemName: "scope") }
                Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
            }
            .font(.title2)

            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(r.d.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(size: 110, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("m").font(.system(size: 34, weight: .semibold))
            }
            Text("Tối thiểu: " + (r.dMin.map { String(format: "%.0f m", $0) } ?? "--"))
                .font(.system(size: 26, weight: .semibold))
            HStack(spacing: 6) {
                Text(r.speedKmh.map { String(format: "%.0f km/h", $0) } ?? "-- km/h")
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                if s.speedSimulated {
                    Text("giả lập").font(.caption.bold()).padding(.horizontal, 6).background(.black.opacity(0.3), in: Capsule())
                } else if !s.gpsOK {
                    Text("chưa có GPS").font(.caption.bold()).padding(.horizontal, 6).background(.black.opacity(0.3), in: Capsule())
                }
            }
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                if let err = s.detectorError {
                    Text(err).font(.caption2.bold()).lineLimit(3)
                }
                if s.thermal != .nominal {
                    Label(s.thermal == .critical ? "Máy rất nóng: che nắng / bật điều hoà vào máy"
                                                 : String(format: "Máy nóng: giảm còn %.0f fps", s.targetFps),
                          systemImage: "thermometer.sun.fill")
                        .font(.caption.bold())
                }
                if !model.isCalibrated {
                    Text("Chưa hiệu chỉnh máy này: bấm ◎ để chỉnh ROI").font(.caption2.bold())
                }
                Text(String(format: "%@ · %.0f fps · YOLO %.0f ms · f %.0f px (%@)", model.settings.zoom2x ? "2x" : "1x", s.fps, s.inferMs, s.fPx, s.fSource.rawValue))
                    .font(.caption2).monospacedDigit()
                if model.logURL != nil {
                    Label("Đang ghi log CSV", systemImage: "record.circle").font(.caption2)
                }
            }
            .opacity(0.85)
        }
        .foregroundStyle(fg)
        .tint(fg)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(r.level.color)
        .animation(.easeInOut(duration: 0.2), value: r.level)
    }
}
