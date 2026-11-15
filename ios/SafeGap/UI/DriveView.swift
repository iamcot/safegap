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
                let l = left.filter { $0.z <= zEnd }, rr = right.filter { $0.z <= zEnd }
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

    private func drawCar(_ ctx: GraphicsContext, _ cam: ChaseCamera, _ car: Car) {
        let base = cam.point(car.pos)
        let k = cam.scale(car.pos.z)
        let w = CGFloat(car.widthM * k), h = CGFloat(car.heightM * k)
        guard w > 2 else { return }
        let body = CGRect(x: base.x - w / 2, y: base.y - h * 0.62, width: w, height: h * 0.62)
        let cabin = CGRect(x: base.x - w * 0.36, y: base.y - h, width: w * 0.72, height: h * 0.42)
        let (fill, edge): (Color, Color) = {
            switch car.kind {
            case .own: return (Color(white: 0.88), .white)
            case .target(let level): return (level == .none ? Color(white: 0.75) : level.accent, .white)
            case .other: return (Color(white: 0.38), Color(white: 0.55))
            }
        }()
        var g = ctx
        if case .target = car.kind {
            g.addFilter(.shadow(color: fill.opacity(0.8), radius: 14))
        }
        // bóng dưới gầm
        g.fill(Path(ellipseIn: CGRect(x: base.x - w * 0.6, y: base.y - h * 0.06, width: w * 1.2, height: h * 0.16)),
               with: .color(.black.opacity(0.5)))
        g.fill(Path(roundedRect: cabin, cornerRadius: w * 0.12), with: .color(fill.opacity(0.75)))
        g.fill(Path(roundedRect: cabin.insetBy(dx: w * 0.05, dy: h * 0.07), cornerRadius: w * 0.07),
               with: .color(Color(white: 0.08).opacity(0.85)))
        g.fill(Path(roundedRect: body, cornerRadius: w * 0.14), with: .color(fill))
        g.stroke(Path(roundedRect: body, cornerRadius: w * 0.14), with: .color(edge.opacity(0.6)), lineWidth: max(0.5, w * 0.012))
        // đèn hậu
        let lw = w * 0.2, lh = max(1, h * 0.07)
        for x in [body.minX + w * 0.06, body.maxX - w * 0.06 - lw] {
            g.fill(Path(roundedRect: CGRect(x: x, y: body.minY + h * 0.1, width: lw, height: lh), cornerRadius: lh / 2),
                   with: .color(Color(red: 1, green: 0.15, blue: 0.15)))
        }
        if case .target = car.kind, let d = snapshot.result.d {
            let label = Text(String(format: "%.0f m", d)).font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            ctx.draw(label, at: CGPoint(x: base.x, y: base.y - h - 14), anchor: .bottom)
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
        let zs = stride(from: 0.0, through: Self.farZ, by: 2.5).map { $0 }
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

/// Camera ảo: cao 3.2 m, lùi sau camera thật 7 m, nhìn thẳng ra trước.
private struct ChaseCamera {
    let size: CGSize
    let height = 3.2
    let back = 7.0

    var horizonY: CGFloat { size.height * 0.36 }
    var focal: Double { Double(size.height) * 1.05 }

    func scale(_ z: Double) -> Double { focal / max(z + back, 0.5) }

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
