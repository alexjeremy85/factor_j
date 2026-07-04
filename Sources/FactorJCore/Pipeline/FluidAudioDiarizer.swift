import FluidAudio
import Foundation

/// Adaptador do FluidAudio (Pyannote segmentation + WeSpeaker no CoreML/ANE)
/// para o protocolo `DiarizationEngine`.
///
/// Uma instância por gravação: o `SpeakerManager` interno mantém a identidade
/// dos falantes entre janelas sucessivas (`atTime` desloca os tempos para o
/// absoluto da gravação).
public final class FluidAudioDiarizer: DiarizationEngine {
    private let manager: DiarizerManager

    public init(
        segmentationModel: URL,
        embeddingModel: URL,
        numSpeakers: Int? = nil
    ) throws {
        var config = DiarizerConfig()
        if let numSpeakers, numSpeakers > 0 {
            config.numClusters = numSpeakers
        }
        manager = DiarizerManager(config: config)
        do {
            let models = try DiarizerModels.load(
                localSegmentationModel: segmentationModel,
                localEmbeddingModel: embeddingModel
            )
            manager.initialize(models: models)
        } catch {
            throw PipelineError.modelsMissing(
                "diarização (\(error.localizedDescription))"
            )
        }
    }

    public func diarize(samples: [Float], offsetMs: Int) throws -> [DiarizedSpan] {
        do {
            let result = try manager.performCompleteDiarization(
                samples,
                sampleRate: 16_000,
                atTime: Double(offsetMs) / 1000.0
            )
            // Com `atTime`, os tempos retornados já são absolutos na gravação.
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
