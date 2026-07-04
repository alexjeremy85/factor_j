import Foundation

/// Formatos de exportação (§7.5).
public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case txt
    case srt
    case vtt
    case json
    case markdown

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        default: return rawValue
        }
    }

    public var displayName: String {
        switch self {
        case .txt: return "Texto (.txt)"
        case .srt: return "Legendas SRT (.srt)"
        case .vtt: return "Legendas WebVTT (.vtt)"
        case .json: return "JSON completo (.json)"
        case .markdown: return "Markdown (.md)"
        }
    }
}

/// Gera o conteúdo das exportações a partir dos dados persistidos.
/// Sempre usa o `displayName` renomeado dos falantes (RF-E1).
public enum Exporter {
    public static func export(
        format: ExportFormat,
        recording: Recording,
        speakers: [Speaker],
        segments: [Segment]
    ) -> String {
        let names = speakerNames(speakers)
        switch format {
        case .txt:
            return txt(segments: segments, names: names)
        case .srt:
            return srt(segments: segments, names: names)
        case .vtt:
            return vtt(segments: segments, names: names)
        case .json:
            return json(recording: recording, speakers: speakers, segments: segments)
        case .markdown:
            return markdown(recording: recording, speakers: speakers, segments: segments, names: names)
        }
    }

    static func speakerNames(_ speakers: [Speaker]) -> [Int64: String] {
        var names: [Int64: String] = [:]
        for speaker in speakers {
            if let id = speaker.id { names[id] = speaker.resolvedName }
        }
        return names
    }

    static func name(for segment: Segment, names: [Int64: String]) -> String {
        segment.speakerId.flatMap { names[$0] } ?? "Falante desconhecido"
    }

    // MARK: - .txt  ("Nome do falante: texto")

    static func txt(segments: [Segment], names: [Int64: String]) -> String {
        segments
            .map { "\(name(for: $0, names: names)): \($0.text)" }
            .joined(separator: "\n")
            + "\n"
    }

    // MARK: - .srt  ("[Nome] texto")

    static func srt(segments: [Segment], names: [Int64: String]) -> String {
        var blocks: [String] = []
        for (index, segment) in segments.enumerated() {
            blocks.append("""
                \(index + 1)
                \(TimeFormat.srt(ms: segment.startMs)) --> \(TimeFormat.srt(ms: segment.endMs))
                [\(name(for: segment, names: names))] \(segment.text)
                """)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - .vtt

    static func vtt(segments: [Segment], names: [Int64: String]) -> String {
        var blocks = ["WEBVTT"]
        for segment in segments {
            blocks.append("""
                \(TimeFormat.vtt(ms: segment.startMs)) --> \(TimeFormat.vtt(ms: segment.endMs))
                [\(name(for: segment, names: names))] \(segment.text)
                """)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - .json

    struct JSONExport: Encodable {
        struct JSONRecording: Encodable {
            var title: String
            var createdAt: String
            var durationSeconds: Double
            var language: String?
            var model: String?
        }
        struct JSONSpeaker: Encodable {
            var id: Int64
            var label: String
            var name: String
        }
        struct JSONSegment: Encodable {
            var speakerId: Int64?
            var speaker: String
            var startMs: Int
            var endMs: Int
            var text: String
            var confidence: Double?
            var isOverlap: Bool
            var isEdited: Bool
        }
        var recording: JSONRecording
        var speakers: [JSONSpeaker]
        var segments: [JSONSegment]
    }

    static func json(recording: Recording, speakers: [Speaker], segments: [Segment]) -> String {
        let names = speakerNames(speakers)
        let iso = ISO8601DateFormatter()
        let payload = JSONExport(
            recording: .init(
                title: recording.title,
                createdAt: iso.string(from: recording.createdAt),
                durationSeconds: recording.duration,
                language: recording.language,
                model: recording.modelUsed
            ),
            speakers: speakers.compactMap { speaker in
                guard let id = speaker.id else { return nil }
                return .init(id: id, label: speaker.label, name: speaker.resolvedName)
            },
            segments: segments.map { segment in
                .init(
                    speakerId: segment.speakerId,
                    speaker: name(for: segment, names: names),
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text,
                    confidence: segment.confidence,
                    isOverlap: segment.isOverlap,
                    isEdited: segment.isEdited
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string + "\n"
    }

    // MARK: - .md  (pronto para Obsidian)

    static func markdown(
        recording: Recording,
        speakers: [Speaker],
        segments: [Segment],
        names: [Int64: String]
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "pt_BR")
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short

        var lines: [String] = []
        lines.append("# \(recording.title)")
        lines.append("")
        lines.append("- **Data:** \(dateFormatter.string(from: recording.createdAt))")
        lines.append("- **Duração:** \(TimeFormat.duration(seconds: recording.duration))")
        if let language = recording.language {
            lines.append("- **Idioma:** \(language)")
        }
        if !speakers.isEmpty {
            let participants = speakers.map(\.resolvedName).joined(separator: ", ")
            lines.append("- **Participantes:** \(participants)")
        }
        lines.append("")
        lines.append("---")
        lines.append("")
        for segment in segments {
            let stamp = TimeFormat.display(ms: segment.startMs)
            lines.append("**\(name(for: segment, names: names))** [\(stamp)]: \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Clipboard (RF-E2)

    public static func plainTranscript(
        speakers: [Speaker],
        segments: [Segment]
    ) -> String {
        txt(segments: segments, names: speakerNames(speakers))
    }
}
