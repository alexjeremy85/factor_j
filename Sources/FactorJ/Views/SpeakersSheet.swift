import FactorJCore
import SwiftUI

/// Gerência de falantes da gravação: renomear e mesclar (§7.3).
struct SpeakersSheet: View {
    @ObservedObject var model: RecordingDetailModel
    @Environment(\.dismiss) private var dismiss

    @State private var names: [Int64: String] = [:]
    @State private var mergeSource: Speaker?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Falantes")
                .font(.title3.bold())

            if model.speakers.isEmpty {
                Text("Nenhum falante identificado nesta gravação.")
                    .foregroundStyle(.secondary)
            }

            ForEach(model.speakers) { speaker in
                HStack(spacing: 10) {
                    Circle()
                        .fill(SpeakerPalette.color(for: speaker))
                        .frame(width: 14, height: 14)
                    Text(speaker.label)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    TextField(
                        "Falante",
                        text: Binding(
                            get: {
                                names[speaker.id ?? -1] ?? speaker.displayName ?? ""
                            },
                            set: { names[speaker.id ?? -1] = $0 }
                        ),
                        prompt: Text(speaker.resolvedName)
                    )
                    .textFieldStyle(.roundedBorder)

                    Menu {
                        ForEach(model.speakers.filter { $0.id != speaker.id }) { target in
                            Button("Mesclar com \(target.resolvedName)") {
                                model.mergeSpeaker(speaker, into: target)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.merge")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.speakers.count < 2)
                    .help("Mesclar este falante com outro (a mesma pessoa dividida em dois)")
                }
            }

            HStack {
                Spacer()
                Button("Concluir") {
                    applyNames()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func applyNames() {
        for speaker in model.speakers {
            guard let id = speaker.id, let newName = names[id] else { continue }
            if newName != (speaker.displayName ?? "") {
                model.renameSpeaker(speaker, to: newName)
            }
        }
    }
}
