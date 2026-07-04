import FactorJCore
import SwiftUI

/// Tela da gravação selecionada: roteia por status (fila, processando,
/// falha, concluída → transcrição).
struct RecordingDetailView: View {
    @StateObject private var model: RecordingDetailModel
    @ObservedObject private var appState: AppState
    @ObservedObject private var recorder: RecorderController

    init(appState: AppState, recordingId: Int64) {
        self.appState = appState
        _recorder = ObservedObject(wrappedValue: appState.recorder)
        _model = StateObject(wrappedValue: RecordingDetailModel(
            database: appState.database,
            recordingId: recordingId
        ))
    }

    var body: some View {
        Group {
            if let recording = model.recording {
                content(for: recording)
            } else {
                ContentUnavailableView(
                    "Gravação não encontrada",
                    systemImage: "questionmark.folder"
                )
            }
        }
    }

    @ViewBuilder
    private func content(for recording: Recording) -> some View {
        switch recording.status {
        case .queued:
            statusView(
                recording,
                icon: "clock",
                title: "Na fila de processamento",
                message: "Este arquivo será processado em breve."
            ) {
                Button("Cancelar") {
                    if let id = recording.id {
                        appState.processing.cancel(recordingId: id)
                    }
                }
            }

        case .processing, .consolidating:
            processingView(recording)

        case .failed:
            statusView(
                recording,
                icon: "exclamationmark.triangle",
                title: "Falha no processamento",
                message: recording.errorMessage ?? "Erro desconhecido."
            ) {
                Button("Reprocessar") {
                    if let id = recording.id {
                        appState.processing.retry(recordingId: id)
                    }
                }
                .buttonStyle(.borderedProminent)
            }

        case .done:
            TranscriptView(appState: appState, model: model, recording: recording)

        case .live:
            if recorder.currentRecordingId == recording.id {
                RecorderView(recorder: recorder)
                    .navigationTitle(recording.title)
            } else {
                statusView(
                    recording,
                    icon: "hourglass",
                    title: "Finalizando gravação…",
                    message: "Combinando o áudio gravado para transcrição."
                ) { EmptyView() }
            }
        }
    }

    private func processingView(_ recording: Recording) -> some View {
        VStack(spacing: 16) {
            let progress = recording.id.flatMap {
                appState.processing.progressByRecording[$0]
            }
            ProgressView(value: progress?.fraction ?? 0)
                .frame(maxWidth: 360)
            Text(progress?.stage.localizedName ?? "Preparando…")
                .foregroundStyle(.secondary)
            Button("Cancelar") {
                if let id = recording.id {
                    appState.processing.cancel(recordingId: id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(recording.title)
    }

    private func statusView(
        _ recording: Recording,
        icon: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(recording.title)
    }
}
