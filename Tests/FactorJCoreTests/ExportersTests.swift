import Foundation
import Testing

@testable import FactorJCore

@Suite struct ExportersTests {
    private let recording: Recording
    private let speakers: [Speaker]
    private var segments: [Segment]

    init() {
        recording = Recording(
            id: 1,
            title: "Reunião de teste",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 125,
            sourceType: .file,
            audioPath: "Audio/x.m4a",
            status: .done,
            language: "pt"
        )
        speakers = [
            Speaker(id: 10, recordingId: 1, label: "SPEAKER_00", displayName: "Fulano", colorIndex: 0),
            Speaker(id: 11, recordingId: 1, label: "SPEAKER_01", displayName: nil, colorIndex: 1),
        ]
        segments = [
            Segment(id: 100, recordingId: 1, speakerId: 10, startMs: 0, endMs: 4230, text: "Bom dia, pessoal."),
            Segment(id: 101, recordingId: 1, speakerId: 11, startMs: 5000, endMs: 8000, text: "Bom dia!"),
        ]
    }

    @Test func txtUsesDisplayNameAndDefaultName() {
        let txt = Exporter.export(format: .txt, recording: recording, speakers: speakers, segments: segments)
        #expect(txt == "Fulano: Bom dia, pessoal.\nFalante 2: Bom dia!\n")
    }

    @Test func srtFormat() {
        let srt = Exporter.export(format: .srt, recording: recording, speakers: speakers, segments: segments)
        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:04,230\n[Fulano] Bom dia, pessoal.\n"))
        #expect(srt.contains("\n2\n00:00:05,000 --> 00:00:08,000\n[Falante 2] Bom dia!"))
    }

    @Test func vttFormat() {
        let vtt = Exporter.export(format: .vtt, recording: recording, speakers: speakers, segments: segments)
        #expect(vtt.hasPrefix("WEBVTT\n\n"))
        #expect(vtt.contains("00:00:00.000 --> 00:00:04.230\n[Fulano] Bom dia, pessoal."))
    }

    @Test func jsonRoundTrips() throws {
        let json = Exporter.export(format: .json, recording: recording, speakers: speakers, segments: segments)
        let data = try #require(json.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let jsonSegments = try #require(object["segments"] as? [[String: Any]])
        #expect(jsonSegments.count == 2)
        #expect(jsonSegments[0]["speaker"] as? String == "Fulano")
        #expect(jsonSegments[0]["startMs"] as? Int == 0)
        #expect(jsonSegments[0]["endMs"] as? Int == 4230)
        let jsonSpeakers = try #require(object["speakers"] as? [[String: Any]])
        #expect(jsonSpeakers.count == 2)
    }

    @Test func markdownContainsHeaderAndParticipants() {
        let md = Exporter.export(format: .markdown, recording: recording, speakers: speakers, segments: segments)
        #expect(md.hasPrefix("# Reunião de teste"))
        #expect(md.contains("**Participantes:** Fulano, Falante 2"))
        #expect(md.contains("**Fulano** [0:00]: Bom dia, pessoal."))
    }

    @Test func unknownSpeakerFallback() {
        var segmentsWithUnknown = segments
        segmentsWithUnknown.append(
            Segment(id: 102, recordingId: 1, speakerId: nil, startMs: 9000, endMs: 9500, text: "…")
        )
        let txt = Exporter.export(
            format: .txt, recording: recording, speakers: speakers, segments: segmentsWithUnknown
        )
        #expect(txt.contains("Falante desconhecido: …"))
    }

    @Test func timeFormats() {
        #expect(TimeFormat.display(ms: 65_000) == "1:05")
        #expect(TimeFormat.display(ms: 3_725_000) == "1:02:05")
        #expect(TimeFormat.srt(ms: 3_725_120) == "01:02:05,120")
        #expect(TimeFormat.vtt(ms: 61_001) == "00:01:01.001")
        #expect(TimeFormat.duration(seconds: 3720) == "1h02min")
        #expect(TimeFormat.duration(seconds: 300) == "5min")
        #expect(TimeFormat.duration(seconds: 32) == "32s")
    }
}
