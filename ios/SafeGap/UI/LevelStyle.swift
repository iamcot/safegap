import SafeGapCore
import SwiftUI

extension Level {
    var color: Color {
        switch self {
        case .none: return Color(white: 0.18)
        case .green: return Color(red: 0.10, green: 0.62, blue: 0.25)
        case .yellow: return Color(red: 0.98, green: 0.80, blue: 0.10)
        case .red: return Color(red: 0.86, green: 0.12, blue: 0.12)
        }
    }

    var textColor: Color { self == .yellow ? .black : .white }

    var label: String {
        switch self {
        case .none: return "—"
        case .green: return "AN TOÀN"
        case .yellow: return "CHÚ Ý"
        case .red: return "QUÁ GẦN"
        }
    }
}
