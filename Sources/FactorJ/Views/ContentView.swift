import FactorJCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detailContent
        }
        .fileImporter(
            isPresented: $appState.showFileImporter,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                appState.requestImport(urls: urls)
            }
        }
        .sheet(isPresented: $appState.showImportOptions) {
            ImportOptionsSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showSetupAssistant) {
            SetupAssistantView(modelStore: appState.modelStore)
                .environmentObject(appState)
        }
        .sheet(item: $appState.reprocessTarget) { recording in
            ReprocessSheet(recording: recording)
                .environmentObject(appState)
        }
        .background(RecorderSheets(recorder: appState.recorder))
        .dropDestination(for: URL.self) { urls, _ in
            appState.requestImport(urls: urls)
            return true
        }
        .alert(
            "Erro",
            isPresented: Binding(
                get: { appState.lastError != nil },
                set: { if !$0 { appState.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.lastError ?? "")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let bootError = appState.bootError {
            ContentUnavailableView(
                "Falha ao iniciar",
                systemImage: "exclamationmark.triangle",
                description: Text(bootError)
            )
        } else if !appState.searchText.isEmpty {
            SearchResultsView()
        } else if let id = appState.selectedRecordingId {
            RecordingDetailView(appState: appState, recordingId: id)
                .id(id)
        } else {
            HomeView()
        }
    }

    private var importTypes: [UTType] {
        Self.importContentTypes
    }

    static var importContentTypes: [UTType] {
        var types: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav]
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        return types
    }
}

/// Hospeda as folhas globais do gravador (iniciar gravação / permissões),
/// observando o RecorderController diretamente.
private struct RecorderSheets: View {
    @ObservedObject var recorder: RecorderController

    var body: some View {
        Color.clear
            .sheet(isPresented: $recorder.showStartSheet) {
                RecorderStartSheet(recorder: recorder)
            }
            .sheet(item: $recorder.permissionIssue) { issue in
                PermissionSheet(issue: issue)
            }
    }
}
