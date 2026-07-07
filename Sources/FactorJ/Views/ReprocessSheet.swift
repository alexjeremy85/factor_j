import FactorJCore
import SwiftUI

/// Reprocessa uma gravação existente com novas opções (idioma, diarização,
/// falantes, sensibilidade) — o áudio original é mantido; a transcrição é
/// gerada de novo do zero.
struct ReprocessSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let recording: Recording

    @State private var language = "auto"
    @State private var diarize = true
    @State private var speakersMode = 0  // 0 = auto
    @State private var sensitivity = VoiceSensitivity.normal

    private static let languages: [(code: String, name: String)] = [
        ("auto", "Detectar automaticamente"),
        ("pt", "Português"),
        ("en", "Inglês"),
        ("es", "Espanhol"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reprocessar gravação")
                .font(.title3.bold())
            Text(recording.title)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Divider()

            Picker("Idioma", selection: $language) {
                ForEach(Self.languages, id: \.code) { item in
                    Text(item.name).tag(item.code)
                }
            }

            Toggle("Identificar falantes (diarização)", isOn: $diarize)

            Picker("Número de falantes", selection: $speakersMode) {
                Text("Automático").tag(0)
                ForEach(2...10, id: \.self) { n in
                    Text("\(n)").tag(n)
                }
            }
            .disabled(!diarize)

            Picker("Separação de vozes", selection: $sensitivity) {
                ForEach(VoiceSensitivity.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .disabled(!diarize)

            Label(
                "A transcrição atual será substituída — edições de texto e nomes de falantes desta gravação serão perdidos.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Reprocessar") {
                    appState.reprocess(
                        recording,
                        language: language == "auto" ? nil : language,
                        diarize: diarize,
                        speakersHint: speakersMode == 0 ? nil : speakersMode,
                        sensitivity: sensitivity
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            // Parte das opções atuais da gravação.
            language = recording.language ?? "auto"
            diarize = recording.diarize
            speakersMode = recording.speakersHint ?? 0
            sensitivity = recording.voiceSensitivity
        }
    }
}
