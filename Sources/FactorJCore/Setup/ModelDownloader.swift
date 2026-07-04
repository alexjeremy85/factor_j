import CryptoKit
import Foundation

/// Baixa e instala os modelos de ML no primeiro uso (assistente de setup).
///
/// Esta é a ÚNICA parte do app que usa rede, e só roda quando o usuário
/// clica em "Instalar modelos". Depois do setup, todo o funcionamento é
/// 100% offline. Alternativa por terminal: scripts/fetch_models.sh.
///
/// Retomada: arquivos já presentes com o tamanho esperado são pulados,
/// então um download interrompido continua de onde parou.
public final class ModelDownloader {
    public struct Progress: Equatable, Sendable {
        public var totalBytes: Int64
        public var downloadedBytes: Int64
        public var currentFile: String
        public var filesDone: Int
        public var filesTotal: Int
        public var isVerifying: Bool

        public init(
            totalBytes: Int64,
            downloadedBytes: Int64,
            currentFile: String,
            filesDone: Int,
            filesTotal: Int,
            isVerifying: Bool
        ) {
            self.totalBytes = totalBytes
            self.downloadedBytes = downloadedBytes
            self.currentFile = currentFile
            self.filesDone = filesDone
            self.filesTotal = filesTotal
            self.isVerifying = isVerifying
        }

        public var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(Double(downloadedBytes) / Double(totalBytes), 1)
        }
    }

    public enum DownloadError: LocalizedError {
        case listingFailed(String)
        case downloadFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case .listingFailed(let repo):
                return "Falha ao listar arquivos de \(repo). Verifique sua conexão."
            case .downloadFailed(let file, let detail):
                return "Falha ao baixar \(file): \(detail)"
            }
        }
    }

    private let modelStore: ModelStore

    public init(modelStore: ModelStore) {
        self.modelStore = modelStore
    }

    // MARK: - Plano de download

    struct RemoteFile {
        var repo: String
        var path: String
        var size: Int64
        var destination: URL
    }

    private struct TreeEntry: Decodable {
        struct LFS: Decodable { var size: Int64 }
        var type: String
        var path: String
        var size: Int64?
        var lfs: LFS?

        var effectiveSize: Int64 { lfs?.size ?? size ?? 0 }
    }

    private func listFiles(repo: String, prefix: String) async throws -> [TreeEntry] {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(repo)/tree/main/\(prefix)")!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let entries = try? JSONDecoder().decode([TreeEntry].self, from: data)
        else {
            throw DownloadError.listingFailed(repo)
        }
        return entries.filter { $0.type == "file" }
    }

    /// Monta a lista completa de arquivos para a qualidade escolhida.
    func buildPlan(quality: WhisperModelQuality) async throws -> [RemoteFile] {
        var plan: [RemoteFile] = []

        // Whisper (pasta inteira do modelo dentro do repo da Argmax)
        let whisperRepo = "argmaxinc/whisperkit-coreml"
        let whisperPrefix = quality.modelFolderName
        for entry in try await listFiles(repo: whisperRepo, prefix: whisperPrefix) {
            plan.append(RemoteFile(
                repo: whisperRepo,
                path: entry.path,
                size: entry.effectiveSize,
                destination: modelStore.whisperRoot.appendingPathComponent(entry.path)
            ))
        }

        // Tokenizer (3 arquivos pequenos do repo da OpenAI)
        let tokenizerFolder = modelStore.whisperTokenizerFolder(quality)
        for file in ["tokenizer.json", "tokenizer_config.json", "config.json"] {
            plan.append(RemoteFile(
                repo: quality.tokenizerRepo,
                path: file,
                size: 0,  // pequenos; tamanho desconhecido não afeta a barra
                destination: tokenizerFolder.appendingPathComponent(file)
            ))
        }

        // Diarização (dois .mlmodelc do repo da FluidInference)
        let diarizationRepo = "FluidInference/speaker-diarization-coreml"
        for prefix in ["pyannote_segmentation.mlmodelc", "wespeaker_v2.mlmodelc"] {
            for entry in try await listFiles(repo: diarizationRepo, prefix: prefix) {
                plan.append(RemoteFile(
                    repo: diarizationRepo,
                    path: entry.path,
                    size: entry.effectiveSize,
                    destination: modelStore.diarizationDirectory.appendingPathComponent(entry.path)
                ))
            }
        }

        guard !plan.isEmpty else {
            throw DownloadError.listingFailed(whisperRepo)
        }
        return plan
    }

    // MARK: - Instalação

    /// Baixa tudo que falta e regenera o SHA256SUMS.txt.
    public func install(
        quality: WhisperModelQuality,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let plan = try await buildPlan(quality: quality)
        let fm = FileManager.default

        // Arquivos já completos (mesmo tamanho) são pulados — retomada natural.
        var pending: [RemoteFile] = []
        var doneBytes: Int64 = 0
        for file in plan {
            if file.size > 0,
               let attrs = try? fm.attributesOfItem(atPath: file.destination.path),
               (attrs[.size] as? Int64) == file.size {
                doneBytes += file.size
            } else {
                pending.append(file)
            }
        }

        let totalBytes = plan.reduce(0) { $0 + $1.size }
        var progress = Progress(
            totalBytes: totalBytes,
            downloadedBytes: doneBytes,
            currentFile: "",
            filesDone: plan.count - pending.count,
            filesTotal: plan.count,
            isVerifying: false
        )
        onProgress(progress)

        for file in pending {
            try Task.checkCancellation()
            progress.currentFile = (file.path as NSString).lastPathComponent
            onProgress(progress)

            let baseBytes = progress.downloadedBytes
            let url = URL(string:
                "https://huggingface.co/\(file.repo)/resolve/main/\(file.path)")!
            do {
                let temp = try await FileDownloadTask().download(url) { written in
                    var p = progress
                    p.downloadedBytes = baseBytes + written
                    onProgress(p)
                }
                try fm.createDirectory(
                    at: file.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? fm.removeItem(at: file.destination)
                try fm.moveItem(at: temp, to: file.destination)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DownloadError.downloadFailed(file.path, error.localizedDescription)
            }

            let actualSize = ((try? fm.attributesOfItem(atPath: file.destination.path))?[.size] as? Int64) ?? 0
            progress.downloadedBytes = baseBytes + max(file.size, actualSize)
            progress.filesDone += 1
            onProgress(progress)
        }

        // Gera o arquivo de somas usado pela verificação de integridade.
        progress.isVerifying = true
        progress.currentFile = "SHA256SUMS.txt"
        onProgress(progress)
        try writeChecksums()
    }

    /// Percorre os modelos instalados e grava Models/SHA256SUMS.txt.
    public func writeChecksums() throws {
        let fm = FileManager.default
        let root = modelStore.modelsDirectory
        var lines: [String] = []

        let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            let isFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile ?? false
            guard isFile, item.lastPathComponent != "SHA256SUMS.txt" else { continue }
            files.append(item)
        }
        files.sort { $0.path < $1.path }

        for file in files {
            let hash = try Self.sha256(of: file)
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            lines.append("\(hash)  \(relative)")
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: modelStore.checksumsURL, atomically: true, encoding: .utf8)
    }

    static func sha256(of url: URL) throws -> String {
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

// MARK: - Download de um arquivo com progresso incremental

/// URLSessionDownloadDelegate embrulhado em async/await, reportando bytes
/// escritos (necessário para a barra de progresso em arquivos de ~1 GB).
private final class FileDownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var onBytes: ((Int64) -> Void)?
    private var movedURL: URL?
    private lazy var session = URLSession(
        configuration: .ephemeral,
        delegate: self,
        delegateQueue: nil
    )

    func download(_ url: URL, onBytes: @escaping (Int64) -> Void) async throws -> URL {
        self.onBytes = onBytes
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onBytes?(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // O arquivo em `location` é apagado quando este método retorna:
        // mover imediatamente para um temporário nosso.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("factorj-dl-\(UUID().uuidString)")
        do {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                continuation?.resume(throwing: URLError(.badServerResponse))
                continuation = nil
                return
            }
            try FileManager.default.moveItem(at: location, to: temp)
            movedURL = temp
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error)
            }
        } else if let movedURL {
            continuation.resume(returning: movedURL)
        } else {
            continuation.resume(throwing: URLError(.cannotWriteToFile))
        }
    }
}
