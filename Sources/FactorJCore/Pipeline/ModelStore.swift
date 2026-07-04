import CryptoKit
import Foundation

/// Qualidade/velocidade do modelo Whisper (§7.6).
public enum WhisperModelQuality: String, CaseIterable, Identifiable, Sendable {
    /// large-v3-turbo — qualidade (default).
    case turbo
    /// base multilíngue — velocidade / preview.
    case base

    public var id: String { rawValue }

    public var modelFolderName: String {
        switch self {
        case .turbo: return "openai_whisper-large-v3-v20240930_turbo"
        case .base: return "openai_whisper-base"
        }
    }

    public var displayName: String {
        switch self {
        case .turbo: return "large-v3-turbo (qualidade)"
        case .base: return "base (velocidade)"
        }
    }

    /// Repositório HF do tokenizer correspondente (usado só no fetch_models.sh).
    public var tokenizerRepo: String {
        switch self {
        case .turbo: return "openai/whisper-large-v3"
        case .base: return "openai/whisper-base"
        }
    }
}

/// Disponibilidade dos modelos embarcados (§3).
public struct ModelAvailability: Equatable, Sendable {
    public var whisperTurbo: Bool
    public var whisperBase: Bool
    public var diarization: Bool

    public init(whisperTurbo: Bool, whisperBase: Bool, diarization: Bool) {
        self.whisperTurbo = whisperTurbo
        self.whisperBase = whisperBase
        self.diarization = diarization
    }

    public func whisperAvailable(_ quality: WhisperModelQuality) -> Bool {
        switch quality {
        case .turbo: return whisperTurbo
        case .base: return whisperBase
        }
    }

    public var anyWhisper: Bool { whisperTurbo || whisperBase }
}

/// Localiza e valida os modelos de ML no diretório de dados.
///
/// Layout esperado (criado por scripts/fetch_models.sh):
/// ```
/// Models/
///   whisperkit/
///     openai_whisper-large-v3-v20240930_turbo/   — AudioEncoder/TextDecoder/… .mlmodelc
///     openai_whisper-base/                        — idem (opcional)
///     tokenizers/<pasta do modelo>/tokenizer.json — tokenizer offline
///   diarization/
///     pyannote_segmentation.mlmodelc
///     wespeaker_v2.mlmodelc
///   SHA256SUMS.txt                                — integridade (primeiro launch)
/// ```
public struct ModelStore: Sendable {
    public let modelsDirectory: URL

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    // MARK: - Caminhos

    public var whisperRoot: URL {
        modelsDirectory.appendingPathComponent("whisperkit", isDirectory: true)
    }

    public func whisperModelFolder(_ quality: WhisperModelQuality) -> URL {
        whisperRoot.appendingPathComponent(quality.modelFolderName, isDirectory: true)
    }

    public func whisperTokenizerFolder(_ quality: WhisperModelQuality) -> URL {
        whisperRoot
            .appendingPathComponent("tokenizers", isDirectory: true)
            .appendingPathComponent(quality.modelFolderName, isDirectory: true)
    }

    public var diarizationDirectory: URL {
        modelsDirectory.appendingPathComponent("diarization", isDirectory: true)
    }

    public var segmentationModelURL: URL {
        diarizationDirectory.appendingPathComponent("pyannote_segmentation.mlmodelc")
    }

    public var embeddingModelURL: URL {
        diarizationDirectory.appendingPathComponent("wespeaker_v2.mlmodelc")
    }

    public var checksumsURL: URL {
        modelsDirectory.appendingPathComponent("SHA256SUMS.txt")
    }

    // MARK: - Disponibilidade

    /// Um `.mlmodelc` válido é um diretório com `coremldata.bin` dentro —
    /// checar só a existência da pasta aceitaria downloads interrompidos.
    private func isCompiledModelPresent(_ url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent("coremldata.bin").path
        )
    }

    public func isWhisperAvailable(_ quality: WhisperModelQuality) -> Bool {
        let folder = whisperModelFolder(quality)
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        guard required.allSatisfy({
            isCompiledModelPresent(folder.appendingPathComponent($0))
        }) else { return false }
        let tokenizer = whisperTokenizerFolder(quality).appendingPathComponent("tokenizer.json")
        return FileManager.default.fileExists(atPath: tokenizer.path)
    }

    public func isDiarizationAvailable() -> Bool {
        isCompiledModelPresent(segmentationModelURL)
            && isCompiledModelPresent(embeddingModelURL)
    }

    public func availability() -> ModelAvailability {
        ModelAvailability(
            whisperTurbo: isWhisperAvailable(.turbo),
            whisperBase: isWhisperAvailable(.base),
            diarization: isDiarizationAvailable()
        )
    }

    // MARK: - Integridade (checksum, §3)

    /// Verifica os arquivos listados em SHA256SUMS.txt.
    /// - Returns: lista de problemas encontrados (vazia = tudo OK).
    public func verifyIntegrity() -> [String] {
        guard let content = try? String(contentsOf: checksumsURL, encoding: .utf8) else {
            return ["SHA256SUMS.txt não encontrado — rode scripts/fetch_models.sh."]
        }
        var issues: [String] = []
        for line in content.split(separator: "\n") {
            // Formato: "<sha256>  <caminho relativo>"
            let parts = line.split(separator: " ", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let expected = parts[0].lowercased()
            let fileURL = modelsDirectory.appendingPathComponent(parts[1])
            guard let actual = try? sha256(of: fileURL) else {
                issues.append("Ausente: \(parts[1])")
                continue
            }
            if actual != expected {
                issues.append("Corrompido: \(parts[1])")
            }
        }
        return issues
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 * 1024 * 1024)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
