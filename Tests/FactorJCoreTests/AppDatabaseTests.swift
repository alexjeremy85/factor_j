import Foundation
import Testing

@testable import FactorJCore

@Suite struct AppDatabaseTests {
    private let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func makeRecording() throws -> Recording {
        try db.createRecording(Recording(
            title: "Teste",
            audioPath: "Audio/teste.m4a",
            status: .queued
        ))
    }

    @Test func createAndFetchRecording() throws {
        let recording = try makeRecording()
        let id = try #require(recording.id)
        let fetched = try #require(try db.fetchRecording(id: id))
        #expect(fetched.title == "Teste")
        #expect(fetched.status == .queued)
        #expect(fetched.diarize)
    }

    @Test func replaceResultsLinksSpeakersAndSegments() throws {
        let recording = try makeRecording()
        let id = try #require(recording.id)

        try db.replaceResults(
            recordingId: id,
            speakers: [
                Speaker(recordingId: id, label: "SPEAKER_00", colorIndex: 0),
                Speaker(recordingId: id, label: "SPEAKER_01", colorIndex: 1),
            ],
            segments: [
                ("SPEAKER_00", Segment(recordingId: id, startMs: 0, endMs: 1000, text: "oi")),
                ("SPEAKER_01", Segment(recordingId: id, startMs: 1000, endMs: 2000, text: "olá")),
                (nil, Segment(recordingId: id, startMs: 2000, endMs: 3000, text: "ruído")),
            ],
            duration: 3.0,
            detectedLanguage: "pt",
            modelUsed: "turbo"
        )

        let updated = try #require(try db.fetchRecording(id: id))
        #expect(updated.status == .done)
        #expect(updated.duration == 3.0)
        #expect(updated.language == "pt")

        let speakers = try db.speakers(recordingId: id)
        let segments = try db.segments(recordingId: id)
        #expect(speakers.count == 2)
        #expect(segments.count == 3)
        #expect(segments[0].speakerId == speakers[0].id)
        #expect(segments[1].speakerId == speakers[1].id)
        #expect(segments[2].speakerId == nil)
    }

    @Test func fullTextSearchFindsSnippetAndSurvivesEdit() throws {
        let recording = try makeRecording()
        let id = try #require(recording.id)
        try db.replaceResults(
            recordingId: id,
            speakers: [Speaker(recordingId: id, label: "SPEAKER_00", colorIndex: 0)],
            segments: [
                ("SPEAKER_00", Segment(recordingId: id, startMs: 0, endMs: 1000,
                                       text: "hoje falamos sobre orçamento anual")),
                ("SPEAKER_00", Segment(recordingId: id, startMs: 1000, endMs: 2000,
                                       text: "outro assunto qualquer")),
            ],
            duration: 2,
            detectedLanguage: "pt",
            modelUsed: nil
        )

        let hits = try db.searchSegments("orçamento")
        #expect(hits.count == 1)
        #expect(hits.first?.recordingId == id)
        #expect(hits.first?.startMs == 0)
        #expect(hits.first?.snippet.contains("«orçamento»") == true)

        // Edição mantém o índice FTS sincronizado.
        let segmentId = try #require(try db.segments(recordingId: id).first?.id)
        try db.updateSegmentText(id: segmentId, text: "agora fala de cronograma")
        #expect(try db.searchSegments("orçamento").isEmpty)
        #expect(try db.searchSegments("cronograma").count == 1)
    }

    @Test func mergeSpeakersMovesSegments() throws {
        let recording = try makeRecording()
        let id = try #require(recording.id)
        try db.replaceResults(
            recordingId: id,
            speakers: [
                Speaker(recordingId: id, label: "SPEAKER_00", colorIndex: 0),
                Speaker(recordingId: id, label: "SPEAKER_01", colorIndex: 1),
            ],
            segments: [
                ("SPEAKER_00", Segment(recordingId: id, startMs: 0, endMs: 1000, text: "a")),
                ("SPEAKER_01", Segment(recordingId: id, startMs: 1000, endMs: 2000, text: "b")),
            ],
            duration: 2,
            detectedLanguage: nil,
            modelUsed: nil
        )
        let speakers = try db.speakers(recordingId: id)
        let source = try #require(speakers[1].id)
        let target = try #require(speakers[0].id)

        try db.mergeSpeaker(source: source, into: target)

        #expect(try db.speakers(recordingId: id).count == 1)
        #expect(try db.segments(recordingId: id).allSatisfy { $0.speakerId == target })
    }

    @Test func deleteRecordingCascades() throws {
        let recording = try makeRecording()
        let id = try #require(recording.id)
        try db.replaceResults(
            recordingId: id,
            speakers: [Speaker(recordingId: id, label: "SPEAKER_00", colorIndex: 0)],
            segments: [("SPEAKER_00", Segment(recordingId: id, startMs: 0, endMs: 1, text: "x"))],
            duration: 1,
            detectedLanguage: nil,
            modelUsed: nil
        )

        try db.deleteRecording(id: id)

        #expect(try db.fetchRecording(id: id) == nil)
        #expect(try db.speakers(recordingId: id).isEmpty)
        #expect(try db.segments(recordingId: id).isEmpty)
        #expect(try db.searchSegments("x").isEmpty)
    }

    @Test func failStaleProcessing() throws {
        let recording = try makeRecording()
        let id = try #require(recording.id)
        try db.setStatus(recordingId: id, status: .processing)

        try db.failStaleProcessing()

        let updated = try #require(try db.fetchRecording(id: id))
        #expect(updated.status == .failed)
        #expect(updated.errorMessage != nil)
    }

    @Test func nextQueuedRespectsInsertionOrder() throws {
        let first = try makeRecording()
        _ = try db.createRecording(Recording(
            title: "Segundo",
            createdAt: Date().addingTimeInterval(10),
            audioPath: "Audio/2.m4a"
        ))

        let next = try #require(try db.nextQueuedRecording())
        #expect(next.id == first.id)
    }

    @Test func renameRecordingTrimsAndIgnoresBlank() throws {
        let recording = try makeRecording()
        let id = try #require(recording.id)

        try db.renameRecording(id: id, title: "  Reunião de quarta  ")
        #expect(try db.fetchRecording(id: id)?.title == "Reunião de quarta")

        // Título em branco é ignorado — mantém o anterior.
        try db.renameRecording(id: id, title: "   ")
        #expect(try db.fetchRecording(id: id)?.title == "Reunião de quarta")
    }

    @Test func requeueWithOptionsReplacesSettingsAndClearsError() throws {
        let recording = try makeRecording()
        let id = try #require(recording.id)
        try db.setStatus(recordingId: id, status: .failed, errorMessage: "idioma errado")

        try db.requeueWithOptions(
            recordingId: id,
            language: "pt",
            diarize: true,
            speakersHint: 4,
            clusteringSensitivity: "high"
        )

        let updated = try #require(try db.fetchRecording(id: id))
        #expect(updated.status == .queued)
        #expect(updated.errorMessage == nil)
        #expect(updated.language == "pt")
        #expect(updated.speakersHint == 4)
        #expect(updated.voiceSensitivity == .high)

        // Voltar para auto limpa os campos.
        try db.requeueWithOptions(
            recordingId: id,
            language: nil,
            diarize: false,
            speakersHint: nil,
            clusteringSensitivity: nil
        )
        let again = try #require(try db.fetchRecording(id: id))
        #expect(again.language == nil)
        #expect(again.diarize == false)
        #expect(again.speakersHint == nil)
        #expect(again.voiceSensitivity == .normal)
    }

    @Test func renameSpeakerTrimsAndNils() throws {
        let recording = try makeRecording()
        let id = try #require(recording.id)
        let speaker = try db.addSpeaker(recordingId: id, displayName: "X")
        let speakerId = try #require(speaker.id)

        try db.renameSpeaker(id: speakerId, displayName: "  Fulano  ")
        #expect(try db.speakers(recordingId: id).first?.displayName == "Fulano")

        try db.renameSpeaker(id: speakerId, displayName: "   ")
        #expect(try db.speakers(recordingId: id).first?.displayName == nil)
    }
}
