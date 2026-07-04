import Combine
import FactorJCore
import Foundation
import GRDB

/// Observa gravação + falantes + segmentos de uma gravação no banco.
/// Toda edição (renomear, reatribuir, mesclar…) reflete aqui automaticamente.
@MainActor
final class RecordingDetailModel: ObservableObject {
    @Published private(set) var recording: Recording?
    @Published private(set) var speakers: [Speaker] = []
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var markers: [Marker] = []

    let recordingId: Int64
    private let database: AppDatabase
    private var cancellable: AnyCancellable?

    init(database: AppDatabase, recordingId: Int64) {
        self.database = database
        self.recordingId = recordingId

        let observation = ValueObservation.tracking { db -> (Recording?, [Speaker], [Segment], [Marker]) in
            let recording = try Recording.fetchOne(db, key: recordingId)
            let speakers = try Speaker
                .filter(Column("recordingId") == recordingId)
                .order(Column("label").asc)
                .fetchAll(db)
            let segments = try Segment
                .filter(Column("recordingId") == recordingId)
                .order(Column("startMs").asc)
                .fetchAll(db)
            let markers = try Marker
                .filter(Column("recordingId") == recordingId)
                .order(Column("timestampMs").asc)
                .fetchAll(db)
            return (recording, speakers, segments, markers)
        }
        cancellable = observation
            .publisher(in: database.writer, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] recording, speakers, segments, markers in
                    self?.recording = recording
                    self?.speakers = speakers
                    self?.segments = segments
                    self?.markers = markers
                }
            )
    }

    var speakersById: [Int64: Speaker] {
        Dictionary(uniqueKeysWithValues: speakers.compactMap { speaker in
            speaker.id.map { ($0, speaker) }
        })
    }

    // MARK: - Edições

    func renameSpeaker(_ speaker: Speaker, to name: String) {
        guard let id = speaker.id else { return }
        try? database.renameSpeaker(id: id, displayName: name)
    }

    func mergeSpeaker(_ source: Speaker, into target: Speaker) {
        guard let sourceId = source.id, let targetId = target.id else { return }
        try? database.mergeSpeaker(source: sourceId, into: targetId)
    }

    func reassign(_ segment: Segment, to speaker: Speaker?) {
        guard let segmentId = segment.id else { return }
        try? database.reassignSegment(id: segmentId, to: speaker?.id)
    }

    func reassignToNewSpeaker(_ segment: Segment, name: String) {
        guard let segmentId = segment.id else { return }
        if let speaker = try? database.addSpeaker(recordingId: recordingId, displayName: name) {
            try? database.reassignSegment(id: segmentId, to: speaker.id)
        }
    }

    func updateText(_ segment: Segment, text: String) {
        guard let segmentId = segment.id else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != segment.text else { return }
        try? database.updateSegmentText(id: segmentId, text: trimmed)
    }
}
