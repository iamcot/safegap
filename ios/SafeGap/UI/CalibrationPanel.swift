// Màn hiệu chỉnh (bảng bên phải): f theo máy, đo A4, ngưỡng capo, chiều cao camera. Lưu theo từng máy.
import SafeGapCore
import SwiftUI

struct CalibrationPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var editor: CalibrationEditor

    var body: some View {
        let s = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hiệu chỉnh máy này").font(.title3.bold())
                Text("\(editor.draft.deviceModel) · camera \(editor.draft.lens) · \(Int(editor.draft.frameWidth))×\(Int(editor.draft.frameHeight))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Kéo 4 chấm trắng để ROI ôm đúng làn của mình. Kéo chấm cam lên sát trên capo: box nào chạm dưới vạch cam bị bỏ.")
                    .font(.footnote)

                GroupBox("Tiêu cự f") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("Intrinsics (iOS)", s.fIntrinsics)
                        row("Từ góc nhìn (FOV)", s.fHFOV)
                        row("Đang dùng (\(s.fSource.rawValue))", s.fPx)
                        if let mf = editor.draft.manualFPx {
                            HStack {
                                row("f đo tay", mf)
                                Button("Bỏ") { editor.draft.manualFPx = nil }.font(.footnote)
                            }
                        }
                    }
                    .font(.footnote).monospacedDigit()
                }

                GroupBox {
                    Toggle("Kiểm tra f bằng tờ A4", isOn: $editor.a4On).font(.footnote.bold())
                    if editor.a4On {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Dán tờ A4 nằm ngang lên tường, đặt máy cách tường đúng khoảng cách dưới đây, kéo 2 vạch xanh vào 2 mép giấy.")
                                .font(.caption)
                            Stepper(String(format: "Khoảng cách: %.1f m", editor.a4DistanceM), value: $editor.a4DistanceM, in: 0.5...10, step: 0.5)
                            Stepper(String(format: "Vạch trái: %.0f px", editor.a4Left), value: $editor.a4Left, in: 0...editor.draft.frameWidth, step: 1)
                            Stepper(String(format: "Vạch phải: %.0f px", editor.a4Right), value: $editor.a4Right, in: 0...editor.draft.frameWidth, step: 1)
                            if let f = editor.a4F {
                                Text(String(format: "Rộng %.0f px → f = %.0f px", abs(editor.a4Right - editor.a4Left), f)).bold()
                                if let fi = s.fIntrinsics {
                                    Text(String(format: "Lệch so với intrinsics: %+.1f%%", (f / fi - 1) * 100))
                                }
                                Button("Dùng f này") { editor.draft.manualFPx = f }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .font(.footnote)
                    }
                }

                GroupBox("Bỏ capo / xe mình") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "Bỏ box rộng hơn %.0f%% khung", editor.draft.maxWidthRatio * 100))
                        Slider(value: $editor.draft.maxWidthRatio, in: 0.3...1.0, step: 0.05)
                        Text(String(format: "Vạch đáy: %.0f%% chiều cao", editor.draft.maxBottomRatio * 100))
                    }
                    .font(.footnote)
                }

                GroupBox {
                    Stepper(String(format: "Chiều cao camera: %.2f m", editor.draft.hCamM), value: $editor.draft.hCamM, in: 0.5...2.5, step: 0.05)
                        .font(.footnote)
                    Text("Chỉ dùng khi bật cách tính theo mặt đường (mặc định tắt).").font(.caption2).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Lưu") { model.saveCalibration() }.buttonStyle(.borderedProminent)
                    Button("Huỷ") { model.endCalibration() }.buttonStyle(.bordered)
                    Spacer()
                    Button("Mặc định") { model.resetCalibrationToDefaults() }.font(.footnote)
                }
            }
            .padding(12)
        }
        .background(Color(white: 0.1))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ name: String, _ f: Double?) -> some View {
        HStack {
            Text(name)
            Spacer()
            if let f {
                Text(String(format: "%.0f px · HFOV %.1f°", f, FocalLength.hfovDeg(fPx: f, imageWidthPx: editor.draft.frameWidth)))
            } else {
                Text("không có").foregroundStyle(.secondary)
            }
        }
    }
}
