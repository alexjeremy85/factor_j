import FactorJCore
import SwiftUI

/// Assistente de instalação dos modelos de ML (primeiro uso).
///
/// Única etapa do app que usa rede; explicita isso ao usuário. Suporta
/// retomada (arquivos completos são pulados) e reparo de instalações
/// corrompidas.
@MainActor
final class SetupAssistantModel: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(ModelDownloader.Progress)
        case done
        case failed(String)
    }

    @Published var state: State = .idle
    private var task: Task<Void, Never>?
    private let downloader: ModelDownloader

    init(modelStore: ModelStore) {
        downloader = ModelDownloader(modelStore: modelStore)
    }

    func start(
        quality: WhisperModelQuality,
        includeVbx: Bool,
        onFinished: @escaping () -> Void
    ) {
        guard task == nil else { return }
        state = .downloading(ModelDownloader.Progress(
            totalBytes: 0, downloadedBytes: 0, currentFile: "Listando arquivos…",
            filesDone: 0, filesTotal: 0, isVerifying: false
        ))
        task = Task { [downloader] in
            do {
                try await downloader.install(quality: quality, includeVbx: includeVbx) { progress in
                    Task { @MainActor [weak self] in
                        // Reporta no máximo ~10×/s já que didWriteData é frequente.
                        if case .downloading = self?.state {
                            self?.state = .downloading(progress)
                        }
                    }
                }
                self.state = .done
                onFinished()
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.state = .failed(error.localizedDescription)
            }
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }
}

struct SetupAssistantView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SetupAssistantModel
    @AppStorage("escriba.modelQuality") private var modelQuality = WhisperModelQuality.turbo.rawValue
    @AppStorage("factorj.diarizerEngine") private var diarizerEngine = "standard"

    init(modelStore: ModelStore) {
        _model = StateObject(wrappedValue: SetupAssistantModel(modelStore: modelStore))
    }

    private var quality: WhisperModelQuality {
        WhisperModelQuality(rawValue: modelQuality) ?? .turbo
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("Instalar modelos de IA")
                .font(.title2.bold())

            switch model.state {
            case .idle:
                idleContent
            case .downloading(let progress):
                downloadingContent(progress)
            case .done:
                doneContent
            case .failed(let message):
                failedContent(message)
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private var idleContent: some View {
        VStack(spacing: 14) {
            Text("O Factor J transcreve tudo no seu Mac, sem nuvem. Para isso, precisa baixar os modelos do modelo de transcrição escolhido nos Ajustes (padrão: ~1,7 GB). Esta é a única etapa que usa internet — depois dela, o app funciona 100% offline.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Agora não") { dismiss() }
                Button("Baixar e instalar") {
                    model.start(quality: quality, includeVbx: diarizerEngine == "vbx") {
                        appState.refreshModelAvailability()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func downloadingContent(_ progress: ModelDownloader.Progress) -> some View {
        VStack(spacing: 10) {
            if progress.totalBytes > 0 {
                ProgressView(value: progress.fraction)
                Text(String(
                    format: "%.0f de %.0f MB — %@",
                    Double(progress.downloadedBytes) / 1_048_576,
                    Double(progress.totalBytes) / 1_048_576,
                    progress.isVerifying
                        ? "verificando integridade…"
                        : progress.currentFile
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else {
                ProgressView()
                Text(progress.currentFile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cancelar") { model.cancel() }
                .padding(.top, 4)
        }
    }

    private var doneContent: some View {
        VStack(spacing: 14) {
            Label("Modelos instalados e verificados.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Pronto! Arraste um áudio para a janela para transcrever.")
                .foregroundStyle(.secondary)
            Button("Começar a usar") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("O download continua de onde parou.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Fechar") { dismiss() }
                Button("Tentar de novo") {
                    model.state = .idle
                    model.start(quality: quality, includeVbx: diarizerEngine == "vbx") {
                        appState.refreshModelAvailability()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
