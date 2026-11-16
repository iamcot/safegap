// Cụm 3 đèn giao thông vẽ ở giữa mép trên màn hình khi app thấy đèn (docs/DRIVER_ASSIST.md, A4).
// Đèn đang sáng phát sáng; khi đèn ra khỏi khung hình (đang giữ trạng thái cũ) thì nhấp nháy nhẹ.
import SafeGapCore
import SwiftUI

struct TrafficLightView: View {
    let state: TrafficLightState
    @State private var pulse = false

    private struct Lamp: Identifiable {
        var id: LightColor
        var color: Color
    }

    private static let lamps: [Lamp] = [
        Lamp(id: .red, color: Color(red: 1.0, green: 0.16, blue: 0.12)),
        Lamp(id: .yellow, color: Color(red: 1.0, green: 0.75, blue: 0.05)),
        Lamp(id: .green, color: Color(red: 0.10, green: 0.95, blue: 0.55)),
    ]

    var body: some View {
        let held = state.box == nil
        HStack(spacing: 10) {
            ForEach(Self.lamps) { lamp in
                let on = state.color == lamp.id
                Circle()
                    .fill(on ? lamp.color : lamp.color.opacity(0.13))
                    .overlay(Circle().fill(.white.opacity(on ? 0.35 : 0)).scaleEffect(0.35).offset(x: -4, y: -4).blur(radius: 2))
                    .frame(width: 30, height: 30)
                    .shadow(color: on ? lamp.color.opacity(0.9) : .clear, radius: on ? 12 : 0)
                    .shadow(color: on ? lamp.color.opacity(0.6) : .clear, radius: on ? 4 : 0)
                    .opacity(on && held && pulse ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.06).opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(white: 0.3), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        .animation(.easeInOut(duration: 0.2), value: state.color)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel("Đèn " + state.color.label)
    }
}
