// Màn hình lái chính: 2 cột (số liệu + dải camera thật + con đường vẽ lại | bản đồ OSM). Con đường vẽ lại theo mét, kiểu màn lái xe điện.
// Vạch làn và các xe được chiếu ngược từ ảnh xuống mặt đường (X ngang, Z phía trước, mét),
// rồi vẽ lại bằng một "camera ảo" đặt sau và cao hơn xe mình. Xe là ảnh vẽ sẵn (Assets: car_own, car_rear, truck_rear) đặt đúng vị trí và cỡ theo mét;
// dải màu từ đầu xe mình tới xe phía trước báo mức an toàn. Sáng/tối theo giao diện máy.
import SafeGapCore
import SwiftUI
import UIKit

struct DriveView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @Binding var showSettings: Bool

    var body: some View {
        let s = model.snapshot
        let r = s.result
        let pal = Palette.of(scheme)
        GeometryReader { geo in
            // chủ app 20/11: 2 cột. Trái 2/3: số liệu chính + biển cấm / camera thật (chỉ dải từ capo trở lên) /
            // con đường vẽ lại. Phải 1/3: bản đồ OpenStreetMap.
            let mapW = (geo.size.width / 3).rounded()
            let h = geo.size.height
            let topH = min(max(h * 0.22, 74), 110)
            let camH = (h * 0.38).rounded()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    topBar(s, pal)
                        .padding(.horizontal, 14)
                        .frame(height: topH)
                    CameraStrip(snapshot: s, calibration: model.calibration, session: model.camera.session)
                        .frame(height: camH)
                        .clipped()
                    ZStack(alignment: .bottomLeading) {
                        RoadCanvas(snapshot: s, calibration: model.calibration, config: model.config, pal: pal)
                        statusLine(s, pal).padding(.horizontal, 12).padding(.bottom, 8)
                    }
                    .clipped()
                }
                .frame(width: geo.size.width - mapW)
                ZStack(alignment: .top) {
                    OSMMapView(dark: pal.dark)
                    controls(pal).padding(.top, 8)
                }
                .frame(width: mapW)
                .clipped()
            }
        }
        .background(pal.bgTop.ignoresSafeArea())
        .overlay(AlertGlow(level: r.level).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: r.level)
    }

    /// Dòng trên: tốc độ, khoảng cách tới xe trước + mức cảnh báo, biển cấm đang có hiệu lực.
    private func topBar(_ s: FrameSnapshot, _ pal: Palette) -> some View {
        let r = s.result
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: -4) {
                Text(r.speedKmh.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 4) {
                    Text("km/h").font(.system(size: 12, weight: .semibold))
                    if s.speedSimulated { Chip(text: "giả lập", pal: pal) } else if !s.gpsOK { Chip(text: "chưa GPS", pal: pal) }
                }
                .foregroundStyle(pal.textDim)
            }
            .foregroundStyle(pal.text)
            if let lim = s.road?.maxspeed {
                Text("\(lim)")
                    .font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white))
                    .overlay(Circle().stroke(Color.red, lineWidth: 4.5))
            }
            if !s.activeSigns.isEmpty {
                SignIconsRow(signs: s.activeSigns, size: 40)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(r.d.map { String(format: "%.0f", $0) } ?? "--")
                        .font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("m").font(.system(size: 17, weight: .semibold)).foregroundStyle(pal.textDim)
                }
                HStack(spacing: 6) {
                    Text("giữ ≥ " + (r.dMin.map { String(format: "%.0f m", $0) } ?? "--"))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.textDim)
                    Text(r.level.label)
                        .font(.system(size: 11, weight: .heavy)).tracking(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(r.level == .none ? pal.textDim.opacity(0.25) : pal.path(r.level), in: Capsule())
                        .foregroundStyle(r.level == .yellow ? .black : .white)
                }
            }
            .foregroundStyle(pal.text)
        }
    }

    private func controls(_ pal: Palette) -> some View {
        HStack(spacing: 6) {
            GlassButton(pal: pal) { model.toggleZoom() } label: {
                Text(model.settings.zoom2x ? "2x" : "1x").font(.system(size: 16, weight: .bold, design: .rounded))
            }
            GlassButton(pal: pal) { model.settings.hidePreview = false } label: { Image(systemName: "video.fill") }
            GlassButton(pal: pal) { model.beginCalibration() } label: { Image(systemName: "scope") }
            GlassButton(pal: pal) { showSettings = true } label: { Image(systemName: "gearshape.fill") }
        }
    }

    private func statusLine(_ s: FrameSnapshot, _ pal: Palette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let line = HUDPanel.assistLine(s) {
                Label(line, systemImage: "signpost.right.fill")
                    .foregroundStyle(pal.textDim)
                    .monospacedDigit()
            }
            if let err = s.detectorError {
                Label(err, systemImage: "exclamationmark.triangle.fill").lineLimit(2)
            }
            if s.thermal != .nominal {
                Label(s.thermal == .critical ? "Máy rất nóng: che nắng, hướng điều hoà vào máy"
                                             : String(format: "Máy nóng: giảm còn %.0f fps", s.targetFps),
                      systemImage: "thermometer.sun.fill")
                    .foregroundStyle(.orange)
            }
            if !model.isCalibrated {
                Label("Chưa hiệu chỉnh máy này: bấm ◎", systemImage: "scope").foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                if model.logURL != nil {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                }
                Text(String(format: "%.0f fps · YOLO %.0f ms · f %.0f px", s.fps, s.inferMs, s.fPx)).monospacedDigit()
                if s.road != nil { Text("· đường © OpenStreetMap") }
            }
            .foregroundStyle(pal.textDim.opacity(0.8))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(pal.text.opacity(0.8))
    }
}

// MARK: - Bảng màu

struct Palette {
    var bgTop, bgBottom, road, roadEdge, lane, laneFaint: Color
    var carTop, carRear, carSide, glass, ownTop, ownRear, ownSide, shadow: Color
    var text, textDim, button: Color
    var dark: Bool

    static func of(_ s: ColorScheme) -> Palette { s == .dark ? .night : .day }

    static let day = Palette(
        bgTop: Color(white: 0.80), bgBottom: Color(white: 0.92), road: Color(white: 0.965), roadEdge: Color(white: 0.86),
        lane: Color(white: 0.62), laneFaint: Color(white: 0.75),
        carTop: Color(white: 0.97), carRear: Color(white: 0.84), carSide: Color(white: 0.74), glass: Color(white: 0.55),
        ownTop: Color(white: 0.30), ownRear: Color(white: 0.16), ownSide: Color(white: 0.10), shadow: .black.opacity(0.18),
        text: Color(white: 0.08), textDim: Color(white: 0.40), button: .white.opacity(0.7), dark: false)

    static let night = Palette(
        bgTop: Color(red: 0.03, green: 0.035, blue: 0.045), bgBottom: Color(red: 0.07, green: 0.075, blue: 0.09),
        road: Color(white: 0.13), roadEdge: Color(white: 0.09), lane: Color(white: 0.55), laneFaint: Color(white: 0.30),
        carTop: Color(white: 0.62), carRear: Color(white: 0.44), carSide: Color(white: 0.32), glass: Color(white: 0.12),
        ownTop: Color(white: 0.85), ownRear: Color(white: 0.66), ownSide: Color(white: 0.50), shadow: .black.opacity(0.6),
        text: .white, textDim: Color(white: 0.6), button: .white.opacity(0.12), dark: true)

    /// Màu dải khoảng cách tới xe trước: xanh lá khi an toàn / chưa có, vàng, đỏ khi quá gần.
    func path(_ l: Level) -> Color {
        switch l {
        case .none, .green: return Color(red: 0.13, green: 0.75, blue: 0.35)
        case .yellow: return Color(red: 1.0, green: 0.72, blue: 0.0)
        case .red: return Color(red: 0.95, green: 0.18, blue: 0.16)
        }
    }
}

// MARK: - Khối chữ

private struct Chip: View {
    let text: String
    let pal: Palette
    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(pal.textDim.opacity(0.18), in: Capsule())
    }
}

private struct GlassButton<L: View>: View {
    let pal: Palette
    let action: () -> Void
    @ViewBuilder let label: () -> L

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(pal.text)
                .frame(width: 40, height: 36)
                .background(pal.button, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(pal.textDim.opacity(0.2)))
                .shadow(color: .black.opacity(pal.dark ? 0 : 0.08), radius: 6, y: 2)
        }
    }
}

/// Viền sáng màu cảnh báo quanh màn hình; đỏ thì nhấp nháy.
private struct AlertGlow: View {
    let level: Level
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 0)
            .strokeBorder(level.accent, lineWidth: level == .red ? 26 : 18)
            .blur(radius: 22)
            .opacity(level == .none || level == .green ? 0 : (level == .red && pulse ? 0.55 : 0.95))
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

extension Level {
    var accent: Color {
        switch self {
        case .none: return Color(white: 0.6)
        case .green: return Color(red: 0.20, green: 0.85, blue: 0.45)
        case .yellow: return Color(red: 1.00, green: 0.80, blue: 0.15)
        case .red: return Color(red: 1.00, green: 0.22, blue: 0.20)
        }
    }
}

// MARK: - Con đường quanh xe mình

/// Điểm trên mặt đường, mét: x sang phải, z về phía trước tính từ camera.
private struct Ground { var x: Double; var z: Double }

/// Dòng dưới của màn chính (chủ app 20/11): thay cho capo, vẽ xe mình to, mũi xe sát mép trên (ngay dưới dải camera
/// thật, khoảng cách tới xe trước đã xem trên camera). Chỉ vẽ làn quanh xe và xe bên hông mà camera không còn thấy
/// (`SideVehicleMemory`: xe làn bên cạnh vừa ra khỏi khung khi đang ở gần, đoán tiếp vị trí ngang / sau xe mình).
private struct RoadCanvas: View {
    let snapshot: FrameSnapshot
    let calibration: DeviceCalibration
    let config: AppConfig
    let pal: Palette

    /// Mũi xe mình (Car.own: đuôi −3,2 m, dài 4,6 m) + chút lề: điểm này nằm ở mép trên.
    static let topZ = 1.6

    var body: some View {
        Canvas { ctx, size in
            // xe mình phải hiện đủ cả chiếc (chủ app 20/11): nóc ảnh xe nhô quá mép trên thì dịch cả cảnh xuống
            let cam0 = NearCamera(size: size, topZ: Self.topZ)
            let ownTop = carRect(cam0, Car.own)?.minY ?? 0
            let cam = ownTop < 6 ? NearCamera(size: size, topZ: Self.topZ, shiftY: 6 - ownTop) : cam0
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [pal.bgTop, pal.bgBottom]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let (left, right) = laneEdges()
            let lw = snapshot.roadLane.width
            let lay = layout
            func edge(_ k: Int) -> [Ground] { left.map { Ground(x: $0.x + Double(k) * lw, z: $0.z) } }  // mép trái của làn k
            ctx.fill(cam.path(edge(lay.lo) + edge(lay.hi + 1).reversed(), closed: true), with: .color(pal.road))
            // làn mình: xanh dương nhạt; mép trên tô màu mức cảnh báo (nối với dải camera phía trên)
            ctx.fill(cam.path(left + right.reversed(), closed: true),
                     with: .color(Color(red: 0.45, green: 0.68, blue: 1.0).opacity(pal.dark ? 0.35 : 0.5)))
            let real = snapshot.roadLane.tracked
            for k in lay.lo...(lay.hi + 1) {
                let e = cam.path(edge(k))
                if k == lay.lo || k == lay.hi + 1 {
                    ctx.stroke(e, with: .color(pal.roadEdge), lineWidth: 3)   // mép đường
                } else if k == lay.center && snapshot.oncomingLane != nil {
                    ctx.stroke(e, with: .color(Color(red: 1.0, green: 0.76, blue: 0.0)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                } else if k == 0 || k == 1 {
                    ctx.stroke(e, with: .color(real ? pal.lane : pal.laneFaint),
                               style: StrokeStyle(lineWidth: real ? 4 : 2.5, lineCap: .round, dash: [24, 26]))
                } else {
                    ctx.stroke(e, with: .color(pal.laneFaint), style: StrokeStyle(lineWidth: 2.5, dash: [24, 26]))
                }
            }
            let level = snapshot.result.level
            if level != .none {
                let c = pal.path(level)
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 4)), with: .color(c.opacity(0.9)))
            }
            // xe: xa (phía trước) vẽ trước, xe mình cuối cùng
            for car in sideCars().sorted(by: { $0.pos.z > $1.pos.z }) + [Car.own] {
                drawCar(ctx, cam, car)
            }
            if let name = snapshot.road?.name {
                let t = ctx.resolve(Text(name).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(pal.text.opacity(0.85)))
                let sz = t.measure(in: CGSize(width: size.width * 0.4, height: 30))
                let rect = CGRect(x: size.width - sz.width - 28, y: size.height - sz.height - 12, width: sz.width + 18, height: sz.height + 6)
                ctx.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(pal.bgBottom.opacity(0.75)))
                ctx.draw(t, in: rect.insetBy(dx: 9, dy: 3))
            }
        }
    }

    /// Xe bên hông đang khuất, đặt vào giữa làn của nó.
    private func sideCars() -> [Car] {
        let lw = snapshot.roadLane.width
        let lay = layout
        return snapshot.sideVehicles.compactMap { v in
            guard v.lane >= lay.lo, v.lane <= lay.hi, v.z < Self.topZ + 2 else { return nil }
            let tall = v.cls == "truck" || v.cls == "bus"
            let moto = v.cls == "motorcycle"
            return Car(pos: Ground(x: centerX(v.z) + Double(v.lane) * lw, z: v.z),
                       widthM: config.vehicleWidthM[v.cls] ?? 1.8, heightM: tall ? 3.0 : (moto ? 1.2 : 1.45),
                       lengthM: tall ? 9.0 : (moto ? 2.0 : 4.5), kind: .other)
        }
    }

    /// Xe là ảnh nhìn từ sau-trên. Bề rộng theo mét × tỉ lệ camera; chiều cao ảnh nén theo độ dài xe
    /// nhìn từ camera ảo (xe xa trông dẹt hơn), đuôi xe đặt đúng vị trí trên mặt đường.
    private func drawCar(_ ctx: GraphicsContext, _ cam: NearCamera, _ car: Car) {
        let name: String
        switch car.kind {
        case .own: name = "car_own"
        case .oncoming: name = car.isTall ? "truck_front" : "car_front"
        default: name = car.isTall ? "truck_rear" : "car_rear"
        }
        let img = ctx.resolve(Image(name))
        guard let rect = carRect(cam, car, imageSize: img.size) else { return }
        let w = rect.width
        var g = ctx
        g.addFilter(.shadow(color: .black.opacity(pal.dark ? 0.5 : 0.18), radius: w * 0.06, y: w * 0.03))
        g.draw(img, in: rect)
    }

    /// Khung ảnh xe trên canvas. Xe mình: giữ nguyên tỉ lệ ảnh (vẽ đủ cả chiếc, không nén).
    private func carRect(_ cam: NearCamera, _ car: Car, imageSize: CGSize? = nil) -> CGRect? {
        let sz = imageSize ?? UIImage(named: car.isOwn ? "car_own" : (car.isTall ? "truck_rear" : "car_rear"))?.size ?? .zero
        guard sz.width > 0 else { return nil }
        let k = cam.scale(car.pos.z)
        let w = CGFloat(car.widthM * k * 1.22)   // ảnh có cả gương hai bên
        guard w > 4 else { return nil }
        let rear = cam.point(car.pos)
        let front = cam.point(Ground(x: car.pos.x, z: car.pos.z + car.lengthM))
        let projected = rear.y - front.y + CGFloat(car.heightM * k) * 0.3
        let natural = w * sz.height / sz.width
        let h = car.isOwn ? natural : min(natural, max(natural * 0.5, projected))
        return CGRect(x: rear.x - w / 2, y: rear.y - h + w * 0.04, width: w, height: h)
    }

    /// Tim làn mình tại z. Gần: theo làn camera. Xa (camera không thấy rõ): có bản đồ thì nối tiếp theo độ cong
    /// thật của con đường trên OSM (liền mạch tại điểm nối), không có thì kéo thẳng theo hướng cuối.
    private func centerX(_ z: Double) -> Double {
        let lane = snapshot.roadLane
        let ahead = snapshot.roadAhead
        let join = ahead != nil ? Self.mapJoinZ : 60
        let zc = min(z, join)
        let slope = lane.heading + lane.curvature * zc
        return lane.center(zc) + slope * (z - zc) + (ahead?.bend(at: z, join: join) ?? 0)
    }

    static let mapJoinZ = 40.0

    private func laneEdges() -> ([Ground], [Ground]) {
        // hai mép làn mình theo mô hình làn đã lọc (RoadLaneFilter), từ sau đuôi xe tới quá mép trên một chút
        let zs = Array(stride(from: -16.0, through: 12.0, by: 1.0))
        let half = snapshot.roadLane.width / 2
        return (zs.map { Ground(x: centerX($0) - half, z: $0) }, zs.map { Ground(x: centerX($0) + half, z: $0) })
    }

    /// Bố cục làn theo chỉ số (0 = làn mình, âm = bên trái). Vạch giữa (chia hai chiều) nằm ở mép trái làn `center`.
    /// Số làn mỗi chiều lấy từ OpenStreetMap nếu có; không có thì 2 + 2 (đường nhỏ 1 + 1).
    /// Làn mình theo `LanePosition` (xe cùng chiều hai bên, xe ngược chiều, GPS); chưa có thì sát vạch giữa.
    var layout: (lo: Int, hi: Int, center: Int) {
        let road = snapshot.road
        let small = (road?.cls ?? 0) == 5
        let osmSame = min(max(road?.lanesSame ?? (small ? 1 : 2), 1), 4)
        let same = min(max(snapshot.lanePosition?.lanes ?? osmSame, osmSame), 4)
        let opp = road?.oneway == true ? 0 : min(max(road?.lanesOpposite ?? (small ? 1 : 2), 1), 3)
        let n = min(max((snapshot.lanePosition?.fromLeft).map { $0 + 1 } ?? snapshot.oncomingLane ?? 1, 1), same)
        let center = -(n - 1)
        return (center - opp, same - n, center)
    }

}

private struct Car {
    enum Kind { case own, target, other, oncoming }
    var pos: Ground
    var widthM: Double
    var heightM: Double
    var lengthM: Double
    var kind: Kind

    var isTall: Bool { heightM > 2 }
    var isOwn: Bool { kind == .own }
    static let own = Car(pos: Ground(x: 0, z: -3.2), widthM: 1.85, heightM: 1.45, lengthM: 4.6, kind: .own)
}

/// Camera ảo nhìn xe mình từ sau-trên: cao 8 m, lùi 25 m sau camera thật, chúc 28° (cùng góc với ảnh xe vẽ sẵn).
/// Tiêu cự chọn để bề ngang thấy ~16 m (xe mình to), nhưng vẫn thấy tới ~8 m sau đuôi xe trong chiều cao canvas;
/// dịch dọc để điểm `topZ` (mũi xe) nằm đúng mép trên.
private struct NearCamera {
    let size: CGSize
    static let height = 8.0
    static let back = 25.0
    static let pitch = 28.0 * Double.pi / 180
    let focal: Double
    let cy: Double

    init(size: CGSize, topZ: Double, shiftY: CGFloat = 0) {
        self.size = size
        func ratio(_ z: Double) -> Double { let (d, v) = Self.view(0, z); return v / d }
        let byWidth = Double(size.width) / 16 * Self.view(0, 0).d
        let byHeight = Double(size.height) / max(ratio(-11) - ratio(topZ), 1e-3)
        let f = max(min(byWidth, byHeight), 1)
        focal = f
        cy = -f * ratio(topZ) + Double(shiftY)
    }

    private static func view(_ y: Double, _ z: Double) -> (d: Double, v: Double) {
        let dz = z + back, dy = height - y
        return (max(dz * cos(pitch) + dy * sin(pitch), 0.3), dy * cos(pitch) - dz * sin(pitch))
    }

    /// Số điểm màn hình cho 1 m bề ngang ở mặt đường, cách z phía trước.
    func scale(_ z: Double) -> Double { focal / Self.view(0, z).d }

    func point3(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        let (d, v) = Self.view(y, z)
        return CGPoint(x: size.width / 2 + CGFloat(focal * x / d), y: CGFloat(cy + focal * v / d))
    }

    func point(_ g: Ground) -> CGPoint { point3(g.x, 0, g.z) }

    func path(_ pts: [Ground], closed: Bool = false) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: point(first))
        for g in pts.dropFirst() { p.addLine(to: point(g)) }
        if closed { p.closeSubpath() }
        return p
    }
}
