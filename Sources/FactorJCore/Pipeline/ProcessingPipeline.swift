import Foundation

/// Executa o pipeline batch completo de uma gravação (§4):
/// conversão → janelas (transcrição + diarização) → alinhamento → persistência.
///
/// Arquivos longos são processados em janelas de ~20 min cortadas em pontos
/// de silêncio, mantendo o uso de memória estável (RF-A6). A identidade dos
/// falantes atravessa as janelas porque a mesma instância do diarizador é
/// reutilizada com offsets absolutos.
public final class ProcessingPipeline {
    /// Duração alvo de cada janela de processamento.
    public var windowSeconds: Double = 1200

    private let transcriber: TranscriptionEngine
    private let diarizer: DiarizationEngine?
    private let wholeFileDiarizer: WholeFileDiarizationEngine?

    public init(
        transcriber: TranscriptionEngine,
        diarizer: DiarizationEngine?,
        wholeFileDiarizer: WholeFileDiarizationEngine? = nil
    ) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.wholeFileDiarizer = wholeFileDiarizer
    }

    public struct Result {
        public var speakers: [Speaker]
        public var segments: [(speakerLabel: String?, segment: Segment)]
        public var duration: Double
        public var detectedLanguage: String?
    }

    /// Processa a gravação inteira. `sourceURL` é o áudio original;
    /// `workingWavURL` é onde o WAV 16 kHz intermediário será criado
    /// (e apagado ao final).
    public func run(
        recordingId: Int64,
        sourceURL: URL,
        workingWavURL: URL,
        language: String?,
        onProgress: @escaping @Sendable (PipelineProgress) -> Void
    ) async throws -> Result {
        defer { try? FileManager.default.removeItem(at: workingWavURL) }

        // Etapa 1 — conversão (0 → 0,15)
        onProgress(PipelineProgress(stage: .converting, fraction: 0))
        var lastReported = 0.0
        let duration = try await AudioConverter.convertToWav16k(
            source: sourceURL,
            destination: workingWavURL,
            progress: { fraction in
                // Reporta a cada 2% para não inundar a MainActor.
                if fraction - lastReported >= 0.02 || fraction >= 1 {
                    lastReported = fraction
                    onProgress(PipelineProgress(stage: .converting, fraction: fraction * 0.15))
                }
            }
        )

        try await transcriber.load()
        try Task.checkCancellation()

        // Etapa 2 — janelas: transcrição (+ diarização em fluxo, quando o
        // motor global não está em uso). Frações: com VBx as janelas ocupam
        // 0,15→0,70 e a diarização global 0,70→0,92; sem VBx, 0,15→0,92.
        let transcribeShare = wholeFileDiarizer != nil ? 0.55 : 0.77
        let reader = try WavWindowReader(url: workingWavURL)
        let windows = try makeWindows(reader: reader)
        var allSegments: [TranscribedSegment] = []
        var allSpans: [DiarizedSpan] = []
        var detectedLanguage: String?

        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            let windowBase = 0.15 + transcribeShare * (Double(index) / Double(windows.count))
            let windowShare = transcribeShare / Double(windows.count)

            let samples = try reader.read(
                startFrame: window.start,
                frameCount: Int(window.end - window.start)
            )
            let offsetMs = Int(Double(window.start) / reader.sampleRate * 1000)

            onProgress(PipelineProgress(stage: .transcribing, fraction: windowBase))
            let (segments, language_) = try await transcriber.transcribe(
                samples: samples,
                language: language ?? detectedLanguage,
                offsetMs: offsetMs
            )
            if detectedLanguage == nil { detectedLanguage = language_ }
            allSegments.append(contentsOf: segments)

            if wholeFileDiarizer == nil, let diarizer {
                try Task.checkCancellation()
                onProgress(PipelineProgress(
                    stage: .diarizing,
                    fraction: windowBase + windowShare * 0.8
                ))
                let spans = try diarizer.diarize(samples: samples, offsetMs: offsetMs)
                allSpans.append(contentsOf: spans)
            }
        }

        // Etapa 2b — diarização global VBx sobre o arquivo inteiro (0,70 → 0,92)
        if let wholeFileDiarizer {
            try Task.checkCancellation()
            onProgress(PipelineProgress(stage: .diarizing, fraction: 0.70))
            allSpans = try await wholeFileDiarizer.diarize(fileURL: workingWavURL) { fraction in
                onProgress(PipelineProgress(
                    stage: .diarizing,
                    fraction: 0.70 + 0.22 * min(fraction, 1)
                ))
            }
        }

        // Etapa 3 — alinhamento (0,92 → 1)
        try Task.checkCancellation()
        onProgress(PipelineProgress(stage: .aligning, fraction: 0.92))
        allSegments.sort { $0.startMs < $1.startMs }
        allSpans.sort { $0.startMs < $1.startMs }
        let turns = Aligner.align(transcription: allSegments, diarization: allSpans)

        let result = buildResult(
            recordingId: recordingId,
            turns: turns,
            duration: duration,
            detectedLanguage: detectedLanguage
        )
        onProgress(PipelineProgress(stage: .aligning, fraction: 1))
        return result
    }

    // MARK: - Janelas

    struct Window {
        var start: Int64
        var end: Int64
    }

    private func makeWindows(reader: WavWindowReader) throws -> [Window] {
        let windowFrames = Int64(windowSeconds * reader.sampleRate)
        guard reader.totalFrames > windowFrames else {
            return [Window(start: 0, end: reader.totalFrames)]
        }
        var windows: [Window] = []
        var cursor: Int64 = 0
        while cursor < reader.totalFrames {
            let target = cursor + windowFrames
            if target >= reader.totalFrames {
                windows.append(Window(start: cursor, end: reader.totalFrames))
                break
            }
            // Corta no ponto mais silencioso perto do alvo (evita cortar palavra).
            let cut = try reader.quietestFrame(near: target)
            let end = max(cut, cursor + windowFrames / 2)  // nunca regride demais
            windows.append(Window(start: cursor, end: end))
            cursor = end
        }
        return windows
    }

    // MARK: - Montagem do resultado

    private func buildResult(
        recordingId: Int64,
        turns: [AlignedTurn],
        duration: Double,
        detectedLanguage: String?
    ) -> Result {
        // Falantes na ordem da primeira fala: SPEAKER_00, SPEAKER_01…
        var labelByKey: [String: String] = [:]
        var speakers: [Speaker] = []
        for turn in turns {
            guard let key = turn.speakerKey, labelByKey[key] == nil else { continue }
            let index = speakers.count
            let label = Speaker.labelForIndex(index)
            labelByKey[key] = label
            speakers.append(Speaker(
                recordingId: recordingId,
                label: label,
                colorIndex: index % 8
            ))
        }

        let segments = turns.map { turn in
            (
                speakerLabel: turn.speakerKey.flatMap { labelByKey[$0] },
                segment: Segment(
                    recordingId: recordingId,
                    speakerId: nil,  // resolvido na persistência via label
                    startMs: turn.startMs,
                    endMs: turn.endMs,
                    text: turn.text,
                    confidence: turn.confidence,
                    isOverlap: turn.isOverlap
                )
            )
        }

        return Result(
            speakers: speakers,
            segments: segments,
            duration: duration,
            detectedLanguage: detectedLanguage
        )
    }
}
