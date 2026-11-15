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
    static let bg = Color(red: 0.035, green: 0.04, blue: 0.05)

    var body: some View {
        Canvas { ctx, size in
            let cam = ChaseCamera(size: size)
            drawBackdrop(ctx, size, cam)

            let (left, right) = laneEdges()
            let r = snapshot.result
            let accent = r.level == .none ? Color(red: 0.45, green: 0.75, blue: 1.0) : r.level.accent

            // mặt làn mình: chỉ một lớp sáng rất nhẹ
            ctx.fill(cam.path(left + right.reversed(), closed: true),
                     with: .linearGradient(Gradient(colors: [.white.opacity(0.07), .white.opacity(0.0)]),
                                           startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: 0, y: cam.horizonY)))
            // vạch làn bên cạnh: nét mảnh mờ
            for side in [-1.0, 1.0] {
                let edge = side < 0 ? left : right
                let outer = edge.map { Ground(x: $0.x + side * Self.laneWidth, z: $0.z) }
                ctx.stroke(cam.path(outer), with: .color(.white.opacity(0.13)), lineWidth: 1)
            }
            // vạch ngang mỗi 10 m trong làn mình + số mét
            for z in stride(from: 10.0, through: 60.0, by: 10.0) {
                guard let li = left.firstIndex(where: { $0.z >= z }), li < right.count else { continue }
                var tick = Path()
                tick.move(to: cam.point(left[li])); tick.addLine(to: cam.point(right[li]))
                ctx.stroke(tick, with: .color(.white.opacity(0.06)), lineWidth: 1)
                let fs = CGFloat(max(8, 12 * cam.scale(z) / cam.scale(10)))
                ctx.draw(Text("\(Int(z))").font(.system(size: fs, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.28)),
                         at: cam.point(Ground(x: right[li].x + 0.5, z: z)), anchor: .leading)
            }
            // thảm khoảng cách an toàn: từ đầu xe mình tới d_min, sáng dần về cuối, vạch cuối phát sáng
            if let dMin = r.dMin, dMin > 0 {
                let zEnd = min(dMin, Self.farZ)
                let l = left.filter { $0.z >= 0 && $0.z <= zEnd }, rr = right.filter { $0.z >= 0 && $0.z <= zEnd }
                if l.count > 1, rr.count > 1 {
                    ctx.fill(cam.path(l + rr.reversed(), closed: true),
                             with: .linearGradient(Gradient(colors: [accent.opacity(0.0), accent.opacity(0.28)]),
                                                   startPoint: cam.point(Ground(x: 0, z: 0)),
                                                   endPoint: cam.point(Ground(x: 0, z: zEnd))))
                    var end = Path()
                    end.move(to: cam.point(l.last!)); end.addLine(to: cam.point(rr.last!))
                    var g = ctx
                    g.addFilter(.shadow(color: accent, radius: 6))
                    g.stroke(end, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            // vạch làn mình: nét liền mảnh phát sáng; vạch tự dựng (không thấy) thì mờ
            let detected = (snapshot.laneLeft != nil, snapshot.laneRight != nil)
            for (edge, real) in [(left, detected.0), (right, detected.1)] {
                var g = ctx
                if real { g.addFilter(.shadow(color: .white.opacity(0.8), radius: 5)) }
                g.stroke(cam.path(edge), with: .color(.white.opacity(real ? 0.9 : 0.25)),
                         style: StrokeStyle(lineWidth: real ? 2 : 1.2, lineCap: .round))
            }
            // đường tan dần vào bóng tối ở xa
            let fadeEnd = cam.horizonY + size.height * 0.14
            ctx.fill(Path(CGRect(x: 0, y: cam.horizonY - 2, width: size.width, height: fadeEnd - cam.horizonY + 2)),
                     with: .linearGradient(Gradient(colors: [Self.bg, Self.bg.opacity(0)]),
                                           startPoint: CGPoint(x: 0, y: cam.horizonY), endPoint: CGPoint(x: 0, y: fadeEnd)))

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
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.bg))
        // quầng sáng rất nhẹ quanh điểm tụ
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .radialGradient(Gradient(colors: [Color(red: 0.3, green: 0.4, blue: 0.55).opacity(0.12), .clear]),
                                       center: CGPoint(x: size.width / 2, y: cam.horizonY), startRadius: 0, endRadius: size.width * 0.45))
    }

    /// Xe vẽ nét (line art) nhìn từ sau, hơi từ trên xuống: viền thân, kính sau, dải đèn hậu, cản.
    /// Toạ độ (u, v) tính theo bề rộng xe: u ngang (-0.5…0.5), v cao từ mặt đường lên.
    private func drawCar(_ ctx: GraphicsContext, _ cam: ChaseCamera, _ car: Car) {
        let base = cam.point(car.pos)
        let w = CGFloat(car.widthM * cam.scale(car.pos.z))
        guard w > 3 else { return }
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: base.x + u * w, y: base.y - v * w) }
        func shape(_ uv: [(CGFloat, CGFloat)], r: CGFloat, closed: Bool = true) -> Path {
            let pts = uv.map { pt($0.0, $0.1) }
            var p = Path()
            guard pts.count > 1 else { return p }
            if !closed {
                p.move(to: pts[0])
                for i in 1..<pts.count - 1 { p.addArc(tangent1End: pts[i], tangent2End: pts[i + 1], radius: r * w) }
                p.addLine(to: pts[pts.count - 1])
                return p
            }
            let n = pts.count
            p.move(to: CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2))
            for i in 0..<n { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: r * w) }
            p.closeSubpath()
            return p
        }

        let line: Color, glow: Color?, fillTop: Double
        var isTarget = false
        switch car.kind {
        case .own: line = .white.opacity(0.75); glow = .white.opacity(0.3); fillTop = 0.10
        case .target(let level):
            isTarget = true
            line = level == .none ? Color(red: 0.45, green: 0.75, blue: 1.0) : level.accent
            glow = line; fillTop = 0.22
        case .other: line = .white.opacity(0.45); glow = nil; fillTop = 0.05
        }
        let lw = max(0.8, min(2.2, w * 0.012))
        let tall = car.heightM > 2
        let topV: CGFloat = tall ? CGFloat(car.heightM / car.widthM) : 0.80

        // bóng mềm dưới xe
        var shadow = ctx
        shadow.addFilter(.blur(radius: w * 0.06))
        shadow.fill(Path(ellipseIn: CGRect(x: base.x - w * 0.6, y: base.y - w * 0.06, width: w * 1.2, height: w * 0.13)),
                    with: .color(isTarget ? line.opacity(0.35) : .black.opacity(0.6)))

        let outline: Path
        var details: [(Path, Double)] = []   // (nét, độ sáng)
        if tall {
            outline = shape([(-0.5, 0.06), (-0.5, topV), (-0.46, topV + 0.12), (0.46, topV + 0.12), (0.5, topV), (0.5, 0.06)], r: 0.04)
            var roof = Path(); roof.move(to: pt(-0.5, topV)); roof.addLine(to: pt(0.5, topV))
            var seam = Path(); seam.move(to: pt(0, topV - 0.08)); seam.addLine(to: pt(0, 0.24))
            var bumper = Path(); bumper.move(to: pt(-0.46, 0.2)); bumper.addLine(to: pt(0.46, 0.2))
            details = [(roof, 0.7), (seam, 0.35), (bumper, 0.5)]
        } else {
            outline = shape([(-0.47, 0.05), (-0.5, 0.30), (-0.45, 0.50), (-0.31, topV), (0.31, topV), (0.45, 0.50), (0.5, 0.30), (0.47, 0.05)],
                            r: 0.09)
            let window = shape([(-0.38, 0.52), (-0.28, 0.73), (0.28, 0.73), (0.38, 0.52)], r: 0.05)
            var bumper = Path(); bumper.move(to: pt(-0.42, 0.19)); bumper.addLine(to: pt(0.42, 0.19))
            var trunk = Path(); trunk.move(to: pt(-0.45, 0.50)); trunk.addLine(to: pt(0.45, 0.50))
            details = [(window, 0.8), (bumper, 0.4), (trunk, 0.3)]
        }
        // thân: che đường phía sau, phủ nhẹ từ trên xuống rồi viền
        ctx.fill(outline, with: .color(Self.bg))
        ctx.fill(outline, with: .linearGradient(Gradient(colors: [line.opacity(fillTop), line.opacity(0.0)]),
                                                startPoint: pt(0, topV), endPoint: pt(0, 0)))
        var g = ctx
        if let glow { g.addFilter(.shadow(color: glow, radius: isTarget ? 8 : 4)) }
        g.stroke(outline, with: .color(line), style: StrokeStyle(lineWidth: lw * (isTarget ? 1.4 : 1), lineJoin: .round))
        for (p, a) in details {
            ctx.stroke(p, with: .color(line.opacity(a)), style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
        }
        // dải đèn hậu: nét đỏ sáng
        var lights = ctx
        lights.addFilter(.shadow(color: .red, radius: max(2, w * 0.04)))
        let ly: CGFloat = tall ? 0.28 : 0.40
        let lightSpans: [(CGFloat, CGFloat)] = tall ? [(-0.46, -0.34), (0.34, 0.46)] : [(-0.44, 0.44)]
        for (u0, u1) in lightSpans {
            var p = Path(); p.move(to: pt(u0, ly)); p.addLine(to: pt(u1, ly))
            lights.stroke(p, with: .color(Color(red: 1, green: 0.25, blue: 0.25).opacity(car.kind.isOther ? 0.6 : 0.95)),
                          style: StrokeStyle(lineWidth: lw * 1.6, lineCap: .round))
        }

        if isTarget, let d = snapshot.result.d {
            let label = Text(String(format: "%.0f m", d)).font(.system(size: 14, weight: .semibold, design: .rounded))
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
    enum Kind {
        case own, target(Level), other
        var isOther: Bool { if case .other = self { return true } else { return false } }
    }
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
