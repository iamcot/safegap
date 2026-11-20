// Màn hình lái chính: 2 cột (số liệu + dải camera thật + con đường vẽ lại | bản đồ OSM). Con đường vẽ lại theo mét, kiểu màn lái xe điện.
// Vạch làn và các xe được chiếu ngược từ ảnh xuống mặt đường (X ngang, Z phía trước, mét),
// rồi vẽ lại bằng một "camera ảo" đặt sau và cao hơn xe mình. Xe là ảnh vẽ sẵn (Assets: car_own, car_rear, truck_rear) đặt đúng vị trí và cỡ theo mét;
// dải màu từ đầu xe mình tới xe phía trước báo mức an toàn. Sáng/tối theo giao diện máy.
import SafeGapCore
import SwiftUI

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

// MARK: - Con đường

/// Điểm trên mặt đường, mét: x sang phải, z về phía trước tính từ camera.
private struct Ground { var x: Double; var z: Double }

private struct RoadCanvas: View {
    let snapshot: FrameSnapshot
    let calibration: DeviceCalibration
    let config: AppConfig
    let pal: Palette

    static let laneWidth = 3.5
    static let farZ = 80.0

    var body: some View {
        Canvas { ctx, size in
            let cam = ChaseCamera(size: size)
            // nền: một dải chuyển nhẹ từ trên xuống
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [pal.bgTop, pal.bgBottom]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            let (left, right) = laneEdges()
            let r = snapshot.result
            let cars = vehicles()
            // mặt đường: 2 làn cùng chiều (làn mình + 1 làn bên) và 2 làn ngược chiều bên trái vạch giữa
            let lw = snapshot.roadLane.width
            let lay = layout
            func edge(_ k: Int) -> [Ground] { left.map { Ground(x: $0.x + Double(k) * lw, z: $0.z) } }  // mép trái của làn k
            ctx.fill(cam.path(edge(lay.lo) + edge(lay.hi + 1).reversed(), closed: true), with: .color(pal.road))
            // làn mình tô xanh dương nhạt trong suốt
            ctx.fill(cam.path(left + right.reversed(), closed: true),
                     with: .color(Color(red: 0.45, green: 0.68, blue: 1.0).opacity(pal.dark ? 0.35 : 0.5)))
            let real = snapshot.roadLane.tracked
            for k in lay.lo...(lay.hi + 1) {
                let e = cam.path(edge(k))
                if k == lay.lo || k == lay.hi + 1 {
                    ctx.stroke(e, with: .color(pal.roadEdge), lineWidth: 2)   // mép đường
                } else if k == lay.center && snapshot.oncomingLane != nil {
                    // có xe ngược chiều: vạch phân cách hai chiều là nét liền vàng
                    ctx.stroke(e, with: .color(Color(red: 1.0, green: 0.76, blue: 0.0)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                } else if k == 0 || k == 1 {
                    ctx.stroke(e, with: .color(real ? pal.lane : pal.laneFaint),
                               style: StrokeStyle(lineWidth: real ? 2.5 : 1.5, lineCap: .round, dash: [14, 16]))
                } else {
                    ctx.stroke(e, with: .color(pal.laneFaint), style: StrokeStyle(lineWidth: 1.5, dash: [14, 16]))
                }
            }

            // ngã tư phía trước (bản đồ): dải đường cắt ngang + vạch đứt xanh dương (hướng dẫn) + nhãn khoảng cách
            if let zj = nextJunction {
                let crossW = 10.0, side = 30.0
                let xl = interp(edge(lay.lo), zj) - side, xr = interp(edge(lay.hi + 1), zj) + side
                let z0 = zj - crossW / 2, z1 = zj + crossW / 2
                let strip = [Ground(x: xl, z: z0), Ground(x: xr, z: z0), Ground(x: xr, z: z1), Ground(x: xl, z: z1)]
                ctx.fill(cam.path(strip, closed: true), with: .color(pal.road))
                for zz in [z0, z1] {
                    for (a, b) in [(xl, interp(edge(lay.lo), zz)), (interp(edge(lay.hi + 1), zz), xr)] {
                        ctx.stroke(cam.path([Ground(x: a, z: zz), Ground(x: b, z: zz)]), with: .color(pal.roadEdge), lineWidth: 1.5)
                    }
                }
                let guide = Color(red: 0.15, green: 0.45, blue: 1.0)
                let zl = z0 - 0.8
                if zl > 2 {
                    let a = cam.point(Ground(x: interp(edge(lay.lo), zl), z: zl))
                    let b = cam.point(Ground(x: interp(edge(lay.hi + 1), zl), z: zl))
                    var m = Path(); m.move(to: a); m.addLine(to: b)
                    ctx.stroke(m, with: .color(guide.opacity(0.85)), style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    let mid = cam.point(Ground(x: (interp(left, zl) + interp(right, zl)) / 2, z: zl))
                    pill(ctx, String(format: "Ngã tư · %.0f m", zj), at: CGPoint(x: mid.x, y: mid.y - 6), fill: guide)
                }
            }

            // dải đường đi giữa làn: từ đầu xe mình tới xe phía trước (không có xe thì dài bằng d_min, mờ dần)
            let target = cars.first { $0.isTarget }
            let pathEnd = target.map { $0.pos.z - 0.6 } ?? min(r.dMin ?? 25, Self.farZ)
            if pathEnd > 1 {
                let color = pal.path(r.level)
                let half = 0.75
                var lp: [Ground] = [], rp: [Ground] = []
                for i in 0...24 {
                    let z = 0.8 + (pathEnd - 0.8) * Double(i) / 24
                    let c = (interp(left, z) + interp(right, z)) / 2
                    lp.append(Ground(x: c - half, z: z))
                    rp.append(Ground(x: c + half, z: z))
                }
                let band = cam.path(lp + rp.reversed(), closed: true)
                var g = ctx
                g.addFilter(.shadow(color: color.opacity(0.5), radius: 8))
                g.fill(band, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.95), color.opacity(target == nil ? 0.0 : 0.85)]),
                    startPoint: cam.point(Ground(x: 0, z: 0.8)), endPoint: cam.point(Ground(x: 0, z: pathEnd))))
                // vạch d_min ngang làn khi có xe phía trước
                if target != nil, let dMin = r.dMin, dMin < Self.farZ {
                    var m = Path()
                    m.move(to: cam.point(Ground(x: interp(left, dMin), z: dMin)))
                    m.addLine(to: cam.point(Ground(x: interp(right, dMin), z: dMin)))
                    ctx.stroke(m, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
                }
            }

            // đường tan dần ở xa (vẽ trước xe để xe không bị mờ)
            let fadeStart = max(0, cam.horizonY)
            let fadeEnd = fadeStart + size.height * 0.13
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: fadeEnd)),
                     with: .linearGradient(Gradient(stops: [.init(color: pal.bgTop, location: 0),
                                                             .init(color: pal.bgTop, location: fadeStart / fadeEnd),
                                                             .init(color: pal.bgTop.opacity(0), location: 1)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: fadeEnd)))

            // xe: xa vẽ trước, xe mình cuối cùng
            for car in cars.sorted(by: { $0.pos.z > $1.pos.z }) + [Car.own] {
                drawCar(ctx, cam, car)
            }
            // tên đường đang chạy (OpenStreetMap), ngay dưới xe mình
            if let name = snapshot.road?.name {
                let rear = cam.point3(0, 0, Car.own.pos.z - 0.3)   // pos.z là đuôi xe
                let t = ctx.resolve(Text(name).font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(pal.text.opacity(0.85)))
                let sz = t.measure(in: CGSize(width: size.width * 0.45, height: 40))
                let y = min(rear.y + 4, size.height - sz.height - 10)
                let rect = CGRect(x: size.width / 2 - sz.width / 2 - 10, y: y, width: sz.width + 20, height: sz.height + 6)
                ctx.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(pal.bgBottom.opacity(0.75)))
                ctx.draw(t, in: rect.insetBy(dx: 10, dy: 3))
            }
            // số khoảng cách tới xe trước: to, nằm giữa dải màu (dải quá ngắn thì đặt trên nóc xe trước)
            if let t = target, let d = r.d {
                if pathEnd > 4 {
                    let zm = 0.8 + (pathEnd - 0.8) * 0.45
                    let p = cam.point(Ground(x: (interp(left, zm) + interp(right, zm)) / 2, z: zm))
                    var g = ctx
                    g.addFilter(.shadow(color: .black.opacity(0.45), radius: 3, y: 1))
                    let label = Text(String(format: "%.0f m", d)).font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    g.draw(label, at: p, anchor: .center)
                } else {
                    let label = Text(String(format: "%.0f m", d)).font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(pal.text)
                    ctx.draw(label, at: cam.point3(t.pos.x, t.heightM + 0.4, t.pos.z), anchor: .bottom)
                }
            }
        }
    }

    /// Nhãn chữ trắng trên nền bo tròn, đáy nhãn đặt tại `at`.
    private func pill(_ ctx: GraphicsContext, _ text: String, at: CGPoint, fill: Color) {
        let t = ctx.resolve(Text(text).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(.white))
        let sz = t.measure(in: CGSize(width: 400, height: 50))
        let rect = CGRect(x: at.x - sz.width / 2 - 9, y: at.y - sz.height - 8, width: sz.width + 18, height: sz.height + 8)
        ctx.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(fill))
        ctx.draw(t, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    /// Xe là ảnh nhìn từ sau-trên. Bề rộng theo mét × tỉ lệ camera; chiều cao ảnh nén theo độ dài xe
    /// nhìn từ camera ảo (xe xa trông dẹt hơn), đuôi xe đặt đúng vị trí trên mặt đường.
    private func drawCar(_ ctx: GraphicsContext, _ cam: ChaseCamera, _ car: Car) {
        let name: String
        switch car.kind {
        case .own: name = "car_own"
        case .oncoming: name = car.isTall ? "truck_front" : "car_front"
        default: name = car.isTall ? "truck_rear" : "car_rear"
        }
        let img = ctx.resolve(Image(name))
        let sz = img.size
        guard sz.width > 0 else { return }
        let k = cam.scale(car.pos.z)
        let w = CGFloat(car.widthM * k * 1.22)   // ảnh có cả gương hai bên
        guard w > 4 else { return }
        let rear = cam.point(car.pos)
        let front = cam.point(Ground(x: car.pos.x, z: car.pos.z + car.lengthM))
        let projected = rear.y - front.y + CGFloat(car.heightM * k) * 0.3
        let natural = w * sz.height / sz.width
        let h = min(natural, max(natural * 0.5, projected))
        let rect = CGRect(x: rear.x - w / 2, y: rear.y - h + w * 0.04, width: w, height: h)
        var g = ctx
        g.addFilter(.shadow(color: .black.opacity(pal.dark ? 0.5 : 0.18), radius: w * 0.06, y: w * 0.03))
        g.draw(img, in: rect)
    }

    // MARK: ảnh → mặt đường

    private var horizonPx: Double {
        snapshot.yHorizon ?? config.distance.yHorizonNorm * snapshot.frameHeight
    }

    private func toGround(xPx: Double, yPx: Double) -> Ground? {
        let f = snapshot.fPx, dy = yPx - horizonPx
        guard f > 0, dy > 1 else { return nil }
        let z = f * calibration.hCamM / dy
        return Ground(x: (xPx - snapshot.frameWidth / 2) * z / f, z: z)
    }

    /// Hai mép làn mình theo mét, lấy từ mô hình làn đã lọc (RoadLaneFilter): thẳng hoặc cong nhẹ, đổi chậm.
    /// Xa hơn 60 m thì kéo thẳng theo hướng tại 60 m để đường cong không văng ra ngoài.
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
        // từ dưới gầm xe mình (mặt đường chạm đáy màn hình) tới thật xa (đường tan vào chân trời, không bị cụt)
        let zs = Array(stride(from: -14.0, through: Self.farZ, by: 2.5)) + Array(stride(from: Self.farZ + 20, through: 300, by: 20))
        let half = snapshot.roadLane.width / 2
        return (zs.map { Ground(x: centerX($0) - half, z: $0) }, zs.map { Ground(x: centerX($0) + half, z: $0) })
    }

    /// Ngã tư gần nhất phía trước (theo bản đồ) để vẽ, trong 150 m.
    private var nextJunction: Double? {
        snapshot.roadAhead?.junctions.first { $0 > 6 && $0 < 150 }
    }

    /// x tại z trên đường gấp khúc (sắp theo z); ngoài khoảng thì kéo thẳng theo hai điểm đầu/cuối.
    private func interp(_ pts: [Ground], _ z: Double) -> Double {
        guard pts.count > 1 else { return pts.first?.x ?? 0 }
        func lerp(_ a: Ground, _ b: Ground) -> Double { b.z == a.z ? a.x : a.x + (z - a.z) * (b.x - a.x) / (b.z - a.z) }
        if z <= pts[0].z { return lerp(pts[0], pts[1]) }
        for i in 1..<pts.count where pts[i].z >= z { return lerp(pts[i - 1], pts[i]) }
        return lerp(pts[pts.count - 2], pts[pts.count - 1])
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

    /// Xe để vẽ. Khoảng cách: bề rộng box kết hợp vị trí đáy xe trên mặt đường (xe bên cạnh nhìn chéo thì box rộng ra
    /// vì thấy cả hông xe → đo theo bề rộng bị gần quá). Vị trí ngang: tính độ lệch so với tâm làn mình rồi
    /// "bắt" vào giữa làn gần nhất của con đường đang vẽ, nên xe luôn nằm trong làn, không trôi ra ngoài đường.
    func vehicles() -> [Car] {
        let s = snapshot
        let lane = s.roadLane
        var out: [Car] = []
        for (i, d) in s.detections.enumerated() {
            let kept = i < s.kept.count ? s.kept[i] : true
            guard kept, let wReal = config.vehicleWidthM[d.cls], d.width > 0, s.fPx > 0 else { continue }
            let isEgo = d.box == s.result.egoBox
            var z = s.fPx * wReal / d.width
            if let g = Distance.fromGround(fPx: s.fPx, hCamM: calibration.hCamM, yBottomPx: d.y2, yHorizonPx: horizonPx) {
                z = Distance.fuse(dWidth: z, dGround: g)
            }
            if isEgo, let dd = s.result.d { z = dd }
            guard z > 1.0, z < Self.farZ + 20 else { continue }  // gần hơn 1 m là capo xe mình
            let x = ((d.x1 + d.x2) / 2 - s.frameWidth / 2) * z / s.fPx
            let laneIdx = isEgo ? 0 : Int(((x - centerX(z)) / lane.width).rounded())
            guard laneIdx >= layout.lo, laneIdx <= layout.hi else { continue }  // ngoài 4 làn đang vẽ (lề, xe đỗ bên đường)
            let xDraw = centerX(z) + Double(laneIdx) * lane.width
            let isCar = d.cls == "car"
            out.append(Car(pos: Ground(x: xDraw, z: z), widthM: wReal, heightM: isCar ? 1.45 : 3.0, lengthM: isCar ? 4.5 : 9.0,
                           kind: isEgo ? .target : (i < s.oncoming.count && s.oncoming[i] ? .oncoming : .other)))
        }
        // model lỡ mất xe trước vài frame nhưng app vẫn đang giữ (D dự đoán): vẫn vẽ xe ở giữa làn, khỏi nhấp nháy
        if !out.contains(where: { $0.kind == .target }), let d = s.result.d, d > 1, let cls = s.result.cls {
            let isCar = cls == "car"
            out.append(Car(pos: Ground(x: centerX(d), z: d), widthM: config.vehicleWidthM[cls] ?? 1.8,
                           heightM: isCar ? 1.45 : 3.0, lengthM: isCar ? 4.5 : 9.0, kind: .target))
        }
        return out
    }
}

private struct Car {
    enum Kind { case own, target, other, oncoming }
    var pos: Ground
    var widthM: Double
    var heightM: Double
    var lengthM: Double
    var kind: Kind

    var isTarget: Bool { kind == .target }
    var isTall: Bool { heightM > 2 }
    static let own = Car(pos: Ground(x: 0, z: -3.2), widthM: 1.85, heightM: 1.45, lengthM: 4.6, kind: .own)
    var isOwn: Bool { kind == .own }
}

/// Camera ảo: cao 8 m, lùi sau camera thật 10 m, chúc xuống 28° (cùng góc nhìn với ảnh xe vẽ sẵn).
/// Chiều sâu được nén lại (depth < 1) để thấy tới ~60 m; số mét hiển thị vẫn là số thật.
private struct ChaseCamera {
    let size: CGSize
    let height = 8.0
    let back = 10.0
    let depth = 0.5
    let pitch = 28.0 * Double.pi / 180

    var focal: Double { Double(size.height) * 1.2 }
    var cy: Double { Double(size.height) * 0.5 }
    /// Đường chân trời (thường nằm trên mép màn hình vì camera chúc xuống).
    var horizonY: CGFloat { CGFloat(cy - focal * tan(pitch)) }

    /// Độ sâu theo trục nhìn và độ lệch dọc (xuống là dương) của điểm cao y, cách z phía trước.
    private func view(_ y: Double, _ z: Double) -> (d: Double, v: Double) {
        let dz = z * depth + back, dy = height - y
        return (max(dz * cos(pitch) + dy * sin(pitch), 0.3), dy * cos(pitch) - dz * sin(pitch))
    }

    /// Số điểm màn hình cho 1 m bề ngang ở mặt đường, cách z phía trước.
    func scale(_ z: Double) -> Double { focal / view(0, z).d }

    /// Điểm 3D: x ngang, y cao so với mặt đường, z phía trước (mét).
    func point3(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        let (d, v) = view(y, z)
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
