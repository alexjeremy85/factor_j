import Foundation

/// Limpeza pós-diarização: absorve "micro-falantes" (rótulos com pouquíssima
/// fala total) no falante substantivo mais próximo NO TEMPO.
///
/// Em áudio de reunião comprimido, o agrupamento em fluxo cria rótulos
/// espúrios de poucos segundos — quase sempre um respiro no meio da fala de
/// outra pessoa. A absorção temporal corrige isso sem depender das
/// embeddings (que nesse tipo de áudio não são confiáveis). Calibrado com
/// reunião real: min 30 s de fala total / vizinho a até 5 s.
public enum DiarizationCleanup {
    public static let defaultMinSpeakerMs = 30_000
    public static let defaultMaxGapMs = 5_000

    public static func absorbMicroSpeakers(
        _ spans: [DiarizedSpan],
        minSpeakerMs: Int = defaultMinSpeakerMs,
        maxGapMs: Int = defaultMaxGapMs
    ) -> [DiarizedSpan] {
        guard !spans.isEmpty else { return spans }

        var totalMs: [String: Int] = [:]
        for span in spans {
            totalMs[span.speakerKey, default: 0] += span.endMs - span.startMs
        }
        let microKeys = Set(totalMs.filter { $0.value < minSpeakerMs }.keys)
        // Se todo mundo é "micro" (gravação curta), não há referência — mantém.
        guard !microKeys.isEmpty, microKeys.count < totalMs.count else { return spans }

        let anchors = spans.filter { !microKeys.contains($0.speakerKey) }
        var result = spans
        for index in result.indices where microKeys.contains(result[index].speakerKey) {
            let span = result[index]
            var best: (gap: Int, key: String)?
            for anchor in anchors {
                let gap = max(anchor.startMs - span.endMs, span.startMs - anchor.endMs, 0)
                if best == nil || gap < best!.gap {
                    best = (gap, anchor.speakerKey)
                }
            }
            if let best, best.gap <= maxGapMs {
                result[index].speakerKey = best.key
            }
        }
        return result
    }
}
