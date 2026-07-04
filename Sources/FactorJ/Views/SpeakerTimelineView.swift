import FactorJCore
import SwiftUI

/// Faixa horizontal colorida mostrando quem fala em cada trecho (§7.3).
/// Clique navega o áudio para o ponto correspondente.
struct SpeakerTimelineView: View {
    let segments: [Segment]
    let speakersById: [Int64: Speaker]
    var markers: [Marker] = []
    let durationMs: Int
    let currentMs: Int
    let onSeek: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            Canvas { context, size in
                // Fundo
                context.fill(
                    Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 5),
                    with: .color(Color.secondary.opacity(0.12))
                )
                guard durationMs > 0 else { return }

                // Trechos por falante
                for segment in segments {
                    let x = CGFloat(segment.startMs) / CGFloat(durationMs) * size.width
                    let w = max(
                        CGFloat(segment.endMs - segment.startMs)
                            / CGFloat(durationMs) * size.width,
                        1.5
                    )
                    let speaker = segment.speakerId.flatMap { speakersById[$0] }
                    let color = SpeakerPalette.color(for: speaker)
                    context.fill(
                        Path(CGRect(x: x, y: 3, width: w, height: size.height - 6)),
                        with: .color(color.opacity(segment.isOverlap ? 0.55 : 0.9))
                    )
                }

                // Marcadores manuais ("Marcar momento")
                for marker in markers {
                    let x = CGFloat(marker.timestampMs) / CGFloat(durationMs) * size.width
                    var pin = Path()
                    pin.move(to: CGPoint(x: x, y: 6))
                    pin.addLine(to: CGPoint(x: x - 3.5, y: 0))
                    pin.addLine(to: CGPoint(x: x + 3.5, y: 0))
                    pin.closeSubpath()
                    context.fill(pin, with: .color(.yellow))
                }

                // Posição atual
                let cursorX = CGFloat(min(currentMs, durationMs))
                    / CGFloat(durationMs) * size.width
                context.fill(
                    Path(CGRect(x: cursorX - 0.75, y: 0, width: 1.5, height: size.height)),
                    with: .color(.primary.opacity(0.8))
                )
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard durationMs > 0, width > 0 else { return }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        onSeek(Int(fraction * CGFloat(durationMs)))
                    }
            )
            .frame(height: height)
        }
        .help("Clique para navegar no áudio")
    }
}
