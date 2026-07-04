import FactorJCore
import SwiftUI

/// Opções de importação (§4.1) aplicadas a todos os arquivos selecionados.
struct ImportOptionsSheet: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("escriba.defaultLanguage") private var defaultLanguage = "auto"

    @State private var language = "auto"
    @State private var diarize = true
    @State private var speakersMode = 0  // 0 = auto

    private static let languages: [(code: String, name: String)] = [
        ("auto", "Detectar automaticamente"),
        ("pt", "Português"),
        ("en", "Inglês"),
        ("es", "Espanhol"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(appState.pendingImportURLs.count == 1
                ? "Importar 1 arquivo"
                : "Importar \(appState.pendingImportURLs.count) arquivos")
                .font(.title3.bold())

            ForEach(appState.pendingImportURLs.prefix(4), id: \.self) { url in
                Label(url.lastPathComponent, systemImage: "doc.audio")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            if appState.pendingImportURLs.count > 4 {
                Text("… e mais \(appState.pendingImportURLs.count - 4)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

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

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) {
                    appState.pendingImportURLs = []
                    appState.showImportOptions = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Importar") {
                    appState.confirmImport(options: ImportOptions(
                        language: language == "auto" ? nil : language,
                        diarize: diarize,
                        speakersHint: speakersMode == 0 ? nil : speakersMode
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { language = defaultLanguage }
    }
}
