import FactorJCore
import SwiftUI

/// Bloco de um turno de fala (§7.3): avatar/cor, nome renomeável, timestamp
/// clicável, texto editável (duplo clique) e reatribuição via menu de contexto.
struct SegmentRow: View {
    let segment: Segment
    let speaker: Speaker?
    let isCurrent: Bool
    @ObservedObject var model: RecordingDetailModel
    let onSeek: (Int) -> Void

    @State private var isEditing = false
    @State private var editedText = ""
    @State private var showRenamePopover = false
    @State private var renameText = ""
    @State private var showNewSpeakerAlert = false
    @State private var newSpeakerName = ""

    private var speakerName: String {
        speaker?.resolvedName ?? "Falante desconhecido"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button {
                        renameText = speaker?.displayName ?? ""
                        showRenamePopover = true
                    } label: {
                        Text(speakerName)
                            .fontWeight(.semibold)
                            .foregroundStyle(SpeakerPalette.color(for: speaker))
                    }
                    .buttonStyle(.plain)
                    .disabled(speaker == nil)
                    .popover(isPresented: $showRenamePopover) { renamePopover }

                    Button {
                        onSeek(segment.startMs)
                    } label: {
                        Text(TimeFormat.display(ms: segment.startMs))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reproduzir a partir daqui")

                    if segment.isOverlap {
                        Image(systemName: "person.2.wave.2")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Falas sobrepostas neste trecho")
                    }
                    if segment.isEdited {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Texto editado manualmente")
                    }
                }

                if isEditing {
                    editView
                } else {
                    Text(segment.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture(count: 2) { startEditing() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            isCurrent ? SpeakerPalette.color(for: speaker).opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contextMenu { contextMenu }
        .alert("Novo falante", isPresented: $showNewSpeakerAlert) {
            TextField("Nome", text: $newSpeakerName)
            Button("Cancelar", role: .cancel) {}
            Button("Criar e atribuir") {
                let name = newSpeakerName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    model.reassignToNewSpeaker(segment, name: name)
                }
                newSpeakerName = ""
            }
        }
    }

    private var avatar: some View {
        Circle()
            .fill(SpeakerPalette.color(for: speaker).opacity(0.85))
            .frame(width: 30, height: 30)
            .overlay {
                Text(SpeakerPalette.initials(speakerName))
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
            }
    }

    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Renomear falante")
                .font(.headline)
            TextField("Nome (ex.: Fulano)", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(commitRename)
            HStack {
                Spacer()
                Button("OK", action: commitRename)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private var editView: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $editedText)
                .font(.body)
                .frame(minHeight: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.4))
                )
            HStack {
                Button("Cancelar") { isEditing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar") {
                    model.updateText(segment, text: editedText)
                    isEditing = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Reproduzir a partir daqui") { onSeek(segment.startMs) }
        Button("Editar texto") { startEditing() }
        Menu("Atribuir a…") {
            ForEach(model.speakers) { candidate in
                Button {
                    model.reassign(segment, to: candidate)
                } label: {
                    if candidate.id == segment.speakerId {
                        Label(candidate.resolvedName, systemImage: "checkmark")
                    } else {
                        Text(candidate.resolvedName)
                    }
                }
            }
            Divider()
            Button("Novo falante…") { showNewSpeakerAlert = true }
        }
    }

    private func startEditing() {
        editedText = segment.text
        isEditing = true
    }

    private func commitRename() {
        if let speaker {
            model.renameSpeaker(speaker, to: renameText)
        }
        showRenamePopover = false
    }
}
