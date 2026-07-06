import FluidAudio
import Foundation

/// Diarização de alta precisão via pipeline offline da FluidAudio
/// (segmentação pyannote + PLDA + clustering VBx com re-clustering global).
///
/// Diferente do motor padrão (que decide falantes em fluxo, janela a
/// janela), este processa o arquivo inteiro de uma vez — é o caminho certo
/// para 3+ falantes. O `process(url:)` usa streaming memory-mapped, então
/// a memória fica estável mesmo em gravações longas.
public final class VbxDiarizer: WholeFileDiarizationEngine {
    private let manager: OfflineDiarizerManager

    /// - Parameter modelsParentDirectory: pasta que CONTÉM
    ///   `speaker-diarization-coreml/` com os modelos offline
    ///   (layout esperado pela FluidAudio).
    public init(
        modelsParentDirectory: URL,
        numSpeakers: Int? = nil,
        sensitivity: VoiceSensitivity = .normal
    ) async throws {
        var config = OfflineDiarizerConfig.default
        config.clustering.threshold = sensitivity.vbxThreshold
        if let numSpeakers, numSpeakers > 0 {
            config.clustering.numSpeakers = numSpeakers
        }
        manager = OfflineDiarizerManager(config: config)
        do {
            // Os arquivos já estão no disco (gate de disponibilidade no
            // chamador); o load não toca a rede nesse caso.
            let models = try await OfflineDiarizerModels.load(from: modelsParentDirectory)
            manager.initialize(models: models)
        } catch {
            throw PipelineError.modelsMissing(
                "diarização VBx (\(error.localizedDescription))"
            )
        }
    }

    public func diarize(
        fileURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [DiarizedSpan] {
        do {
            let result = try await manager.process(fileURL) { done, total in
                guard total > 0 else { return }
                onProgress(Double(done) / Double(total))
            }
            return result.segments.map { segment in
                DiarizedSpan(
                    speakerKey: segment.speakerId,
                    startMs: Int(segment.startTimeSeconds * 1000),
                    endMs: Int(segment.endTimeSeconds * 1000),
                    quality: Double(segment.qualityScore)
                )
            }
        } catch {
            throw PipelineError.diarizationFailed(error.localizedDescription)
        }
    }
}
