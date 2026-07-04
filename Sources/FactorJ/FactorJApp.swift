import AppKit
import FactorJCore
import SwiftUI

/// Mantém o app vivo em segundo plano quando o modo correspondente está
/// ativo nos Ajustes (fechar a janela não encerra o app).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "factorj.menuBarEnabled")
    }
}

@main
struct FactorJApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Factor J", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    // Necessário quando rodando como executável SPM (swift run):
                    // garante janela em primeiro plano com menu bar.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Importar Arquivo…") {
                    appState.showFileImporter = true
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Gravar Reunião…") {
                    appState.recorder.showStartSheet = true
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // Sempre inserida (sem isInserted: binding com AppStorage — a
        // combinação disparava um loop de invalidação da cena que travava
        // o app na abertura). O ícone observa o gravador diretamente.
        MenuBarExtra {
            MenuBarContent(recorder: appState.recorder)
                .environmentObject(appState)
        } label: {
            MenuBarLabel(recorder: appState.recorder)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

/// Ícone da barra de menus: um "J" neutro, deliberadamente idêntico com ou
/// sem gravação em andamento — nada denuncia o app numa tela projetada.
/// O status aparece só ao abrir o menu.
private struct MenuBarLabel: View {
    @ObservedObject var recorder: RecorderController

    var body: some View {
        Text("J")
            .font(.system(size: 14, weight: .bold, design: .rounded))
    }
}

/// Conteúdo do menu na barra de menus: gravação com um clique, sem
/// precisar abrir a janela.
private struct MenuBarContent: View {
    @ObservedObject var recorder: RecorderController
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if recorder.isRecording {
            Text("Gravando — \(TimeFormat.display(ms: recorder.elapsedMs))")
            Button(recorder.isPaused ? "Retomar" : "Pausar") {
                recorder.togglePause()
            }
            Button("Marcar momento") {
                recorder.addMarker()
            }
            Button("Encerrar gravação") {
                recorder.stop()
                openMainWindow()
            }
        } else {
            Button("Gravar reunião agora") {
                recorder.startWithDefaults()
            }
            Button("Gravar com opções…") {
                openMainWindow()
                recorder.showStartSheet = true
            }
        }

        Divider()

        Button("Abrir o Factor J") {
            openMainWindow()
        }

        Divider()

        Button("Sair do Factor J") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
