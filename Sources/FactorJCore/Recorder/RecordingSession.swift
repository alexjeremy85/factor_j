import Foundation
import GRDB

/// Fontes de captura da gravação ao vivo (§5.1).
public struct RecordingSources: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let microphone = RecordingSources(rawValue: 1 << 0)
    public static let system = RecordingSources(rawValue: 1 << 1)
    public static let both: RecordingSources = [.microphone, .system]
}

/// Uma sessão de gravação ao vivo: grava as fontes em arquivos separados
/// dentro de uma pasta de sessão (à prova de crash — RF-G4: o áudio vai
/// para o disco incrementalmente), e ao encerrar combina tudo no arquivo
/// final da gravação e a enfileira para transcrição.
public final class RecordingSession {
    public let recordingId: Int64
    public let sources: RecordingSources
    public private(set) var startedAt = Date()

    private let dataStore: DataStore
    private let database: AppDatabase
    private var mic: MicRecorder?
    private var tap: SystemAudioTap?

    /// Tempo acumulado (exclui pausas).
    private var accumulated: TimeInterval = 0
    private var resumedAt: Date?

    public var elapsed: TimeInterval {
        accumulated + (resumedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    public var isPaused: Bool { resumedAt == nil }

    // MARK: - Layout da sessão em disco

    static func sessionDirectory(dataStore: DataStore, recordingId: Int64) -> URL {
        dataStore.tempDirectory.appendingPathComponent("live_rec_\(recordingId)", isDirectory: true)
    }

    var sessionDirectory: URL {
        Self.sessionDirectory(dataStore: dataStore, recordingId: recordingId)
    }

    var micFileURL: URL { sessionDirectory.appendingPathComponent("mic.caf") }
    var systemFileURL: URL { sessionDirectory.appendingPathComponent("system.caf") }

    // MARK: - Ciclo de vida

    public init(
        recordingId: Int64,
        sources: RecordingSources,
        dataStore: DataStore,
        database: AppDatabase,
        onMicLevel: @escaping (Float) -> Void,
        onSystemLevel: @escaping (Float) -> Void
    ) {
        self.recordingId = recordingId
        self.sources = sources
        self.dataStore = dataStore
        self.database = database
        if sources.contains(.microphone) {
            mic = MicRecorder(onLevel: onMicLevel)
        }
        if sources.contains(.system) {
            tap = SystemAudioTap(onLevel: onSystemLevel)
        }
    }

    /// Inicia a captura. Lança erro de permissão/hardware (RF-G5).
    public func start() throws {
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        // Sistema primeiro: é quem pode falhar por permissão.
        if let tap {
            try tap.start(writingTo: systemFileURL)
        }
        do {
            try mic?.start(writingTo: micFileURL)
        } catch {
            tap?.stop()
            throw error
        }
        startedAt = Date()
        resumedAt = Date()
        accumulated = 0
    }

    public func pause() {
        guard let resumedAt else { return }
        accumulated += Date().timeIntervalSince(resumedAt)
        self.resumedAt = nil
        mic?.isPaused = true
        tap?.isPaused = true
    }

    public func resume() {
        guard resumedAt == nil else { return }
        resumedAt = Date()
        mic?.isPaused = false
        tap?.isPaused = false
    }

    /// "Marcar momento": flag manual com timestamp (§5.1).
    public func addMarker(note: String? = nil) throws {
        _ = try database.writer.write { [recordingId, elapsed] db in
            var marker = Marker(
                recordingId: recordingId,
                timestampMs: Int(elapsed * 1000),
                note: note
            )
            try marker.insert(db)
            return marker
        }
    }

    /// Encerra a captura, combina as fontes (mic = L, sistema = R) no
    /// arquivo final e enfileira a transcrição.
    public func stop() throws {
        pause()
        mic?.stop()
        tap?.stop()
        try Self.finalize(
            recordingId: recordingId,
            sessionDirectory: sessionDirectory,
            dataStore: dataStore,
            database: database
        )
    }

    /// Descarta a sessão sem transcrever (gravação cancelada).
    public func discard() {
        mic?.stop()
        tap?.stop()
        try? FileManager.default.removeItem(at: sessionDirectory)
        try? database.deleteRecording(id: recordingId)
    }

    // MARK: - Finalização e recuperação pós-crash

    /// Combina os arquivos da sessão no áudio final da gravação e marca
    /// como `queued`. Usada no fluxo normal e na recuperação pós-crash.
    static func finalize(
        recordingId: Int64,
        sessionDirectory: URL,
        dataStore: DataStore,
        database: AppDatabase
    ) throws {
        let fm = FileManager.default
        let micURL = sessionDirectory.appendingPathComponent("mic.caf")
        let systemURL = sessionDirectory.appendingPathComponent("system.caf")
        let micExists = fm.fileExists(atPath: micURL.path)
        let systemExists = fm.fileExists(atPath: systemURL.path)

        guard micExists || systemExists else {
            try database.setStatus(
                recordingId: recordingId,
                status: .failed,
                errorMessage: "A gravação não produziu áudio."
            )
            try? fm.removeItem(at: sessionDirectory)
            return
        }

        try dataStore.ensureDirectories()
        let audioName = "Audio/rec_\(recordingId)_\(UUID().uuidString).caf"
        let outputURL = dataStore.absoluteURL(for: audioName)
        try AudioFileMerger.merge(
            micURL: micExists ? micURL : nil,
            systemURL: systemExists ? systemURL : nil,
            output: outputURL
        )

        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE recording SET audioPath = ?, status = ?, errorMessage = NULL WHERE id = ?",
                arguments: [audioName, RecordingStatus.queued.rawValue, recordingId]
            )
        }
        try? fm.removeItem(at: sessionDirectory)
    }

    /// Recupera sessões interrompidas por crash/queda de energia: qualquer
    /// gravação `live` no banco tem seus arquivos de sessão combinados e
    /// volta como `queued` (critério de aceite nº 5 — perde no máximo os
    /// últimos segundos não descarregados).
    public static func recoverInterruptedSessions(
        dataStore: DataStore,
        database: AppDatabase
    ) {
        guard let liveRecordings = try? database.reader.read({ db in
            try Recording
                .filter(Column("status") == RecordingStatus.live.rawValue)
                .fetchAll(db)
        }) else { return }

        for recording in liveRecordings {
            guard let id = recording.id else { continue }
            let dir = sessionDirectory(dataStore: dataStore, recordingId: id)
            try? finalize(
                recordingId: id,
                sessionDirectory: dir,
                dataStore: dataStore,
                database: database
            )
        }
    }
}
