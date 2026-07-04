import Foundation

/// Alinha a saída do ASR com a diarização, produzindo turnos de fala por
/// falante (RF-A5).
///
/// Estratégia:
/// - Com word timestamps: cada palavra é atribuída ao falante com maior
///   interseção temporal; palavras consecutivas do mesmo falante viram um
///   turno. Isso permite quebrar um segmento do Whisper que atravessa uma
///   troca de falante.
/// - Sem word timestamps (fallback): o segmento inteiro é atribuído ao
///   falante com maior interseção.
/// - Trechos onde dois ou mais falantes falam ao mesmo tempo recebem
///   `isOverlap = true`.
public enum Aligner {
    /// Pausa mínima (ms) para quebrar turno mesmo sem troca de falante.
    public static let pauseBreakMs = 1500
    /// Distância máxima (ms) para "adotar" o falante mais próximo quando a
    /// palavra cai fora de qualquer trecho diarizado.
    public static let adoptionRadiusMs = 1000

    public static func align(
        transcription: [TranscribedSegment],
        diarization: [DiarizedSpan]
    ) -> [AlignedTurn] {
        guard !transcription.isEmpty else { return [] }
        guard !diarization.isEmpty else {
            // Diarização desligada/vazia: um turno por segmento do ASR.
            return transcription.map {
                AlignedTurn(
                    speakerKey: nil,
                    startMs: $0.startMs,
                    endMs: $0.endMs,
                    text: $0.text.trimmingCharacters(in: .whitespaces),
                    confidence: $0.confidence
                )
            }
        }

        let spans = diarization.sorted { $0.startMs < $1.startMs }
        let units = makeUnits(from: transcription)

        var assigned: [(unit: Unit, speaker: String?, overlap: Bool)] = []
        assigned.reserveCapacity(units.count)

        for unit in units {
            let (speaker, overlap) = assignSpeaker(
                for: unit,
                in: spans,
                previous: assigned.last?.speaker
            )
            assigned.append((unit, speaker, overlap))
        }

        // Palavras órfãs entre dois trechos do mesmo falante herdam o falante anterior.
        for i in assigned.indices where assigned[i].speaker == nil {
            if i > 0 { assigned[i].speaker = assigned[i - 1].speaker }
        }

        return groupIntoTurns(assigned)
    }

    // MARK: - Unidades de alinhamento

    /// Unidade mínima alinhável: palavra (preferido) ou segmento inteiro.
    struct Unit {
        var text: String
        var startMs: Int
        var endMs: Int
        var probability: Double
        /// Segmento do ASR de origem (índice), usado para herdar confiança.
        var sourceIndex: Int
    }

    private static func makeUnits(from segments: [TranscribedSegment]) -> [Unit] {
        var units: [Unit] = []
        for (index, segment) in segments.enumerated() {
            if segment.words.isEmpty {
                let text = segment.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                units.append(Unit(
                    text: text,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    probability: segment.confidence,
                    sourceIndex: index
                ))
            } else {
                for word in segment.words {
                    let text = word.text.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    units.append(Unit(
                        text: text,
                        startMs: word.startMs,
                        endMs: word.endMs,
                        probability: word.probability,
                        sourceIndex: index
                    ))
                }
            }
        }
        return units.sorted { $0.startMs < $1.startMs }
    }

    // MARK: - Atribuição de falante

    private static func assignSpeaker(
        for unit: Unit,
        in spans: [DiarizedSpan],
        previous: String?
    ) -> (speaker: String?, overlap: Bool) {
        var overlapBySpeaker: [String: Int] = [:]
        var activeSpeakers = Set<String>()

        for span in spans {
            if span.startMs >= unit.endMs { break }
            let intersection = min(unit.endMs, span.endMs) - max(unit.startMs, span.startMs)
            if intersection > 0 {
                overlapBySpeaker[span.speakerKey, default: 0] += intersection
                activeSpeakers.insert(span.speakerKey)
            }
        }

        if let maxValue = overlapBySpeaker.values.max() {
            // Empate (fala sobreposta): prefere a continuidade do falante
            // anterior; senão, desempate determinístico por chave.
            let candidates = overlapBySpeaker
                .filter { $0.value == maxValue }
                .keys
            let best: String
            if let previous, candidates.contains(previous) {
                best = previous
            } else {
                best = candidates.sorted().first!
            }
            return (best, activeSpeakers.count > 1)
        }

        // Sem interseção: adota o trecho diarizado mais próximo, se estiver perto.
        var nearest: (key: String, distance: Int)?
        for span in spans {
            let distance: Int
            if span.endMs <= unit.startMs {
                distance = unit.startMs - span.endMs
            } else if span.startMs >= unit.endMs {
                distance = span.startMs - unit.endMs
            } else {
                distance = 0
            }
            if nearest == nil || distance < nearest!.distance {
                nearest = (span.speakerKey, distance)
            }
        }
        if let nearest, nearest.distance <= adoptionRadiusMs {
            return (nearest.key, false)
        }
        return (nil, false)
    }

    // MARK: - Agrupamento em turnos

    private static func groupIntoTurns(
        _ assigned: [(unit: Unit, speaker: String?, overlap: Bool)]
    ) -> [AlignedTurn] {
        var turns: [AlignedTurn] = []
        var currentTexts: [String] = []
        var currentProbs: [Double] = []
        var currentSpeaker: String?
        var currentStart = 0
        var currentEnd = 0
        var currentOverlap = false

        func flush() {
            guard !currentTexts.isEmpty else { return }
            let confidence = currentProbs.isEmpty
                ? nil
                : currentProbs.reduce(0, +) / Double(currentProbs.count)
            turns.append(AlignedTurn(
                speakerKey: currentSpeaker,
                startMs: currentStart,
                endMs: currentEnd,
                text: currentTexts.joined(separator: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                    .trimmingCharacters(in: .whitespaces),
                confidence: confidence.map { min(max($0, 0), 1) },
                isOverlap: currentOverlap
            ))
            currentTexts = []
            currentProbs = []
            currentOverlap = false
        }

        for (unit, speaker, overlap) in assigned {
            let speakerChanged = speaker != currentSpeaker
            let longPause = !currentTexts.isEmpty && (unit.startMs - currentEnd) > pauseBreakMs
            if currentTexts.isEmpty || speakerChanged || longPause {
                flush()
                currentSpeaker = speaker
                currentStart = unit.startMs
                currentEnd = unit.endMs
            }
            currentTexts.append(unit.text)
            currentProbs.append(unit.probability)
            currentEnd = max(currentEnd, unit.endMs)
            currentOverlap = currentOverlap || overlap
        }
        flush()

        return turns
    }
}
