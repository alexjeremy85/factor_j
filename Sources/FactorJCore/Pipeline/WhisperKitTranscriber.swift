import Foundation
import WhisperKit

/// Adaptador do WhisperKit (CoreML) para o protocolo `TranscriptionEngine`.
///
/// Sempre opera offline: `download = false` e tokenizer resolvido de pasta
/// local. Se os modelos não estiverem no disco, `load()` falha com erro claro.
public final class WhisperKitTranscriber: TranscriptionEngine {
    private let modelFolder: URL
    private let tokenizerFolder: URL
    private var whisperKit: WhisperKit?

    public init(modelFolder: URL, tokenizerFolder: URL) {
        self.modelFolder = modelFolder
        self.tokenizerFolder = tokenizerFolder
    }

    public func load() async throws {
        guard whisperKit == nil else { return }
        let config = WhisperKitConfig()
        config.modelFolder = modelFolder.path
        config.tokenizerFolder = tokenizerFolder
        config.download = false
        config.load = true
        // Prewarm reduz o pico de memória na especialização CoreML (M2 16 GB).
        config.prewarm = true
        config.verbose = false
        config.logLevel = .error
        do {
            whisperKit = try await WhisperKit(config)
        } catch {
            throw PipelineError.modelsMissing(
                "Whisper em \(modelFolder.lastPathComponent) (\(error.localizedDescription))"
            )
        }
    }

    public func unload() {
        whisperKit = nil
    }

    public func transcribe(
        samples: [Float],
        language: String?,
        offsetMs: Int
    ) async throws -> (segments: [TranscribedSegment], detectedLanguage: String?) {
        guard let whisperKit else {
            throw PipelineError.transcriptionFailed("modelo não carregado")
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )

        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
        } catch {
            throw PipelineError.transcriptionFailed(error.localizedDescription)
        }

        var segments: [TranscribedSegment] = []
        for result in results {
            for segment in result.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let words = (segment.words ?? []).compactMap { word -> TranscribedWord? in
                    let wordText = word.word.trimmingCharacters(in: .whitespaces)
                    guard !wordText.isEmpty else { return nil }
                    return TranscribedWord(
                        text: wordText,
                        startMs: Int(word.start * 1000) + offsetMs,
                        endMs: Int(word.end * 1000) + offsetMs,
                        probability: Double(min(max(word.probability, 0), 1))
                    )
                }

                let confidence = Double(min(max(exp(segment.avgLogprob), 0), 1))
                segments.append(TranscribedSegment(
                    text: text,
                    startMs: Int(segment.start * 1000) + offsetMs,
                    endMs: Int(segment.end * 1000) + offsetMs,
                    confidence: confidence,
                    words: words
                ))
            }
        }
        segments.sort { $0.startMs < $1.startMs }

        let detected = results.first?.language
        return (segments, detected)
    }
}
