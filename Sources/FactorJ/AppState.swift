import Combine
import FactorJCore
import Foundation
import GRDB

/// Opções escolhidas na importação (§4.1).
struct ImportOptions {
    /// nil = auto-detect.
    var language: String?
    var diarize: Bool = true
    /// nil = automático.
    var speakersHint: Int?
}

/// Navegação pós-busca: abrir gravação e pular para o timestamp.
struct PendingSeek: Equatable {
    var recordingId: Int64
    var ms: Int
    var segmentId: Int64?
}

/// Estado global do app: banco, fila de processamento, seleção e busca.
@MainActor
final class AppState: ObservableObject {
    let dataStore: DataStore
    let database: AppDatabase
    let modelStore: ModelStore
    let processing: ProcessingCenter
    let recorder = RecorderController()
    private let hotKeyManager = HotKeyManager()

    @Published var recordings: [Recording] = []
    @Published var selectedRecordingId: Int64?
    @Published var searchText = ""
    @Published var searchHits: [AppDatabase.SearchHit] = []
    @Published var modelAvailability = ModelAvailability(
        whisperTurbo: false, whisperBase: false, diarization: false
    )
    @Published var pendingSeek: PendingSeek?
    @Published var bootError: String?
    @Published var lastError: String?

    // Assistente de instalação de modelos (primeiro uso)
    @Published var showSetupAssistant = false

    // Fluxo de importação
    @Published var showFileImporter = false
    @Published var pendingImportURLs: [URL] = []
    @Published var showImportOptions = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        let store = DataStore()
        var database: AppDatabase
        var bootError: String?
        do {
            try store.ensureDirectories()
            database = try AppDatabase.open(at: store.databaseURL)
        } catch {
            bootError = "Falha ao abrir o banco de dados: \(error.localizedDescription)"
            // Fallback em memória para o app ao menos abrir e mostrar o erro.
            database = (try? AppDatabase.inMemory()) ?? (try! AppDatabase.inMemory())
        }

        self.dataStore = store
        self.database = database
        self.modelStore = ModelStore(modelsDirectory: store.modelsDirectory)
        self.processing = ProcessingCenter(
            database: database,
            dataStore: store,
            modelStore: modelStore
        )
        self.bootError = bootError

        // Itens que ficaram "processing" após um crash viram failed (aceite nº 5).
        try? database.failStaleProcessing()

        startObservingRecordings()
        refreshModelAvailability()

        // Primeiro uso: oferece a instalação dos modelos automaticamente.
        if bootError == nil,
           !modelAvailability.anyWhisper || !modelAvailability.diarization {
            showSetupAssistant = true
        }

        UserDefaults.standard.register(defaults: [
            "factorj.menuBarEnabled": true,
            "factorj.hotkeyEnabled": true,
        ])
        recorder.attach(appState: self)
        refreshHotkey()

        // Recupera gravações ao vivo interrompidas por crash (RF-G4) e
        // retoma a fila; senão, warm-up dos modelos (§3).
        Task.detached(priority: .utility) { [dataStore, database] in
            RecordingSession.recoverInterruptedSessions(
                dataStore: dataStore,
                database: database
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if (try? self.database.nextQueuedRecording()) ?? nil != nil {
                    self.processing.kick()
                } else {
                    Task { await self.processing.preloadEngines() }
                }
            }
        }

        // Busca full-text com debounce.
        $searchText
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] text in
                guard let self else { return }
                self.searchHits = (try? self.database.searchSegments(text)) ?? []
            }
            .store(in: &cancellables)
    }

    private func startObservingRecordings() {
        let observation = ValueObservation.tracking { db in
            try Recording.order(Column("createdAt").desc).fetchAll(db)
        }
        observation
            .publisher(in: database.writer, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] recordings in
                    self?.recordings = recordings
                }
            )
            .store(in: &cancellables)
    }

    func refreshModelAvailability() {
        modelAvailability = modelStore.availability()
    }

    /// (Re)registra o atalho global conforme os Ajustes.
    func refreshHotkey() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "factorj.hotkeyEnabled") else {
            hotKeyManager.unregister()
            return
        }
        let preset = HotKeyManager.preset(
            id: defaults.string(forKey: "factorj.hotkeyPreset") ?? "opt-cmd-r"
        )
        hotKeyManager.register(preset: preset) { [weak self] in
            self?.recorder.toggleFromShortcut()
        }
    }

    // MARK: - Importação

    /// Recebe URLs (file importer ou drag-and-drop) e abre a folha de opções.
    func requestImport(urls: [URL]) {
        let supported = urls.filter {
            AudioConverter.supportedExtensions.contains($0.pathExtension.lowercased())
        }
        guard !supported.isEmpty else {
            lastError = "Nenhum dos arquivos tem formato de áudio/vídeo suportado."
            return
        }
        pendingImportURLs = supported
        showImportOptions = true
    }

    func confirmImport(options: ImportOptions) {
        defer {
            pendingImportURLs = []
            showImportOptions = false
        }
        var lastId: Int64?
        for url in pendingImportURLs {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let audioPath = try dataStore.importAudioFile(from: url)
                let recording = try database.createRecording(Recording(
                    title: url.deletingPathExtension().lastPathComponent,
                    sourceType: .file,
                    audioPath: audioPath,
                    status: .queued,
                    language: options.language,
                    diarize: options.diarize,
                    speakersHint: options.speakersHint
                ))
                lastId = recording.id
            } catch {
                lastError = "Falha ao importar \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if let lastId {
            selectedRecordingId = lastId
            processing.kick()
        }
    }

    // MARK: - Ações

    func deleteRecording(_ recording: Recording) {
        guard let id = recording.id else { return }
        processing.cancel(recordingId: id)
        dataStore.removeAudioFile(relativePath: recording.audioPath)
        do {
            try database.deleteRecording(id: id)
        } catch {
            lastError = "Falha ao excluir: \(error.localizedDescription)"
        }
        if selectedRecordingId == id { selectedRecordingId = nil }
    }

    func openSearchHit(_ hit: AppDatabase.SearchHit) {
        selectedRecordingId = hit.recordingId
        pendingSeek = PendingSeek(
            recordingId: hit.recordingId,
            ms: hit.startMs,
            segmentId: hit.segmentId
        )
        searchText = ""
    }
}
