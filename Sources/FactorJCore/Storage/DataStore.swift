import Foundation

/// Localização dos dados do app em disco (RF-D1).
///
/// Estrutura:
/// ```
/// ~/Library/Application Support/FactorJ/
///   escriba.sqlite      — banco de metadados/transcrições
///   Audio/              — arquivos de áudio originais (copiados na importação)
///   Models/             — modelos de ML (instalados via scripts/fetch_models.sh)
///   tmp/                — intermediários de processamento (WAV 16 kHz)
/// ```
public struct DataStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.rootURL = appSupport.appendingPathComponent("FactorJ", isDirectory: true)
        }
    }

    public var databaseURL: URL { rootURL.appendingPathComponent("escriba.sqlite") }
    public var audioDirectory: URL { rootURL.appendingPathComponent("Audio", isDirectory: true) }
    public var modelsDirectory: URL { rootURL.appendingPathComponent("Models", isDirectory: true) }
    public var tempDirectory: URL { rootURL.appendingPathComponent("tmp", isDirectory: true) }

    public func ensureDirectories() throws {
        migrateLegacyDirectoryIfNeeded()
        let fm = FileManager.default
        for dir in [rootURL, audioDirectory, modelsDirectory, tempDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// O app se chamava "Escriba"; instalações antigas têm os dados em
    /// `Application Support/Escriba`. Move a pasta inteira (banco, áudios e
    /// modelos) para o novo nome, uma única vez.
    private func migrateLegacyDirectoryIfNeeded() {
        let fm = FileManager.default
        let legacy = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("Escriba", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: rootURL.path)
        else { return }
        try? fm.moveItem(at: legacy, to: rootURL)
    }

    /// Copia um arquivo importado para Audio/ com nome único.
    /// Retorna o caminho relativo à raiz (valor de `Recording.audioPath`).
    public func importAudioFile(from source: URL) throws -> String {
        try ensureDirectories()
        let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension
        let name = UUID().uuidString + "." + ext
        let destination = audioDirectory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        return "Audio/" + name
    }

    public func absoluteURL(for relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    public func removeAudioFile(relativePath: String) {
        let url = absoluteURL(for: relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    /// URL temporária para o WAV 16 kHz intermediário de uma gravação.
    public func tempWavURL(recordingId: Int64) -> URL {
        tempDirectory.appendingPathComponent("rec_\(recordingId)_16k.wav")
    }

    public func cleanTempDirectory() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }
}
