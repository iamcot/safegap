// Hàng icon các biển cấm đang có hiệu lực (docs/DRIVER_ASSIST.md, B7), vẽ theo kiểu biển thật:
// tròn viền đỏ; cấm dừng đỗ nền xanh; biển không áp dụng lúc này (ngoài khung giờ, ngày chẵn/lẻ) thì mờ.
import SafeGapCore
import SwiftUI

struct SignIconsRow: View {
    let signs: [ActiveSign]
    var size: CGFloat = 46

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(signs) { s in
                VStack(spacing: 2) {
                    SignIcon(sign: s).frame(width: size, height: size)
                    if let w = s.window {
                        Text(w.label).font(.system(size: 10, weight: .bold)).monospacedDigit()
                            .padding(.horizontal, 4).background(.white, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.black)
                    }
                }
                .opacity(s.applies ? 1 : 0.35)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: signs.map(\.id))
    }
}

struct SignIcon: View {
    let sign: ActiveSign
    private let red = Color(red: 0.86, green: 0.1, blue: 0.1)
    private let blue = Color(red: 0.05, green: 0.32, blue: 0.75)

    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            let ring = d * 0.12
            let r = sign.rule
            ZStack {
                if sign.code == "P.102" {
                    // cấm đi ngược chiều: nền đỏ, vạch trắng ngang
                    Circle().fill(red)
                    RoundedRectangle(cornerRadius: d * 0.03).fill(.white).frame(width: d * 0.7, height: d * 0.2)
                } else if r.noStop == true || r.noPark == true {
                    Circle().fill(blue)
                    Circle().stroke(red, lineWidth: ring).padding(ring / 2)
                    slash(d: d, ring: ring, angle: 45)
                    if r.noStop == true { slash(d: d, ring: ring, angle: -45) }
                    if r.parity == "odd" || r.parity == "even" {
                        Text(r.parity == "odd" ? "I" : "II")
                            .font(.system(size: d * 0.22, weight: .heavy)).foregroundStyle(.white)
                            .offset(y: d * 0.02)
                    }
                } else {
                    Circle().fill(.white)
                    Circle().stroke(red, lineWidth: ring).padding(ring / 2)
                    content(d: d)
                    if r.speedLimit != true { slash(d: d, ring: ring, angle: -45) }
                }
            }
            .frame(width: d, height: d)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
    }

    @ViewBuilder private func content(d: CGFloat) -> some View {
        let r = sign.rule
        if r.speedLimit == true {
            Text(sign.value.map(String.init) ?? "?")
                .font(.system(size: d * 0.38, weight: .heavy, design: .rounded))
                .foregroundStyle(.black).minimumScaleFactor(0.5)
        } else if let t = r.forbidTurns, let first = t.first {
            Image(systemName: t.contains(.uturn) && t.count == 1 ? "arrow.uturn.down" :
                    (first == .left ? "arrow.turn.up.left" : (first == .right ? "arrow.turn.up.right" : "arrow.uturn.down")))
                .font(.system(size: d * 0.4, weight: .black)).foregroundStyle(.black)
        } else if r.vehicle == "truck" {
            Image(systemName: "truck.box.fill").font(.system(size: d * 0.36)).foregroundStyle(.black)
        } else if r.vehicle == "car" {
            Image(systemName: "car.fill").font(.system(size: d * 0.36)).foregroundStyle(.black)
        } else {
            Text(sign.code).font(.system(size: d * 0.18, weight: .bold)).foregroundStyle(.black)
        }
    }

    private func slash(d: CGFloat, ring: CGFloat, angle: Double) -> some View {
        Rectangle().fill(red).frame(width: d - ring * 1.6, height: ring * 0.9).rotationEffect(.degrees(angle))
    }
}
