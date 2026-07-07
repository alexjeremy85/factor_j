import FactorJCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var recordingToRename: Recording?
    @State private var renameText = ""

    var body: some View {
        List(selection: $appState.selectedRecordingId) {
            Section("Gravações") {
                ForEach(appState.recordings) { recording in
                    RecordingRow(recording: recording)
                        .tag(recording.id ?? -1)
                        .contextMenu { contextMenu(for: recording) }
                }
            }
        }
        .searchable(text: $appState.searchText, prompt: "Buscar nas transcrições")
        .safeAreaInset(edge: .bottom) {
            modelsFooter
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button {
                        appState.showFileImporter = true
                    } label: {
                        Label("Importar arquivo…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        appState.recorder.showStartSheet = true
                    } label: {
                        Label("Gravar reunião…", systemImage: "record.circle")
                    }
                } label: {
                    Label("Nova", systemImage: "plus")
                }
            }
        }
        .alert("Renomear gravação", isPresented: Binding(
            get: { recordingToRename != nil },
            set: { if !$0 { recordingToRename = nil } }
        )) {
            TextField("Título", text: $renameText)
            Button("Cancelar", role: .cancel) { recordingToRename = nil }
            Button("OK") {
                if let recording = recordingToRename {
                    appState.renameRecording(recording, to: renameText)
                }
                recordingToRename = nil
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for recording: Recording) -> some View {
        if let id = recording.id {
            switch recording.status {
            case .queued, .processing:
                Button("Cancelar processamento") {
                    appState.processing.cancel(recordingId: id)
                }
            case .failed:
                Button("Reprocessar") {
                    appState.processing.retry(recordingId: id)
                }
            default:
                EmptyView()
            }
            if recording.status == .done || recording.status == .failed {
                Button("Reprocessar com opções…") {
                    appState.reprocessTarget = recording
                }
            }
            Button("Renomear…") {
                renameText = recording.title
                recordingToRename = recording
            }
            Divider()
            Button("Excluir…", role: .destructive) {
                appState.deleteRecording(recording)
            }
        }
    }

    private var modelsFooter: some View {
        HStack(spacing: 6) {
            let quality = ProcessingCenter.selectedQuality
            let ready = appState.modelAvailability.whisperAvailable(quality)
                && appState.modelAvailability.diarization
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? .green : .orange)
            if ready {
                Text("Modelos prontos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Modelos ausentes — instalar…") {
                    appState.showSetupAssistant = true
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(8)
        .background(.bar)
    }
}

private struct RecordingRow: View {
    @EnvironmentObject private var appState: AppState
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(recording.title)
                    .lineLimit(1)
                    .fontWeight(.medium)
                Spacer()
                statusBadge
            }
            HStack(spacing: 4) {
                Text(recording.createdAt, format: .dateTime.day().month().year())
                if recording.duration > 0 {
                    Text("•")
                    Text(TimeFormat.duration(seconds: recording.duration))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if recording.status == .processing,
               let id = recording.id,
               let progress = appState.processing.progressByRecording[id] {
                ProgressView(value: progress.fraction)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch recording.status {
        case .queued:
            Text("Na fila")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        case .processing, .consolidating:
            ProgressView()
                .controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .live:
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
        case .done:
            EmptyView()
        }
    }
}
