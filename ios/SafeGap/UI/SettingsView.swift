import SafeGapCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Cảnh báo") {
                    Toggle("Âm thanh khi QUÁ GẦN", isOn: $model.settings.soundOn)
                    Toggle("d_min chỉnh tay (biển cự ly, trời mưa)", isOn: Binding(
                        get: { model.settings.manualDMinM != nil },
                        set: { model.settings.manualDMinM = $0 ? (model.settings.manualDMinM ?? 100) : nil }))
                    if let d = model.settings.manualDMinM {
                        Stepper("d_min: \(Int(d)) m", value: Binding(
                            get: { d }, set: { model.settings.manualDMinM = $0 }), in: 20...200, step: 5)
                    }
                    Text("Bảng luật: " + model.law.table.map { "≤\(Int($0.maxKmh)) km/h → \(Int($0.dMinM)) m" }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                    if let src = model.law.source { Text(src).font(.caption2).foregroundStyle(.secondary) }
                }
                Section {
                    Toggle("Tốc độ giả lập", isOn: Binding(
                        get: { model.settings.simulatedSpeedKmh != nil },
                        set: { model.settings.simulatedSpeedKmh = $0 ? 90 : nil }))
                    if let v = model.settings.simulatedSpeedKmh {
                        Slider(value: Binding(get: { v }, set: { model.settings.simulatedSpeedKmh = $0.rounded() }), in: 0...130)
                        Text("\(Int(v)) km/h").monospacedDigit()
                    }
                } header: {
                    Text("Thử khi đứng yên")
                } footer: {
                    Text("Nhớ tắt trước khi lái: bật lên thì app bỏ qua GPS.")
                }
                Section {
                    Toggle("Ghi log CSV mỗi frame", isOn: $model.settings.logOn)
                    if let url = model.logURL {
                        Text(url.lastPathComponent).font(.caption).monospaced()
                    }
                } header: {
                    Text("Log")
                } footer: {
                    Text("Mở app Tệp > Trên iPhone > SafeGap > logs. Cột giống CSV của proto/run_video.py nên chạy được proto.eval.")
                }
                Section("Camera") {
                    Button("Hiệu chỉnh camera / ROI") {
                        dismiss()
                        model.beginCalibration()
                    }
                }
                Section {
                    Text("App chỉ để tham khảo, không thay thế sự chú ý của tài xế. Không thao tác điện thoại khi đang lái.")
                        .font(.caption)
                }
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Xong") { dismiss() } }
        }
    }
}
