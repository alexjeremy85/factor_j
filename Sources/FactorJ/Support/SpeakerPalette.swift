import FactorJCore
import SwiftUI

/// Cores dos falantes (uma por `colorIndex`, ciclo de 8).
enum SpeakerPalette {
    static let colors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .red, .indigo,
    ]

    static func color(index: Int) -> Color {
        colors[abs(index) % colors.count]
    }

    static func color(for speaker: Speaker?) -> Color {
        guard let speaker else { return .gray }
        return color(index: speaker.colorIndex)
    }

    /// Iniciais para o avatar ("Fulano Silva" → "RS").
    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }
}
