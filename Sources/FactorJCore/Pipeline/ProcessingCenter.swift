import Foundation

/// Fila de processamento (RF-A3/RF-A4): processa gravações `queued` em
/// sequência, publica progresso para a UI e permite cancelar sem corromper
/// o banco.
@MainActor
public final class ProcessingCenter: ObservableObject {
    @Published public private(set) var progressByRecording: [Int64: PipelineProgress] = [:]
    @Published public private(set) var currentRecordingId: Int64?

    public let database: AppDatabase
    public let dataStore: DataStore
    public let modelStore: ModelStore

    private var workerTask: Task<Void, Never>?
    private var currentWork: Task<Void, Error>?

    /// Transcritor mantido carregado entre itens da fila (recarregar o
    /// turbo custa vários segundos); liberado quando a fila esvazia.
    private var transcriber: WhisperKitTranscriber?
    private var transcriberQuality: WhisperModelQuality?

    public init(database: AppDatabase, dataStore: DataStore, modelStore: ModelStore) {
        self.database = database
        self.dataStore = dataStore
        self.modelStore = modelStore
    }

    /// Qualidade escolhida em Ajustes (default: turbo).
    public static var selectedQuality: WhisperModelQuality {
        let raw = UserDefaults.standard.string(forKey: "escriba.modelQuality") ?? ""
        return WhisperModelQuality(rawValue: raw) ?? .turbo
    }

    // MARK: - API

    /// Garante que o worker está rodando (chame após enfileirar).
    public func kick() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.workerLoop()
        }
    }

    public func cancel(recordingId: Int64) {
        if currentRecordingId == recordingId {
            currentWork?.cancel()
        } else {
            try? database.setStatus(
                recordingId: recordingId,
                status: .failed,
                errorMessage: "Cancelado pelo usuário."
            )
        }
    }

    public func retry(recordingId: Int64) {
        try? database.setStatus(recordingId: recordingId, status: .queued)
        kick()
    }

    /// Warm-up dos modelos em background ao abrir o app (§3), para a
    /// primeira inferência não travar a UI.
    public func preloadEngines() async {
        let quality = Self.selectedQuality
        guard modelStore.isWhisperAvailable(quality) else { return }
        _ = try? await loadTranscriber(quality: quality)
    }

    // MARK: - Worker

    private func workerLoop() async {
        defer { workerTask = nil }
        while let recording = (try? database.nextQueuedRecording()) ?? nil {
            guard let id = recording.id else { break }
            currentRecordingId = id
            progressByRecording[id] = PipelineProgress(stage: .converting, fraction: 0)

            do {
                try await processOne(recording)
            } catch is CancellationError {
                try? database.setStatus(
                    recordingId: id,
                    status: .failed,
                    errorMessage: "Cancelado pelo usuário."
                )
            } catch {
                try? database.setStatus(
                    recordingId: id,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
            }
            progressByRecording[id] = nil
            currentRecordingId = nil
        }
        // Fila drenada: libera ~2 GB de RAM do modelo.
        transcriber?.unload()
        transcriber = nil
        transcriberQuality = nil
        dataStore.cleanTempDirectory()
    }

    private func processOne(_ recording: Recording) async throws {
        guard let id = recording.id else { return }

        let quality = Self.selectedQuality
        guard modelStore.isWhisperAvailable(quality) else {
            throw PipelineError.modelsMissing("Whisper \(quality.displayName)")
        }
        if recording.diarize, !modelStore.isDiarizationAvailable() {
            throw PipelineError.modelsMissing("diarização (pyannote/wespeaker)")
        }

        try database.setStatus(recordingId: id, status: .processing)

        let transcriber = try await loadTranscriber(quality: quality)
        let diarizer: DiarizationEngine? = recording.diarize
            ? try FluidAudioDiarizer(
                segmentationModel: modelStore.segmentationModelURL,
                embeddingModel: modelStore.embeddingModelURL,
                numSpeakers: recording.speakersHint
            )
            : nil

        let pipeline = ProcessingPipeline(transcriber: transcriber, diarizer: diarizer)
        let sourceURL = dataStore.absoluteURL(for: recording.audioPath)
        let workingWavURL = dataStore.tempWavURL(recordingId: id)
        let language = recording.language

        // Trabalho pesado fora da MainActor; progresso volta para cá.
        let work = Task.detached(priority: .userInitiated) { [database] () throws -> Void in
            let result = try await pipeline.run(
                recordingId: id,
                sourceURL: sourceURL,
                workingWavURL: workingWavURL,
                language: language,
                onProgress: { progress in
                    Task { @MainActor [weak self] in
                        self?.progressByRecording[id] = progress
                    }
                }
            )
            try database.replaceResults(
                recordingId: id,
                speakers: result.speakers,
                segments: result.segments,
                duration: result.duration,
                detectedLanguage: result.detectedLanguage,
                modelUsed: quality.modelFolderName
            )
        }
        currentWork = work
        defer { currentWork = nil }
        try await work.value
    }

    private func loadTranscriber(quality: WhisperModelQuality) async throws -> WhisperKitTranscriber {
        if let transcriber, transcriberQuality == quality {
            return transcriber
        }
        transcriber?.unload()
        let fresh = WhisperKitTranscriber(
            modelFolder: modelStore.whisperModelFolder(quality),
            tokenizerFolder: modelStore.whisperTokenizerFolder(quality)
        )
        try await fresh.load()
        transcriber = fresh
        transcriberQuality = quality
        return fresh
    }
}
