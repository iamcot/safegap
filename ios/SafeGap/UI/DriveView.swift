// Màn hình lái khi ẩn camera: vẽ lại con đường theo mét (kiểu bảng đồng hồ xe điện), full màn hình.
// Vạch làn và các xe được chiếu ngược từ ảnh xuống mặt đường (X ngang, Z phía trước, mét),
// rồi vẽ lại bằng một "camera ảo" đặt sau và cao hơn xe mình.
import SafeGapCore
import SwiftUI

struct DriveView: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool

    var body: some View {
        let s = model.snapshot
        let r = s.result
        ZStack {
            RoadCanvas(snapshot: s, calibration: model.calibration, config: model.config)
                .ignoresSafeArea()
            AlertGlow(level: r.level).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    SpeedBlock(snapshot: s)
                    Spacer()
                    controls
                }
                Spacer()
                HStack(alignment: .bottom) {
                    statusLine(s)
                    Spacer()
                    DistanceBlock(result: r)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .background(Color.black)
        .animation(.easeInOut(duration: 0.25), value: r.level)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            GlassButton { model.toggleZoom() } label: {
                Text(model.settings.zoom2x ? "2x" : "1x").font(.system(size: 16, weight: .bold, design: .rounded))
            }
            GlassButton { model.beginCalibration() } label: { Image(systemName: "scope") }
            GlassButton { showSettings = true } label: { Image(systemName: "gearshape.fill") }
        }
    }

    private func statusLine(_ s: FrameSnapshot) -> some View {
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
                Label("Chưa hiệu chỉnh máy này: bấm ◎", systemImage: "scope").foregroundStyle(.yellow)
            }
            HStack(spacing: 8) {
                if model.logURL != nil {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                }
                Text(String(format: "%.0f fps · YOLO %.0f ms · f %.0f px", s.fps, s.inferMs, s.fPx)).monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.45))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.8))
    }
}

// MARK: - Khối chữ

private struct SpeedBlock: View {
    let snapshot: FrameSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: -6) {
            Text(snapshot.result.speedKmh.map { String(format: "%.0f", $0) } ?? "--")
                .font(.system(size: 72, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            HStack(spacing: 6) {
                Text("km/h").font(.system(size: 15, weight: .semibold))
                if snapshot.speedSimulated {
                    Chip(text: "giả lập")
                } else if !snapshot.gpsOK {
                    Chip(text: "chưa có GPS")
                }
            }
            .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 8)
    }
}

private struct DistanceBlock: View {
    let result: FrameResult

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(result.level.label)
                .font(.system(size: 13, weight: .heavy))
                .tracking(1.5)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(result.level.accent.opacity(result.level == .none ? 0.25 : 0.9), in: Capsule())
                .foregroundStyle(result.level == .yellow ? .black : .white)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(result.d.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("m").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            Text("Cần giữ ≥ " + (result.dMin.map { String(format: "%.0f m", $0) } ?? "--"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 8)
    }
}

private struct Chip: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.white.opacity(0.12), in: Capsule())
    }
}

private struct GlassButton<L: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> L

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 40)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.12)))
        }
        .environment(\.colorScheme, .dark)
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
    /// Màu nhấn trên nền tối.
    var accentRGB: (Double, Double, Double) {
        switch self {
        case .none: return (0.6, 0.6, 0.6)
        case .green: return (0.20, 0.85, 0.45)
        case .yellow: return (1.00, 0.80, 0.15)
        case .red: return (1.00, 0.22, 0.20)
        }
    }

    var accent: Color { Color(red: accentRGB.0, green: accentRGB.1, blue: accentRGB.2) }
}

// MARK: - Con đường

/// Điểm trên mặt đường, mét: x sang phải, z về phía trước tính từ camera.
private struct Ground { var x: Double; var z: Double }

private struct RoadCanvas: View {
    let snapshot: FrameSnapshot
    let calibration: DeviceCalibration
    let config: AppConfig

    static let laneWidth = 3.5
    static let farZ = 70.0

    var body: some View {
        Canvas { ctx, size in
            let cam = ChaseCamera(size: size)
            drawBackdrop(ctx, size, cam)

            let (left, right) = laneEdges()
            // làn hai bên mờ
            for side in [-1.0, 1.0] {
                let edge = side < 0 ? left : right
                let outer = edge.map { Ground(x: $0.x + side * Self.laneWidth, z: $0.z) }
                let poly = side < 0 ? outer + edge.reversed() : edge + outer.reversed()
                ctx.fill(cam.path(poly, closed: true), with: .color(Color(white: 0.09)))
                ctx.stroke(cam.path(outer), with: .color(.white.opacity(0.12)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [10, 14]))
            }
            // mặt đường làn mình
            let road = left + right.reversed()
            ctx.fill(cam.path(road, closed: true),
                     with: .linearGradient(Gradient(colors: [Color(white: 0.20), Color(white: 0.12)]),
                                           startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: 0, y: cam.horizonY)))

            // thảm khoảng cách an toàn: từ đầu xe mình tới d_min
            let r = snapshot.result
            if let dMin = r.dMin, dMin > 0 {
                let zEnd = min(dMin, Self.farZ)
                let l = left.filter { $0.z >= 0 && $0.z <= zEnd }, rr = right.filter { $0.z >= 0 && $0.z <= zEnd }
                if l.count > 1, rr.count > 1 {
                    let carpet = l + rr.reversed()
                    let color = r.level == .none ? Color.cyan : r.level.accent
                    ctx.fill(cam.path(carpet, closed: true),
                             with: .linearGradient(Gradient(colors: [color.opacity(0.05), color.opacity(0.45)]),
                                                   startPoint: cam.point(Ground(x: 0, z: 0)),
                                                   endPoint: cam.point(Ground(x: 0, z: zEnd))))
                    var end = Path()
                    end.move(to: cam.point(l.last!)); end.addLine(to: cam.point(rr.last!))
                    ctx.stroke(end, with: .color(color), lineWidth: 2.5)
                }
            }
            // vạch mét
            for z in stride(from: 10.0, through: 60.0, by: 10.0) {
                guard let p = right.min(by: { abs($0.z - z) < abs($1.z - z) }) else { continue }
                let a = cam.point(Ground(x: p.x + 0.4, z: z))
                ctx.draw(Text("\(Int(z))").font(.system(size: CGFloat(max(8, 13 * cam.scale(z) / cam.scale(10))), weight: .medium))
                            .foregroundColor(.white.opacity(0.35)), at: a, anchor: .leading)
            }
            // vạch làn
            let detected = (snapshot.laneLeft != nil, snapshot.laneRight != nil)
            for (edge, real) in [(left, detected.0), (right, detected.1)] {
                ctx.stroke(cam.path(edge), with: .color(.white.opacity(real ? 0.95 : 0.35)),
                           style: StrokeStyle(lineWidth: real ? 4 : 2, lineCap: .round, dash: [16, 14]))
            }

            // xe: xa vẽ trước
            for v in vehicles().sorted(by: { $0.pos.z > $1.pos.z }) {
                drawCar(ctx, cam, v)
            }
            // xe mình
            drawCar(ctx, cam, Car(pos: Ground(x: 0, z: -1.5), widthM: 1.8, heightM: 1.45, kind: .own))
        }
    }

    // MARK: dựng hình

    private func drawBackdrop(_ ctx: GraphicsContext, _ size: CGSize, _ cam: ChaseCamera) {
        let all = CGRect(origin: .zero, size: size)
        ctx.fill(Path(all), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.02, green: 0.03, blue: 0.06), location: 0),
                             .init(color: Color(red: 0.06, green: 0.08, blue: 0.13), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: cam.horizonY)))
        ctx.fill(Path(CGRect(x: 0, y: cam.horizonY, width: size.width, height: size.height - cam.horizonY)),
                 with: .color(Color(red: 0.03, green: 0.035, blue: 0.045)))
        // quầng sáng chân trời
        ctx.fill(Path(ellipseIn: CGRect(x: size.width * 0.15, y: cam.horizonY - 40, width: size.width * 0.7, height: 80)),
                 with: .radialGradient(Gradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.55).opacity(0.35), .clear]),
                                       center: CGPoint(x: size.width / 2, y: cam.horizonY), startRadius: 0, endRadius: size.width * 0.35))
    }

    /// Xe nhìn từ sau, hơi từ trên xuống (camera ảo cao hơn xe): cản, cốp + dải đèn hậu, kính sau, nóc.
    /// Toạ độ (u, v) tính theo bề rộng xe: u ngang (-0.5…0.5), v cao từ mặt đường lên.
    private func drawCar(_ ctx: GraphicsContext, _ cam: ChaseCamera, _ car: Car) {
        let base = cam.point(car.pos)
        let w = CGFloat(car.widthM * cam.scale(car.pos.z))
        guard w > 3 else { return }
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: base.x + u * w, y: base.y - v * w) }
        func shape(_ uv: [(CGFloat, CGFloat)], r: CGFloat) -> Path {
            let pts = uv.map { pt($0.0, $0.1) }
            var p = Path()
            let n = pts.count
            p.move(to: CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2))
            for i in 0..<n {
                p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: r * w)
            }
            p.closeSubpath()
            return p
        }
        func vGrad(_ top: Color, _ bottom: Color, _ v0: CGFloat, _ v1: CGFloat) -> GraphicsContext.Shading {
            .linearGradient(Gradient(colors: [top, bottom]), startPoint: pt(0, v1), endPoint: pt(0, v0))
        }

        let rgb: (Double, Double, Double)
        switch car.kind {
        case .own: rgb = (0.86, 0.86, 0.88)
        case .target(let level): rgb = level == .none ? (0.55, 0.62, 0.72) : level.accentRGB
        case .other: rgb = (0.30, 0.33, 0.38)
        }
        func tone(_ t: Double, toward x: Double) -> Color {  // trộn màu sơn với đen (x = 0) hoặc trắng (x = 1)
            Color(red: rgb.0 + (x - rgb.0) * t, green: rgb.1 + (x - rgb.1) * t, blue: rgb.2 + (x - rgb.2) * t)
        }
        let paint = tone(0, toward: 0)
        let dark = tone(0.55, toward: 0)
        let light = tone(0.35, toward: 1)
        let isTarget: Bool = { if case .target = car.kind { return true } else { return false } }()
        let tall = car.heightM > 2   // xe tải, buýt: thùng vuông cao
        let topV: CGFloat = tall ? CGFloat(car.heightM / car.widthM) : 0.86

        // bóng đổ + quầng sáng dưới xe đang bám
        ctx.fill(Path(ellipseIn: CGRect(x: base.x - w * 0.62, y: base.y - w * 0.07, width: w * 1.24, height: w * 0.16)),
                 with: .color(.black.opacity(0.55)))
        if isTarget {
            var glow = ctx
            glow.addFilter(.blur(radius: w * 0.18))
            glow.fill(Path(ellipseIn: CGRect(x: base.x - w * 0.75, y: base.y - w * 0.12, width: w * 1.5, height: w * 0.26)),
                      with: .color(paint.opacity(0.7)))
        }
        // bánh xe
        for u in [-0.44, 0.30] as [CGFloat] {
            ctx.fill(Path(roundedRect: CGRect(origin: pt(u, 0.16), size: CGSize(width: w * 0.14, height: w * 0.16)),
                          cornerRadius: w * 0.03), with: .color(Color(white: 0.05)))
        }

        if tall {
            // thùng xe tải / buýt
            let box = shape([(-0.5, topV), (0.5, topV), (0.5, 0.08), (-0.5, 0.08)], r: 0.05)
            ctx.fill(box, with: vGrad(light, dark, 0.08, topV))
            ctx.fill(shape([(-0.47, topV + 0.12), (0.47, topV + 0.12), (0.5, topV), (-0.5, topV)], r: 0.03),
                     with: .color(light))  // nóc thùng
            var seam = Path(); seam.move(to: pt(0, topV - 0.06)); seam.addLine(to: pt(0, 0.22))
            ctx.stroke(seam, with: .color(.black.opacity(0.35)), lineWidth: max(0.5, w * 0.012))
            for u in [-0.45, 0.33] as [CGFloat] {
                ctx.fill(Path(roundedRect: CGRect(origin: pt(u, 0.26), size: CGSize(width: w * 0.12, height: w * 0.08)),
                              cornerRadius: w * 0.02), with: .color(Color(red: 1, green: 0.2, blue: 0.15)))
            }
        } else {
            // cản sau
            ctx.fill(shape([(-0.5, 0.31), (0.5, 0.31), (0.48, 0.07), (-0.48, 0.07)], r: 0.06), with: vGrad(paint, dark, 0.07, 0.31))
            ctx.fill(Path(roundedRect: CGRect(origin: pt(-0.18, 0.17), size: CGSize(width: w * 0.36, height: w * 0.07)),
                          cornerRadius: w * 0.01), with: .color(Color(white: 0.92).opacity(0.85)))  // biển số
            // cốp
            ctx.fill(shape([(-0.46, 0.50), (0.46, 0.50), (0.5, 0.31), (-0.5, 0.31)], r: 0.05), with: vGrad(light, paint, 0.31, 0.50))
            // dải đèn hậu
            var lights = ctx
            lights.addFilter(.shadow(color: Color.red.opacity(0.9), radius: w * 0.06))
            lights.fill(shape([(-0.47, 0.43), (0.47, 0.43), (0.48, 0.385), (-0.48, 0.385)], r: 0.02),
                        with: .color(Color(red: 1, green: 0.12, blue: 0.12)))
            // kính sau
            ctx.fill(shape([(-0.33, 0.70), (0.33, 0.70), (0.41, 0.51), (-0.41, 0.51)], r: 0.04),
                     with: vGrad(Color(red: 0.25, green: 0.3, blue: 0.38), Color(white: 0.05), 0.51, 0.70))
            var shine = Path()  // vệt phản chiếu trên kính
            shine.move(to: pt(-0.22, 0.68)); shine.addLine(to: pt(-0.06, 0.68)); shine.addLine(to: pt(-0.18, 0.53)); shine.addLine(to: pt(-0.30, 0.53))
            shine.closeSubpath()
            ctx.fill(shine, with: .color(.white.opacity(0.08)))
            // nóc
            ctx.fill(shape([(-0.29, topV), (0.29, topV), (0.33, 0.70), (-0.33, 0.70)], r: 0.06), with: vGrad(light, paint, 0.70, topV))
        }
        // viền sáng mép trên
        var rim = Path()
        rim.move(to: pt(tall ? -0.47 : -0.27, topV + (tall ? 0.12 : 0)))
        rim.addLine(to: pt(tall ? 0.47 : 0.27, topV + (tall ? 0.12 : 0)))
        ctx.stroke(rim, with: .color(.white.opacity(0.35)), lineWidth: max(0.5, w * 0.012))

        if isTarget, let d = snapshot.result.d {
            let label = Text(String(format: "%.0f m", d)).font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            let top = pt(0, topV + (tall ? 0.12 : 0))
            ctx.draw(label, at: CGPoint(x: top.x, y: top.y - 8), anchor: .bottom)
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

    /// Hai mép làn mình theo mét, từ z = 0 tới farZ. Thiếu vạch thì dựng thẳng / song song vạch còn lại.
    private func laneEdges() -> ([Ground], [Ground]) {
        let zs = stride(from: -12.0, through: Self.farZ, by: 2.5).map { $0 }  // từ dưới gầm xe mình để mặt đường chạm đáy màn hình
        func sample(_ c: LaneCurve?) -> [Ground]? {
            guard let c else { return nil }
            // lấy điểm ảnh trong vùng tin được (dưới chân trời, tới đáy ảnh) rồi nội suy theo z
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

    private func interp(_ pts: [Ground], _ z: Double) -> Double {
        if z <= pts[0].z {
            // ngoài tầm ảnh phía gần: kéo thẳng theo hướng hai điểm gần nhất
            let a = pts[0], b = pts[min(1, pts.count - 1)]
            return b.z == a.z ? a.x : a.x + (z - a.z) * (b.x - a.x) / (b.z - a.z)
        }
        for i in 1..<pts.count where pts[i].z >= z {
            let a = pts[i - 1], b = pts[i]
            return b.z == a.z ? a.x : a.x + (z - a.z) * (b.x - a.x) / (b.z - a.z)
        }
        let a = pts[max(0, pts.count - 2)], b = pts[pts.count - 1]
        return b.z == a.z ? b.x : b.x + (z - b.z) * (b.x - a.x) / (b.z - a.z)
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
            let height = d.cls == "car" ? 1.5 : 2.8
            out.append(Car(pos: Ground(x: x, z: z), widthM: wReal, heightM: height,
                           kind: isEgo ? .target(s.result.level) : .other))
        }
        return out
    }
}

private struct Car {
    enum Kind { case own, target(Level), other }
    var pos: Ground
    var widthM: Double
    var heightM: Double
    var kind: Kind
}

/// Camera ảo: cao 3.2 m, lùi sau camera thật 7 m, nhìn thẳng ra trước. Chiều sâu được nén lại
/// (depth < 1) để xe ở 20–60 m không bị dồn sát chân trời; số mét hiển thị vẫn là số thật.
private struct ChaseCamera {
    let size: CGSize
    let height = 3.2
    let back = 7.0
    let depth = 0.45

    var horizonY: CGFloat { size.height * 0.30 }
    var focal: Double { Double(size.height) * 1.05 }

    func scale(_ z: Double) -> Double { focal / max(z * depth + back, 0.5) }

    func point(_ g: Ground) -> CGPoint {
        let k = scale(g.z)
        return CGPoint(x: size.width / 2 + CGFloat(g.x * k), y: horizonY + CGFloat(height * k))
    }

    func path(_ pts: [Ground], closed: Bool = false) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: point(first))
        for g in pts.dropFirst() { p.addLine(to: point(g)) }
        if closed { p.closeSubpath() }
        return p
    }
}
