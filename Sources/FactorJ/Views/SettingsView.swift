import AppKit
import FactorJCore
import ServiceManagement
import SwiftUI

/// Ajustes do app (§7.6).
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Geral", systemImage: "gearshape") }
            ModelsSettingsView()
                .tabItem { Label("Modelos", systemImage: "cpu") }
        }
        .frame(width: 520)
        .padding(.bottom, 8)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("escriba.defaultLanguage") private var defaultLanguage = "auto"
    @AppStorage("escriba.modelQuality") private var modelQuality = WhisperModelQuality.turbo.rawValue
    @AppStorage("factorj.menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("factorj.hotkeyEnabled") private var hotkeyEnabled = true
    @AppStorage("factorj.hotkeyPreset") private var hotkeyPreset = "opt-cmd-r"
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled

    private var loginToggle: some View {
        Toggle("Iniciar no login", isOn: Binding(
            get: { loginItemEnabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginItemEnabled = newValue
                } catch {
                    loginItemEnabled = SMAppService.mainApp.status == .enabled
                }
            }
        ))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Armazenamento") {
                    HStack {
                        Text(appState.dataStore.rootURL.path)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Button("Mostrar no Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [appState.dataStore.rootURL]
                            )
                        }
                    }
                }
                Text("Tudo o que você grava e transcreve fica nesta pasta, para sempre — só sai se você excluir. Para backup, copie a pasta inteira (o Time Machine já a inclui).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Idioma padrão", selection: $defaultLanguage) {
                    Text("Detectar automaticamente").tag("auto")
                    Text("Português").tag("pt")
                    Text("Inglês").tag("en")
                    Text("Espanhol").tag("es")
                }

                Picker("Modelo de transcrição", selection: $modelQuality) {
                    ForEach(WhisperModelQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality.rawValue)
                    }
                }
                Text("large-v3-turbo entrega a melhor qualidade em pt-BR; base é mais rápido e leve.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gravação e segundo plano") {
                Toggle("Continuar em segundo plano ao fechar a janela", isOn: $menuBarEnabled)
                Text("O ícone na barra de menus fica sempre disponível; com isto ligado, fechar a janela não encerra o app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Atalho global para gravar/encerrar", isOn: $hotkeyEnabled)
                Picker("Atalho", selection: $hotkeyPreset) {
                    ForEach(HotKeyManager.presets) { preset in
                        Text(preset.label).tag(preset.id)
                    }
                }
                .disabled(!hotkeyEnabled)

                loginToggle
                Text("Iniciar no login exige o app instalado (dist/FactorJ.app em /Applications).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: hotkeyEnabled) { _, _ in appState.refreshHotkey() }
            .onChange(of: hotkeyPreset) { _, _ in appState.refreshHotkey() }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}

private struct ModelsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var integrityIssues: [String]?
    @State private var checking = false

    var body: some View {
        Form {
            Section("Disponibilidade") {
                availabilityRow(
                    "Whisper large-v3-turbo",
                    available: appState.modelAvailability.whisperTurbo
                )
                availabilityRow(
                    "Whisper base (rápido)",
                    available: appState.modelAvailability.whisperBase
                )
                availabilityRow(
                    "Diarização (pyannote + WeSpeaker)",
                    available: appState.modelAvailability.diarization
                )
                Button("Baixar / reparar modelos…") {
                    appState.showSetupAssistant = true
                }
                Text("O download roda dentro do app, uma única vez, e retoma de onde parou. Fora dessa etapa, nenhuma conexão de rede acontece. Alternativa por terminal: `scripts/fetch_models.sh`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Integridade") {
                HStack {
                    Button(checking ? "Verificando…" : "Verificar integridade dos modelos") {
                        verify()
                    }
                    .disabled(checking)
                    Spacer()
                }
                if let issues = integrityIssues {
                    if issues.isEmpty {
                        Label("Todos os modelos íntegros.", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(issues, id: \.self) { issue in
                            Label(issue, systemImage: "xmark.seal")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onAppear { appState.refreshModelAvailability() }
    }

    private func availabilityRow(_ name: String, available: Bool) -> some View {
        LabeledContent(name) {
            Label(
                available ? "Instalado" : "Ausente",
                systemImage: available ? "checkmark.circle.fill" : "xmark.circle"
            )
            .foregroundStyle(available ? .green : .orange)
        }
    }

    private func verify() {
        checking = true
        let store = appState.modelStore
        Task.detached(priority: .utility) {
            let issues = store.verifyIntegrity()
            await MainActor.run {
                integrityIssues = issues
                checking = false
            }
        }
    }
}
