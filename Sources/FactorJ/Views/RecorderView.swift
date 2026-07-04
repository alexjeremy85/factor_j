import FactorJCore
import SwiftUI

/// Tela de gravação ao vivo (§7.4): timer, VU meters por fonte e botões
/// Pausar / Marcar momento / Encerrar.
struct RecorderView: View {
    @ObservedObject var recorder: RecorderController

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            HStack(spacing: 10) {
                Circle()
                    .fill(recorder.isPaused ? Color.orange : Color.red)
                    .frame(width: 12, height: 12)
                    .opacity(recorder.isPaused ? 1 : 0.9)
                Text(recorder.isPaused ? "Pausado" : "Gravando")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Text(TimeFormat.display(ms: recorder.elapsedMs))
                .font(.system(size: 56, weight: .light, design: .monospaced))

            VStack(spacing: 12) {
                LevelMeter(label: "Microfone", icon: "mic", level: recorder.micLevel)
                LevelMeter(label: "Sistema", icon: "speaker.wave.2", level: recorder.systemLevel)
            }
            .frame(maxWidth: 380)

            if recorder.markerCount > 0 {
                Text("\(recorder.markerCount) momento(s) marcado(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Button {
                    recorder.togglePause()
                } label: {
                    Label(
                        recorder.isPaused ? "Retomar" : "Pausar",
                        systemImage: recorder.isPaused ? "play.fill" : "pause.fill"
                    )
                    .frame(width: 110)
                }
                .controlSize(.large)

                Button {
                    recorder.addMarker()
                } label: {
                    Label("Marcar momento", systemImage: "bookmark")
                        .frame(width: 150)
                }
                .controlSize(.large)
                .keyboardShortcut("m", modifiers: .command)

                Button {
                    recorder.stop()
                } label: {
                    Label("Encerrar", systemImage: "stop.fill")
                        .frame(width: 110)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Text("Ao encerrar, a transcrição começa automaticamente.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(30)
    }
}

private struct LevelMeter: View {
    let label: String
    let icon: String
    let level: Float

    var body: some View {
        HStack(spacing: 10) {
            Label(label, systemImage: icon)
                .frame(width: 120, alignment: .leading)
                .font(.callout)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(level > 0.85 ? Color.orange : Color.green)
                        .frame(width: geometry.size.width * CGFloat(min(level, 1)))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 8)
        }
    }
}

/// Seletor de fontes exibido antes de iniciar a gravação (§5.1).
struct RecorderStartSheet: View {
    @ObservedObject var recorder: RecorderController
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var sourceOption = 0  // 0 = ambos, 1 = mic, 2 = sistema

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gravar reunião")
                .font(.title3.bold())

            TextField("Título (opcional)", text: $title, prompt: Text("Reunião de hoje…"))
                .textFieldStyle(.roundedBorder)

            Picker("Fontes", selection: $sourceOption) {
                Text("Microfone + áudio do sistema").tag(0)
                Text("Só microfone").tag(1)
                Text("Só áudio do sistema").tag(2)
            }
            .pickerStyle(.radioGroup)

            Text("O áudio do sistema captura o que sai das caixas (Teams, Zoom, Meet…). Na primeira vez, o macOS pede autorização.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Gravar") {
                    let sources: RecordingSources = switch sourceOption {
                    case 1: .microphone
                    case 2: .system
                    default: .both
                    }
                    let chosenTitle = title
                    dismiss()
                    Task { await recorder.start(sources: sources, title: chosenTitle) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 400)
    }
}

/// Orientação quando uma permissão foi negada (RF-G5).
struct PermissionSheet: View {
    let issue: RecorderController.PermissionIssue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            switch issue {
            case .microphone:
                Text("Sem acesso ao microfone")
                    .font(.title3.bold())
                Text("Autorize o Factor J em Ajustes do Sistema → Privacidade e Segurança → Microfone, e tente de novo.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Abrir Ajustes do Sistema") {
                    RecorderController.openMicrophoneSettings()
                }
                .buttonStyle(.borderedProminent)

            case .systemAudio(let detail):
                Text("Sem acesso ao áudio do sistema")
                    .font(.title3.bold())
                Text(detail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Abrir Ajustes do Sistema") {
                    RecorderController.openSystemAudioSettings()
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Fechar") { dismiss() }
        }
        .padding(24)
        .frame(width: 400)
    }
}
