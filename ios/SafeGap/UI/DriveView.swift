// Màn hình lái khi ẩn camera: vẽ lại con đường theo mét, full màn hình, kiểu màn lái xe điện.
// Vạch làn và các xe được chiếu ngược từ ảnh xuống mặt đường (X ngang, Z phía trước, mét),
// rồi vẽ lại bằng một "camera ảo" đặt sau và cao hơn xe mình. Xe là khối 3D bo mềm, tông xám;
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
        ZStack {
            RoadCanvas(snapshot: s, calibration: model.calibration, config: model.config, pal: pal)
                .ignoresSafeArea()
            AlertGlow(level: r.level).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    SpeedBlock(snapshot: s, pal: pal)
                    Spacer()
                    controls(pal)
                }
                Spacer()
                HStack(alignment: .bottom) {
                    statusLine(s, pal)
                    Spacer()
                    DistanceBlock(result: r, pal: pal)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .background(pal.bgTop)
        .animation(.easeInOut(duration: 0.25), value: r.level)
    }

    private func controls(_ pal: Palette) -> some View {
        HStack(spacing: 10) {
            GlassButton(pal: pal) { model.toggleZoom() } label: {
                Text(model.settings.zoom2x ? "2x" : "1x").font(.system(size: 16, weight: .bold, design: .rounded))
            }
            GlassButton(pal: pal) { model.beginCalibration() } label: { Image(systemName: "scope") }
            GlassButton(pal: pal) { showSettings = true } label: { Image(systemName: "gearshape.fill") }
        }
    }

    private func statusLine(_ s: FrameSnapshot, _ pal: Palette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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

    /// Màu dải đường đi: xanh dương khi an toàn / chưa có, vàng, đỏ.
    func path(_ l: Level) -> Color {
        switch l {
        case .none, .green: return Color(red: 0.16, green: 0.48, blue: 1.0)
        case .yellow: return Color(red: 1.0, green: 0.72, blue: 0.0)
        case .red: return Color(red: 0.95, green: 0.18, blue: 0.16)
        }
    }
}

// MARK: - Khối chữ

private struct SpeedBlock: View {
    let snapshot: FrameSnapshot
    let pal: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: -6) {
            Text(snapshot.result.speedKmh.map { String(format: "%.0f", $0) } ?? "--")
                .font(.system(size: 68, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            HStack(spacing: 6) {
                Text("km/h").font(.system(size: 15, weight: .semibold))
                if snapshot.speedSimulated {
                    Chip(text: "giả lập", pal: pal)
                } else if !snapshot.gpsOK {
                    Chip(text: "chưa có GPS", pal: pal)
                }
            }
            .foregroundStyle(pal.textDim)
        }
        .foregroundStyle(pal.text)
    }
}

private struct DistanceBlock: View {
    let result: FrameResult
    let pal: Palette

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(result.level.label)
                .font(.system(size: 13, weight: .heavy))
                .tracking(1.5)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(result.level == .none ? pal.textDim.opacity(0.25) : pal.path(result.level), in: Capsule())
                .foregroundStyle(result.level == .yellow ? .black : .white)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(result.d.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(size: 60, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("m").font(.system(size: 22, weight: .semibold)).foregroundStyle(pal.textDim)
            }
            Text("Cần giữ ≥ " + (result.dMin.map { String(format: "%.0f m", $0) } ?? "--"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(pal.textDim)
        }
        .foregroundStyle(pal.text)
    }
}

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
                .frame(width: 46, height: 40)
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
            // mặt đường: làn mình + 2 làn mỗi bên
            let leftmost = left.map { Ground(x: $0.x - 2 * Self.laneWidth, z: $0.z) }
            let rightmost = right.map { Ground(x: $0.x + 2 * Self.laneWidth, z: $0.z) }
            ctx.fill(cam.path(leftmost + rightmost.reversed(), closed: true), with: .color(pal.road))
            for edge in [leftmost, rightmost] {
                ctx.stroke(cam.path(edge), with: .color(pal.roadEdge), lineWidth: 2)
            }
            // vạch làn: làn mình nét liền, vạch giữa các làn bên nét đứt
            let leftNext = left.map { Ground(x: $0.x - Self.laneWidth, z: $0.z) }
            let rightNext = right.map { Ground(x: $0.x + Self.laneWidth, z: $0.z) }
            for edge in [leftNext, rightNext] {
                ctx.stroke(cam.path(edge), with: .color(pal.laneFaint), style: StrokeStyle(lineWidth: 1.5, dash: [14, 16]))
            }
            let detected = (snapshot.laneLeft != nil, snapshot.laneRight != nil)
            for (edge, real) in [(left, detected.0), (right, detected.1)] {
                ctx.stroke(cam.path(edge), with: .color(real ? pal.lane : pal.laneFaint),
                           style: StrokeStyle(lineWidth: real ? 2.5 : 1.5, lineCap: .round))
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
            let fadeEnd = cam.horizonY + size.height * 0.13
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: fadeEnd)),
                     with: .linearGradient(Gradient(stops: [.init(color: pal.bgTop, location: 0),
                                                             .init(color: pal.bgTop, location: cam.horizonY / fadeEnd),
                                                             .init(color: pal.bgTop.opacity(0), location: 1)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: fadeEnd)))

            // xe: xa vẽ trước, xe mình cuối cùng
            for v in cars.sorted(by: { $0.pos.z > $1.pos.z }) {
                drawCar(ctx, cam, v)
            }
            drawCar(ctx, cam, Car(pos: Ground(x: 0, z: -2.0), widthM: 1.85, heightM: 1.45, lengthM: 4.6, kind: .own))

        }
    }

    // MARK: xe 3D

    /// Khối xe bo mềm: thân dưới + cabin thu nhỏ, nhìn từ sau và trên. Mặt bên chỉ vẽ phía camera thấy.
    private func drawCar(_ ctx: GraphicsContext, _ cam: ChaseCamera, _ car: Car) {
        let W = car.widthM, L = car.lengthM, H = car.heightM
        let x0 = car.pos.x, z0 = car.pos.z
        guard cam.scale(z0) * W > 3 else { return }
        let own = car.isOwn
        let top = own ? pal.ownTop : pal.carTop
        let rear = own ? pal.ownRear : pal.carRear
        let side = own ? pal.ownSide : pal.carSide
        let tall = H > 2

        func p(_ x: Double, _ y: Double, _ z: Double) -> CGPoint { cam.point3(x0 + x, y, z0 + z) }
        func quad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, r: CGFloat = 0) -> Path {
            var path = Path()
            let pts = [a, b, c, d]
            guard r > 0 else { path.addLines(pts); path.closeSubpath(); return path }
            path.move(to: CGPoint(x: (d.x + a.x) / 2, y: (d.y + a.y) / 2))
            for i in 0..<4 { path.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % 4], radius: r) }
            path.closeSubpath()
            return path
        }
        let k = CGFloat(cam.scale(z0))
        let rad = max(1, k * 0.18)
        let hw = W / 2

        // bóng
        var sh = ctx
        sh.addFilter(.blur(radius: max(1, k * 0.25)))
        sh.fill(quad(p(-hw - 0.15, 0, -0.2), p(hw + 0.15, 0, -0.2), p(hw + 0.15, 0, L), p(-hw - 0.15, 0, L), r: rad),
                with: .color(pal.shadow))

        // thân dưới (cao hb), cabin (hb → H) thu vào hai bên và trước/sau. Xe tải/buýt: một khối thùng.
        let hb = tall ? H : H * 0.55
        let sx = x0 > 0 ? -1.0 : 1.0   // mặt bên nhìn thấy: xe bên phải thấy hông trái
        let showSide = abs(x0) > 0.4
        if showSide {
            ctx.fill(quad(p(sx * hw, 0.15, 0), p(sx * hw, 0.15, L), p(sx * hw, hb, L), p(sx * hw, hb, 0), r: rad * 0.6),
                     with: .color(side))
        }
        ctx.fill(quad(p(-hw, hb, 0), p(hw, hb, 0), p(hw, hb, L), p(-hw, hb, L), r: rad), with: .color(top))
        if !tall {
            let cw = hw - 0.17 * W
            let cz0 = 1.0, cz1 = L - 1.45
            if showSide {
                ctx.fill(quad(p(sx * (hw - 0.06), hb, cz0 - 0.35), p(sx * (hw - 0.06), hb, cz1 + 0.5),
                              p(sx * cw, H, cz1), p(sx * cw, H, cz0 + 0.3)),
                         with: .color(pal.glass.opacity(0.85)))
            }
            ctx.fill(quad(p(-hw + 0.06, hb, cz0 - 0.35), p(hw - 0.06, hb, cz0 - 0.35), p(cw, H, cz0 + 0.3), p(-cw, H, cz0 + 0.3),
                          r: rad * 0.7),
                     with: .color(pal.glass))  // kính sau
            ctx.fill(quad(p(-cw, H, cz0 + 0.3), p(cw, H, cz0 + 0.3), p(cw, H, cz1), p(-cw, H, cz1), r: rad * 0.8),
                     with: .color(top))  // nóc
        }
        // bánh sau: chỉ lộ phần dưới cản
        for s in [-1.0, 1.0] {
            let cx = s * (hw - 0.2)
            ctx.fill(quad(p(cx - 0.13, 0, 0.1), p(cx + 0.13, 0, 0.1), p(cx + 0.13, 0.3, 0.1), p(cx - 0.13, 0.3, 0.1), r: rad * 0.3),
                     with: .color(Color(white: 0.1)))
        }
        // mặt sau
        ctx.fill(quad(p(-hw, 0.18, 0), p(hw, 0.18, 0), p(hw, hb, 0), p(-hw, hb, 0), r: rad * 0.8),
                 with: .linearGradient(Gradient(colors: [rear, side]), startPoint: p(0, hb, 0), endPoint: p(0, 0.18, 0)))
        // đèn hậu
        let ly = tall ? 0.6 : hb * 0.78
        for s in [-1.0, 1.0] {
            var l = Path()
            l.move(to: p(s * (hw - 0.08), ly, 0))
            l.addLine(to: p(s * (hw - (tall ? 0.35 : 0.5)), ly, 0))
            ctx.stroke(l, with: .color(Color(red: 0.9, green: 0.15, blue: 0.15).opacity(own ? 0.9 : 0.75)),
                       style: StrokeStyle(lineWidth: max(1, k * 0.12), lineCap: .round))
        }
        if car.isTarget, let d = snapshot.result.d {
            let label = Text(String(format: "%.0f m", d)).font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(pal.text)
            let t = p(0, H, 0)
            ctx.draw(label, at: CGPoint(x: t.x, y: t.y - 6), anchor: .bottom)
        }
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

    /// Hai mép làn mình theo mét. Thiếu vạch thì dựng thẳng / song song vạch còn lại.
    private func laneEdges() -> ([Ground], [Ground]) {
        // từ dưới gầm xe mình (mặt đường chạm đáy màn hình) tới thật xa (đường tan vào chân trời, không bị cụt)
        let zs = Array(stride(from: -14.0, through: Self.farZ, by: 2.5)) + Array(stride(from: Self.farZ + 20, through: 300, by: 20))
        func sample(_ c: LaneCurve?) -> [Ground]? {
            guard let c else { return nil }
            var pts: [Ground] = []
            for i in 0...30 {
                let yn = 0.5 + 0.5 * Double(i) / 30
                if let g = toGround(xPx: c.x(at: yn) * snapshot.frameWidth, yPx: yn * snapshot.frameHeight), g.z < 120 {
                    pts.append(g)
                }
            }
            guard pts.count >= 3 else { return nil }
            pts.sort { $0.z < $1.z }
            return zs.map { z in Ground(x: interp(pts, z), z: z) }
        }
        let half = Self.laneWidth / 2
        var l = sample(snapshot.laneLeft), r = sample(snapshot.laneRight)
        if let ll = l, let rr = r, abs(rr[0].x - ll[0].x) < 2.2 { r = nil }  // hai vạch quá sát: coi như chỉ có vạch trái
        switch (l, r) {
        case let (ll?, nil): r = ll.map { Ground(x: $0.x + Self.laneWidth, z: $0.z) }
        case let (nil, rr?): l = rr.map { Ground(x: $0.x - Self.laneWidth, z: $0.z) }
        case (nil, nil):
            l = zs.map { Ground(x: -half, z: $0) }
            r = zs.map { Ground(x: half, z: $0) }
        default: break
        }
        return (l!, r!)
    }

    /// x tại z trên đường gấp khúc (sắp theo z); ngoài khoảng thì kéo thẳng theo hai điểm đầu/cuối.
    private func interp(_ pts: [Ground], _ z: Double) -> Double {
        guard pts.count > 1 else { return pts.first?.x ?? 0 }
        func lerp(_ a: Ground, _ b: Ground) -> Double { b.z == a.z ? a.x : a.x + (z - a.z) * (b.x - a.x) / (b.z - a.z) }
        if z <= pts[0].z { return lerp(pts[0], pts[1]) }
        for i in 1..<pts.count where pts[i].z >= z { return lerp(pts[i - 1], pts[i]) }
        return lerp(pts[pts.count - 2], pts[pts.count - 1])
    }

    private func vehicles() -> [Car] {
        let s = snapshot
        var out: [Car] = []
        for (i, d) in s.detections.enumerated() {
            let kept = i < s.kept.count ? s.kept[i] : true
            guard kept, let wReal = config.vehicleWidthM[d.cls], d.width > 0, s.fPx > 0 else { continue }
            let isEgo = d.box == s.result.egoBox
            let z = isEgo ? (s.result.d ?? s.fPx * wReal / d.width) : s.fPx * wReal / d.width
            guard z < Self.farZ + 20 else { continue }
            let x = ((d.x1 + d.x2) / 2 - s.frameWidth / 2) * z / s.fPx
            let isCar = d.cls == "car"
            out.append(Car(pos: Ground(x: x, z: z), widthM: wReal, heightM: isCar ? 1.45 : 3.0, lengthM: isCar ? 4.5 : 9.0,
                           kind: isEgo ? .target : .other))
        }
        return out
    }
}

private struct Car {
    enum Kind { case own, target, other }
    var pos: Ground
    var widthM: Double
    var heightM: Double
    var lengthM: Double
    var kind: Kind

    var isTarget: Bool { kind == .target }
    var isOwn: Bool { kind == .own }
}

/// Camera ảo: cao 5.5 m, lùi sau camera thật 10 m, nhìn ra trước. Chiều sâu được nén lại (depth < 1)
/// để xe ở 20–60 m không bị dồn sát chân trời; số mét hiển thị vẫn là số thật.
private struct ChaseCamera {
    let size: CGSize
    let height = 5.5
    let back = 10.0
    let depth = 0.5

    var horizonY: CGFloat { size.height * 0.14 }
    var focal: Double { Double(size.height) * 1.1 }

    func scale(_ z: Double) -> Double { focal / max(z * depth + back, 0.5) }

    /// Điểm 3D: x ngang, y cao so với mặt đường, z phía trước (mét).
    func point3(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        let k = scale(z)
        return CGPoint(x: size.width / 2 + CGFloat(x * k), y: horizonY + CGFloat((height - y) * k))
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
