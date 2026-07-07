import Foundation
import GRDB

/// Acesso central ao banco SQLite do FactorJ (metadados, transcrições, busca FTS5).
public final class AppDatabase {
    public let writer: any DatabaseWriter

    public var reader: any DatabaseReader { writer }

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    /// Abre (ou cria) o banco no caminho dado.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        return try AppDatabase(queue)
    }

    /// Banco em memória (testes).
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "recording") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("sourceType", .text).notNull()
                t.column("audioPath", .text).notNull()
                t.column("status", .text).notNull()
                t.column("language", .text)
                t.column("notes", .text)
                t.column("diarize", .boolean).notNull().defaults(to: true)
                t.column("speakersHint", .integer)
                t.column("errorMessage", .text)
                t.column("modelUsed", .text)
            }

            try db.create(table: "speaker") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("recording", onDelete: .cascade).notNull()
                t.column("label", .text).notNull()
                t.column("displayName", .text)
                t.column("colorIndex", .integer).notNull().defaults(to: 0)
                t.column("embeddingRef", .text)
            }

            try db.create(table: "segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("recording", onDelete: .cascade).notNull()
                t.column("speakerId", .integer)
                    .references("speaker", onDelete: .setNull)
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("confidence", .double)
                t.column("isOverlap", .boolean).notNull().defaults(to: false)
                t.column("isProvisional", .boolean).notNull().defaults(to: false)
                t.column("isEdited", .boolean).notNull().defaults(to: false)
            }
            try db.create(
                index: "segment_on_recording_start",
                on: "segment",
                columns: ["recordingId", "startMs"]
            )

            try db.create(table: "marker") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("recording", onDelete: .cascade).notNull()
                t.column("timestampMs", .integer).notNull()
                t.column("note", .text)
            }

            // Busca full-text sincronizada com a tabela segment (RF-D3).
            try db.create(virtualTable: "segment_ft", using: FTS5()) { t in
                t.synchronize(withTable: "segment")
                t.column("text")
            }
        }

        migrator.registerMigration("v2-voice-sensitivity") { db in
            try db.alter(table: "recording") { t in
                t.add(column: "clusteringSensitivity", .text)
            }
        }

        return migrator
    }

    // MARK: - Recording CRUD

    @discardableResult
    public func createRecording(_ recording: Recording) throws -> Recording {
        try writer.write { db in
            var r = recording
            try r.insert(db)
            return r
        }
    }

    public func fetchRecording(id: Int64) throws -> Recording? {
        try reader.read { db in try Recording.fetchOne(db, key: id) }
    }

    public func allRecordings() throws -> [Recording] {
        try reader.read { db in
            try Recording.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    public func updateRecording(_ recording: Recording) throws {
        try writer.write { db in try recording.update(db) }
    }

    public func setStatus(
        recordingId: Int64,
        status: RecordingStatus,
        errorMessage: String? = nil
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE recording SET status = ?, errorMessage = ? WHERE id = ?",
                arguments: [status.rawValue, errorMessage, recordingId]
            )
        }
    }

    /// Próxima gravação na fila de processamento (ordem de chegada).
    public func nextQueuedRecording() throws -> Recording? {
        try reader.read { db in
            try Recording
                .filter(Column("status") == RecordingStatus.queued.rawValue)
                .order(Column("createdAt").asc, Column("id").asc)
                .fetchOne(db)
        }
    }

    /// Marca como `failed` gravações que ficaram penduradas em `processing`
    /// (ex.: app morto no meio do processamento — critério de aceite nº 5).
    public func failStaleProcessing() throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE recording SET status = ?, errorMessage = ?
                    WHERE status IN (?, ?)
                    """,
                arguments: [
                    RecordingStatus.failed.rawValue,
                    "Processamento interrompido inesperadamente. Tente reprocessar.",
                    RecordingStatus.processing.rawValue,
                    RecordingStatus.consolidating.rawValue,
                ]
            )
        }
    }

    public func deleteRecording(id: Int64) throws {
        _ = try writer.write { db in
            try Recording.deleteOne(db, key: id)
        }
    }

    // MARK: - Resultados do pipeline

    /// Substitui atomicamente falantes e segmentos de uma gravação pelo
    /// resultado final do pipeline, atualizando os metadados da gravação.
    public func replaceResults(
        recordingId: Int64,
        speakers: [Speaker],
        segments: [(speakerLabel: String?, segment: Segment)],
        duration: Double,
        detectedLanguage: String?,
        modelUsed: String?
    ) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM segment WHERE recordingId = ?", arguments: [recordingId])
            try db.execute(sql: "DELETE FROM speaker WHERE recordingId = ?", arguments: [recordingId])

            var idByLabel: [String: Int64] = [:]
            for speaker in speakers {
                var s = speaker
                s.recordingId = recordingId
                try s.insert(db)
                if let id = s.id { idByLabel[s.label] = id }
            }

            for (label, segment) in segments {
                var seg = segment
                seg.recordingId = recordingId
                seg.speakerId = label.flatMap { idByLabel[$0] }
                try seg.insert(db)
            }

            try db.execute(
                sql: """
                    UPDATE recording
                    SET status = ?, duration = ?, language = COALESCE(?, language),
                        errorMessage = NULL, modelUsed = ?
                    WHERE id = ?
                    """,
                arguments: [
                    RecordingStatus.done.rawValue, duration, detectedLanguage,
                    modelUsed, recordingId,
                ]
            )
        }
    }

    // MARK: - Detalhe (falantes + segmentos)

    public func speakers(recordingId: Int64) throws -> [Speaker] {
        try reader.read { db in
            try Speaker
                .filter(Column("recordingId") == recordingId)
                .order(Column("label").asc)
                .fetchAll(db)
        }
    }

    public func segments(recordingId: Int64) throws -> [Segment] {
        try reader.read { db in
            try Segment
                .filter(Column("recordingId") == recordingId)
                .order(Column("startMs").asc)
                .fetchAll(db)
        }
    }

    public func markers(recordingId: Int64) throws -> [Marker] {
        try reader.read { db in
            try Marker
                .filter(Column("recordingId") == recordingId)
                .order(Column("timestampMs").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Edições do usuário

    public func renameSpeaker(id: Int64, displayName: String?) throws {
        try writer.write { db in
            let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            try db.execute(
                sql: "UPDATE speaker SET displayName = ? WHERE id = ?",
                arguments: [(name?.isEmpty == true) ? nil : name, id]
            )
        }
    }

    /// Renomeia a gravação. Título em branco é ignorado (mantém o anterior),
    /// pois `title` é obrigatório e aparece na barra lateral.
    public func renameRecording(id: Int64, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try writer.write { db in
            try db.execute(
                sql: "UPDATE recording SET title = ? WHERE id = ?",
                arguments: [trimmed, id]
            )
        }
    }

    /// Une o falante `source` ao falante `target` (RF: mesclar falantes).
    public func mergeSpeaker(source: Int64, into target: Int64) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE segment SET speakerId = ? WHERE speakerId = ?",
                arguments: [target, source]
            )
            try db.execute(sql: "DELETE FROM speaker WHERE id = ?", arguments: [source])
        }
    }

    public func reassignSegment(id: Int64, to speakerId: Int64?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE segment SET speakerId = ? WHERE id = ?",
                arguments: [speakerId, id]
            )
        }
    }

    public func updateSegmentText(id: Int64, text: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE segment SET text = ?, isEdited = 1 WHERE id = ?",
                arguments: [text, id]
            )
        }
    }

    /// Recoloca uma gravação na fila com novas opções de processamento
    /// (reprocessamento manual — o áudio original é preservado).
    public func requeueWithOptions(
        recordingId: Int64,
        language: String?,
        diarize: Bool,
        speakersHint: Int?,
        clusteringSensitivity: String?
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE recording
                    SET status = ?, errorMessage = NULL, language = ?,
                        diarize = ?, speakersHint = ?, clusteringSensitivity = ?
                    WHERE id = ?
                    """,
                arguments: [
                    RecordingStatus.queued.rawValue, language,
                    diarize, speakersHint, clusteringSensitivity, recordingId,
                ]
            )
        }
    }

    /// Cria um novo falante manualmente (usado em "Atribuir a… > Novo falante").
    @discardableResult
    public func addSpeaker(recordingId: Int64, displayName: String) throws -> Speaker {
        try writer.write { db in
            let count = try Speaker
                .filter(Column("recordingId") == recordingId)
                .fetchCount(db)
            var speaker = Speaker(
                recordingId: recordingId,
                label: Speaker.labelForIndex(count),
                displayName: displayName,
                colorIndex: count % 8
            )
            try speaker.insert(db)
            return speaker
        }
    }

    // MARK: - Busca full-text (RF-D3)

    public struct SearchHit: Identifiable, Equatable {
        public var id: Int64 { segmentId }
        public let segmentId: Int64
        public let recordingId: Int64
        public let recordingTitle: String
        public let startMs: Int
        public let snippet: String
    }

    public func searchSegments(_ query: String, limit: Int = 200) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed)
        else { return [] }

        return try reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT segment.id AS segmentId,
                           segment.recordingId AS recordingId,
                           recording.title AS recordingTitle,
                           segment.startMs AS startMs,
                           snippet(segment_ft, 0, '«', '»', '…', 12) AS snippet
                    FROM segment
                    JOIN segment_ft ON segment_ft.rowid = segment.id
                    JOIN recording ON recording.id = segment.recordingId
                    WHERE segment_ft MATCH ?
                    ORDER BY recording.createdAt DESC, segment.startMs ASC
                    LIMIT ?
                    """,
                arguments: [pattern, limit]
            )
            return rows.map { row in
                SearchHit(
                    segmentId: row["segmentId"],
                    recordingId: row["recordingId"],
                    recordingTitle: row["recordingTitle"],
                    startMs: row["startMs"],
                    snippet: row["snippet"]
                )
            }
        }
    }
}
