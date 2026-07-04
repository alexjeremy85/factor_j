import FactorJCore
import SwiftUI

/// Tela inicial (§7.2): ações principais, zona de drop e gravações recentes.
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("Factor J")
                .font(.largeTitle.bold())
            Text("Transcrição e diarização 100% local")
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                BigActionButton(
                    title: "Importar arquivo",
                    subtitle: "Áudio ou vídeo (⌘O)",
                    systemImage: "square.and.arrow.down",
                    disabled: false
                ) {
                    appState.showFileImporter = true
                }

                BigActionButton(
                    title: "Gravar reunião",
                    subtitle: "Mic + áudio do sistema (⇧⌘R)",
                    systemImage: "record.circle",
                    disabled: false
                ) {
                    appState.recorder.showStartSheet = true
                }
            }

            dropZone

            if !appState.modelAvailability.anyWhisper || !appState.modelAvailability.diarization {
                VStack(spacing: 8) {
                    Label(
                        "Os modelos de IA ainda não foram instalados.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    Button("Instalar modelos (~1,7 GB)…") {
                        appState.showSetupAssistant = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            recentSection

            Spacer()
        }
        .padding(40)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 1.5, dash: [6])
            )
            .frame(maxWidth: 480, minHeight: 90, maxHeight: 90)
            .overlay {
                Label(
                    "Arraste arquivos de áudio ou vídeo aqui",
                    systemImage: "arrow.down.doc"
                )
                .foregroundStyle(.secondary)
            }
            .dropDestination(for: URL.self) { urls, _ in
                appState.requestImport(urls: urls)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
    }

    @ViewBuilder
    private var recentSection: some View {
        let recents = Array(appState.recordings.prefix(5))
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recentes")
                    .font(.headline)
                ForEach(recents) { recording in
                    Button {
                        appState.selectedRecordingId = recording.id
                    } label: {
                        HStack {
                            Image(systemName: recording.sourceType == .live
                                ? "mic" : "doc.text")
                                .foregroundStyle(.secondary)
                            Text(recording.title)
                                .lineLimit(1)
                            Spacer()
                            Text(recording.createdAt, format: .dateTime.day().month())
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 480)
        }
    }
}

private struct BigActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 34))
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 210, height: 130)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}
