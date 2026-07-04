import AppKit
import Combine
import FactorJCore
import Foundation
import SwiftUI

/// Estado global do gravador: compartilhado pela janela principal, pela
/// barra de menus e pelo atalho global.
@MainActor
final class RecorderController: ObservableObject {
    enum PermissionIssue: Identifiable {
        case microphone
        case systemAudio(String)

        var id: String {
            switch self {
            case .microphone: return "microphone"
            case .systemAudio: return "systemAudio"
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsedMs = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var markerCount = 0
    @Published var permissionIssue: PermissionIssue?
    @Published var showStartSheet = false

    private var session: RecordingSession?
    private var timer: Timer?
    private weak var appState: AppState?

    var currentRecordingId: Int64? { session?.recordingId }

    func attach(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Ações (UI, menu bar e atalho global)

    /// Alterna gravação: comportamento do atalho global e da barra de menus.
    func toggleFromShortcut() {
        if isRecording {
            stop()
        } else {
            startWithDefaults()
        }
    }

    /// Inicia direto com as fontes padrão (Ambos), sem abrir a janela.
    func startWithDefaults() {
        Task { await start(sources: .both) }
    }

    func start(sources: RecordingSources, title: String? = nil) async {
        guard !isRecording, let appState else { return }

        if sources.contains(.microphone) {
            guard await MicRecorder.requestPermission() else {
                permissionIssue = .microphone
                return
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        let defaultTitle = "Reunião de \(formatter.string(from: Date()))"

        var createdId: Int64?
        do {
            let recording = try appState.database.createRecording(Recording(
                title: title?.isEmpty == false ? title! : defaultTitle,
                sourceType: .live,
                audioPath: "",
                status: .live,
                language: nil
            ))
            guard let id = recording.id else { return }
            createdId = id

            let session = RecordingSession(
                recordingId: id,
                sources: sources,
                dataStore: appState.dataStore,
                database: appState.database,
                onMicLevel: { [weak self] level in
                    Task { @MainActor [weak self] in self?.micLevel = level }
                },
                onSystemLevel: { [weak self] level in
                    Task { @MainActor [weak self] in self?.systemLevel = level }
                }
            )
            try session.start()

            self.session = session
            isRecording = true
            isPaused = false
            markerCount = 0
            elapsedMs = 0
            appState.selectedRecordingId = id
            startTimer()
        } catch {
            if let createdId {
                try? appState.database.deleteRecording(id: createdId)
                if appState.selectedRecordingId == createdId {
                    appState.selectedRecordingId = nil
                }
            }
            session = nil
            isRecording = false
            if let tapError = error as? SystemAudioTap.TapError {
                permissionIssue = .systemAudio(tapError.localizedDescription)
            } else {
                appState.lastError = "Falha ao iniciar gravação: \(error.localizedDescription)"
            }
        }
    }

    func togglePause() {
        guard let session else { return }
        if session.isPaused {
            session.resume()
            isPaused = false
        } else {
            session.pause()
            isPaused = true
        }
    }

    func addMarker() {
        guard let session else { return }
        try? session.addMarker()
        markerCount += 1
    }

    func stop() {
        guard let session, let appState else { return }
        stopTimer()
        isRecording = false
        isPaused = false
        micLevel = 0
        systemLevel = 0
        let recordingId = session.recordingId
        self.session = nil

        // Finalização (merge dos arquivos) fora da MainActor.
        Task.detached(priority: .userInitiated) { [database = appState.database] in
            do {
                try session.stop()
            } catch {
                try? database.setStatus(
                    recordingId: recordingId,
                    status: .failed,
                    errorMessage: "Falha ao finalizar gravação: \(error.localizedDescription)"
                )
            }
            await MainActor.run { [weak appState] in
                appState?.processing.kick()
                appState?.selectedRecordingId = recordingId
            }
        }
    }

    func discard() {
        guard let session, let appState else { return }
        stopTimer()
        isRecording = false
        isPaused = false
        if appState.selectedRecordingId == session.recordingId {
            appState.selectedRecordingId = nil
        }
        session.discard()
        self.session = nil
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let session = self.session else { return }
                self.elapsedMs = Int(session.elapsed * 1000)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Ajustes do Sistema (RF-G5)

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
