import Foundation

// MARK: - Resultados intermediários do pipeline

/// Palavra transcrita com tempos absolutos no áudio.
public struct TranscribedWord: Equatable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    /// 0…1
    public var probability: Double

    public init(text: String, startMs: Int, endMs: Int, probability: Double) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.probability = probability
    }
}

/// Segmento de transcrição do ASR (nível frase/janela do Whisper).
public struct TranscribedSegment: Equatable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    /// 0…1 (derivada de avgLogprob).
    public var confidence: Double
    /// Palavras com timestamps, quando disponíveis.
    public var words: [TranscribedWord]

    public init(
        text: String,
        startMs: Int,
        endMs: Int,
        confidence: Double,
        words: [TranscribedWord] = []
    ) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
        self.words = words
    }
}

/// Trecho de fala atribuído a um falante pela diarização.
public struct DiarizedSpan: Equatable, Sendable {
    /// Chave estável do falante dentro da gravação (vinda do motor de diarização).
    public var speakerKey: String
    public var startMs: Int
    public var endMs: Int
    public var quality: Double

    public init(speakerKey: String, startMs: Int, endMs: Int, quality: Double = 1.0) {
        self.speakerKey = speakerKey
        self.startMs = startMs
        self.endMs = endMs
        self.quality = quality
    }
}

/// Turno final de fala: saída do alinhador, pronto para persistir.
public struct AlignedTurn: Equatable, Sendable {
    /// nil = falante desconhecido / diarização desligada.
    public var speakerKey: String?
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var confidence: Double?
    public var isOverlap: Bool

    public init(
        speakerKey: String?,
        startMs: Int,
        endMs: Int,
        text: String,
        confidence: Double? = nil,
        isOverlap: Bool = false
    ) {
        self.speakerKey = speakerKey
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
        self.isOverlap = isOverlap
    }
}

// MARK: - Progresso

public enum PipelineStage: String, Sendable {
    case converting
    case transcribing
    case diarizing
    case aligning

    public var localizedName: String {
        switch self {
        case .converting: return "Convertendo áudio…"
        case .transcribing: return "Transcrevendo…"
        case .diarizing: return "Identificando falantes…"
        case .aligning: return "Alinhando…"
        }
    }
}

public struct PipelineProgress: Equatable, Sendable {
    public var stage: PipelineStage
    /// 0…1 dentro do processamento total da gravação.
    public var fraction: Double

    public init(stage: PipelineStage, fraction: Double) {
        self.stage = stage
        self.fraction = min(max(fraction, 0), 1)
    }
}

// MARK: - Protocolos dos motores (permitem testes sem modelos reais)

public protocol TranscriptionEngine: AnyObject {
    /// Carrega os modelos na memória (chamada única, cara).
    func load() async throws

    /// Transcreve amostras 16 kHz mono. `offsetMs` desloca os timestamps
    /// para o tempo absoluto da gravação.
    /// - Returns: segmentos com palavras e, quando idioma = auto, o idioma detectado.
    func transcribe(
        samples: [Float],
        language: String?,
        offsetMs: Int
    ) async throws -> (segments: [TranscribedSegment], detectedLanguage: String?)

    func unload()
}

public protocol DiarizationEngine: AnyObject {
    /// Diariza amostras 16 kHz mono a partir do offset dado. Chamadas
    /// sucessivas na mesma instância mantêm a identidade dos falantes.
    func diarize(samples: [Float], offsetMs: Int) throws -> [DiarizedSpan]
}

// MARK: - Erros

public enum PipelineError: LocalizedError {
    case noAudioTrack
    case audioReadFailed(String)
    case modelsMissing(String)
    case transcriptionFailed(String)
    case diarizationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "O arquivo não contém trilha de áudio."
        case .audioReadFailed(let detail):
            return "Falha ao ler o áudio: \(detail)"
        case .modelsMissing(let detail):
            return "Modelos de ML ausentes: \(detail). Instale em Ajustes → Modelos."
        case .transcriptionFailed(let detail):
            return "Falha na transcrição: \(detail)"
        case .diarizationFailed(let detail):
            return "Falha na identificação de falantes: \(detail)"
        }
    }
}
