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
                    Stepper("Cảnh báo từ \(Int(model.settings.minSpeedKmh ?? model.config.alert.minSpeedKmh)) km/h",
                            value: Binding(get: { model.settings.minSpeedKmh ?? model.config.alert.minSpeedKmh },
                                           set: { model.settings.minSpeedKmh = $0 == model.config.alert.minSpeedKmh ? nil : $0 }),
                            in: 0...80, step: 5)
                    Text("Dưới tốc độ này coi là kẹt xe, không cảnh báo. Mặc định \(Int(model.config.alert.minSpeedKmh)) km/h; hạ xuống để thử trong phố.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Bảng luật: " + model.law.table.map { "≤\(Int($0.maxKmh)) km/h → \(Int($0.dMinM)) m" }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                    if let src = model.law.source { Text(src).font(.caption2).foregroundStyle(.secondary) }
                }
                Section {
                    Toggle("Giọng nói tiếng Việt", isOn: $model.settings.voiceOn)
                    Toggle("Nhận đèn giao thông (thử nghiệm)", isOn: $model.settings.trafficLights)
                } header: {
                    Text("Hỗ trợ tài xế")
                } footer: {
                    Text("Bản thử: nhận đèn bằng model hiện có, màu theo điểm sáng trong khung đèn. Nhắc \"Đèn đỏ phía trước\" khi còn chạy nhanh gần ngã tư, \"Đèn xanh rồi\" khi đèn đã xanh mà xe vẫn đứng. Giọng đọc dùng giọng tiếng Việt có sẵn trên máy (Cài đặt iPhone > Trợ năng > Nội dung được đọc > Giọng nói để tải giọng tốt hơn).")
                }
                Section {
                    Toggle("Thu dữ liệu (ảnh + nhãn gán sẵn)", isOn: $model.settings.dataCapture)
                    CaptureSessionsList()
                } header: {
                    Text("Thu dữ liệu để train")
                } footer: {
                    Text("Khi xe chạy: 1 ảnh / 2 s; thấy đèn giao thông: 1 ảnh / s (cả lúc chờ đèn). Mỗi phiên có images/, labels/ (YOLO, gán sẵn bằng model hiện tại), classes.txt, meta.jsonl (giờ, GPS, tốc độ). Ảnh ~250 KB, 1 giờ chạy ~400 MB. Bấm ZIP để nén rồi chia sẻ (AirDrop sang Mac), mở trong CVAT / Label Studio để sửa nhãn.")
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
                    LogFilesList()
                } header: {
                    Text("Log")
                } footer: {
                    Text("Bấm nút chia sẻ cạnh từng file để gửi (Zalo, AirDrop, Lưu vào Tệp...). Hoặc mở app Tệp > Trên iPhone > SafeGap > logs.")
                }
                Section {
                    Toggle("Chạy mát (15 fps)", isOn: $model.settings.coolMode)
                    Toggle("Ẩn hình camera trên màn hình chính", isOn: $model.settings.hidePreview)
                } header: {
                    Text("Nhiệt độ máy")
                } footer: {
                    Text("Chạy mát: YOLO 15 fps thay vì 30, máy nóng thì giảm tiếp. Ẩn hình camera: màn hình chính vẽ lại con đường, vạch làn và các xe theo mét (không cần ảnh camera), bớt việc cho GPU. Màn hiệu chỉnh vẫn hiện camera. Gắn máy ở khe gió điều hoà, tháo ốp, tránh sạc nhanh khi đang chạy.")
                }
                Section {
                    Toggle("Tự tải đường quanh xe", isOn: $model.settings.autoRoads)
                    RoadStatusRow(store: model.roads)
                    Button("Tải sẵn TP.HCM (36 ô)") { model.roads.downloadHCM() }
                    Button("Xoá dữ liệu đường", role: .destructive) { model.roads.deleteAll() }
                } header: {
                    Text("Dữ liệu đường (OpenStreetMap)")
                } footer: {
                    Text("Không hiện bản đồ, chỉ lấy số làn mỗi chiều, đường một chiều và tốc độ giới hạn để màn lái vẽ đúng số làn. Tải theo ô ~5 km khi có mạng, lưu trong máy, các ô tự ghép với nhau. Đường chưa ghi số làn thì vẽ mặc định. Dữ liệu © OpenStreetMap contributors (ODbL).")
                }
                Section {
                    Toggle("ROI bám theo vạch làn", isOn: $model.settings.laneFollow)
                } header: {
                    Text("Chọn xe cùng làn")
                } footer: {
                    Text("Tìm vạch kẻ đường để ROI uốn theo làn (đường cong). Không thấy vạch thì dùng hình thang đã hiệu chỉnh. Vạch xanh trên màn hình là vạch nhận diện được.")
                }
                Section {
                    Toggle("Kết hợp đo theo mặt đường", isOn: $model.settings.groundFusion)
                } header: {
                    Text("Khoảng cách")
                } footer: {
                    Text("Ngoài bề rộng xe, đo thêm theo vị trí đáy xe so với chân trời (chân trời tính từ góc nghiêng máy bằng CoreMotion). Giúp ổn định khi xe gần, dưới khoảng 40 m. Cần nhập đúng chiều cao camera trong màn hiệu chỉnh.")
                }
                Section {
                    Picker("Ống kính", selection: $model.settings.zoom2x) {
                        Text("1x").tag(false)
                        Text("2x (đo xa)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Button("Hiệu chỉnh camera / ROI") {
                        dismiss()
                        model.beginCalibration()
                    }
                } header: {
                    Text("Camera")
                } footer: {
                    Text("2x: xe ở xa to gấp đôi trên ảnh nên đo xa chính xác hơn, nhưng nhìn hẹp hơn (dễ mất xe khi vào cua). Mỗi ống kính lưu hiệu chỉnh riêng (ROI, f, vạch capo); đổi qua lại không cần chỉnh lại. Lần đầu dùng 2x, app tự suy ra từ hiệu chỉnh 1x. Đổi nhanh bằng nút 1x/2x trên màn hình chính.")
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

private struct RoadStatusRow: View {
    @ObservedObject var store: RoadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "Đã có %d ô · %d đoạn đường · %.1f MB", store.tileCount, store.wayCount,
                        Double(store.bytesOnDisk) / 1_048_576))
            if let d = store.downloading {
                Text("Đang tải ô \(d)… còn \(store.queued) ô").foregroundStyle(.secondary)
            } else if store.queued > 0 {
                Text("Chờ tải \(store.queued) ô").foregroundStyle(.secondary)
            }
            if let e = store.lastError {
                Text(e).foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }
}


/// Danh sách file log CSV, mới nhất trước, mỗi file có nút chia sẻ.
private struct LogFilesList: View {
    @State private var files: [(url: URL, size: Int)] = []

    var body: some View {
        Group {
            if files.isEmpty {
                Text("Chưa có file log").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(files, id: \.url) { f in
                HStack {
                    VStack(alignment: .leading) {
                        Text(f.url.lastPathComponent).font(.caption).monospaced()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: f.url) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: CSVLogger.logsDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        files = urls.filter { $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(10)
            .map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}


/// Danh sách phiên thu dữ liệu: nén ZIP rồi chia sẻ, hoặc xoá.
private struct CaptureSessionsList: View {
    @State private var sessions: [(url: URL, images: Int, bytes: Int)] = []
    @State private var zips: [URL: URL] = [:]
    @State private var zipping: URL?

    var body: some View {
        Group {
            if sessions.isEmpty {
                Text("Chưa có phiên thu dữ liệu").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sessions, id: \.url) { s in
                HStack {
                    VStack(alignment: .leading) {
                        Text(s.url.lastPathComponent).font(.caption).monospaced()
                        Text("\(s.images) ảnh · " + ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let z = zips[s.url] {
                        ShareLink(item: z) { Image(systemName: "square.and.arrow.up") }
                    } else if zipping == s.url {
                        ProgressView()
                    } else {
                        Button("ZIP") { zip(s.url) }.buttonStyle(.borderless)
                    }
                    Button(role: .destructive) { delete(s.url) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() { sessions = Array(DataCapture.sessions().prefix(15)) }

    private func zip(_ dir: URL) {
        zipping = dir
        DispatchQueue.global(qos: .userInitiated).async {
            let z = DataCapture.zip(dir)
            DispatchQueue.main.async {
                zipping = nil
                if let z { zips[dir] = z }
            }
        }
    }

    private func delete(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        zips[dir] = nil
        reload()
    }
}
