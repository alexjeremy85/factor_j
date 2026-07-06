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

// MARK: - Sensibilidade de separação de vozes

/// Quão agressivamente o algoritmo separa vozes parecidas em falantes
/// diferentes. Nível semântico, mapeado para o limiar de cada motor.
public enum VoiceSensitivity: String, CaseIterable, Identifiable, Sendable {
    /// Equilíbrio padrão do motor.
    case normal
    /// Separa mais (bom quando há vozes parecidas sendo fundidas).
    case high
    /// Separa menos (bom quando a mesma pessoa está sendo dividida).
    case low

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .normal: return "Padrão"
        case .high: return "Separar mais (vozes parecidas)"
        case .low: return "Separar menos (falante duplicado)"
        }
    }

    /// Limiar de similaridade de cosseno do motor padrão (default 0,7;
    /// menor = mais falantes).
    public var standardThreshold: Float {
        switch self {
        case .normal: return 0.7
        case .high: return 0.62
        case .low: return 0.78
        }
    }

    /// Limiar de distância euclidiana do motor VBx (default 0,6;
    /// menor = mais falantes).
    public var vbxThreshold: Double {
        switch self {
        case .normal: return 0.6
        case .high: return 0.5
        case .low: return 0.7
        }
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

/// Motor que processa o arquivo inteiro de uma vez (re-clustering global —
/// mais preciso para 3+ falantes que o processamento em janelas).
public protocol WholeFileDiarizationEngine: AnyObject {
    /// Diariza o arquivo completo (WAV 16 kHz mono). `onProgress` recebe 0…1.
    func diarize(
        fileURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [DiarizedSpan]
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
