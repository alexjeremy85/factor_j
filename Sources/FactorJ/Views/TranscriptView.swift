import AppKit
import FactorJCore
import SwiftUI
import UniformTypeIdentifiers

/// Tela de transcrição (§7.3): player, timeline de falantes, blocos por
/// turno com sincronia bidirecional, edição e exportação.
struct TranscriptView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: RecordingDetailModel
    let recording: Recording

    @StateObject private var player = PlayerController()
    @State private var autoScroll = true
    @State private var showSpeakersSheet = false

    var body: some View {
        VStack(spacing: 0) {
            PlayerBar(player: player)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            SpeakerTimelineView(
                segments: model.segments,
                speakersById: model.speakersById,
                markers: model.markers,
                durationMs: player.durationMs,
                currentMs: player.currentMs
            ) { ms in
                player.seek(toMs: ms)
            }
            .frame(height: 26)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            transcriptList
        }
        .navigationTitle(recording.title)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSpeakersSheet) {
            SpeakersSheet(model: model)
        }
        .onAppear {
            let url = appState.dataStore.absoluteURL(for: recording.audioPath)
            player.load(
                url: url,
                fallbackDurationMs: Int(recording.duration * 1000)
            )
            consumePendingSeek()
        }
        .onDisappear { player.unload() }
        .onChange(of: appState.pendingSeek) { _, _ in
            consumePendingSeek()
        }
    }

    // MARK: - Lista de blocos

    private var currentSegmentId: Int64? {
        model.segments.last {
            $0.startMs <= player.currentMs && player.currentMs < $0.endMs
        }?.id
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.segments) { segment in
                        SegmentRow(
                            segment: segment,
                            speaker: segment.speakerId.flatMap { model.speakersById[$0] },
                            isCurrent: segment.id == currentSegmentId,
                            model: model
                        ) { ms in
                            player.seek(toMs: ms)
                        }
                        .id(segment.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: currentSegmentId) { _, newValue in
                guard autoScroll, player.isPlaying, let newValue else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onChange(of: appState.pendingSeek) { _, seek in
                guard let seek, seek.recordingId == model.recordingId,
                      let segmentId = seek.segmentId else { return }
                proxy.scrollTo(segmentId, anchor: .center)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: $autoScroll) {
                Label("Rolagem automática", systemImage: "arrow.down.to.line")
            }
            .help("Rolar automaticamente durante a reprodução")

            Button {
                showSpeakersSheet = true
            } label: {
                Label("Falantes", systemImage: "person.2")
            }
            .help("Renomear ou mesclar falantes")

            Button {
                appState.reprocessTarget = recording
            } label: {
                Label("Reprocessar", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Gerar a transcrição de novo com outras opções (idioma, falantes…)")

            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.displayName) { export(format) }
                }
                Divider()
                Button("Copiar transcrição") { copyTranscript() }
            } label: {
                Label("Exportar", systemImage: "square.and.arrow.up")
            }
        }
    }

    // MARK: - Ações

    private func consumePendingSeek() {
        guard let seek = appState.pendingSeek,
              seek.recordingId == model.recordingId else { return }
        player.seek(toMs: seek.ms)
        // O scroll é feito pelo onChange do transcriptList.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if appState.pendingSeek == seek {
                appState.pendingSeek = nil
            }
        }
    }

    private func export(_ format: ExportFormat) {
        let content = Exporter.export(
            format: format,
            recording: recording,
            speakers: model.speakers,
            segments: model.segments
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = recording.title + "." + format.fileExtension
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appState.lastError = "Falha ao exportar: \(error.localizedDescription)"
        }
    }

    private func copyTranscript() {
        let text = Exporter.plainTranscript(
            speakers: model.speakers,
            segments: model.segments
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Player bar

struct PlayerBar: View {
    @ObservedObject var player: PlayerController
    @State private var isScrubbing = false
    @State private var scrubMs: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.skip(seconds: -15)
            } label: {
                Image(systemName: "gobackward.15")
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                player.skip(seconds: 15)
            } label: {
                Image(systemName: "goforward.15")
            }
            .buttonStyle(.plain)

            Text(TimeFormat.display(ms: isScrubbing ? Int(scrubMs) : player.currentMs))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 64, alignment: .trailing)

            Slider(
                value: Binding(
                    get: {
                        isScrubbing ? scrubMs : Double(min(player.currentMs, player.durationMs))
                    },
                    set: { scrubMs = $0 }
                ),
                in: 0...Double(max(player.durationMs, 1))
            ) { editing in
                if editing {
                    scrubMs = Double(player.currentMs)
                    isScrubbing = true
                } else {
                    player.seek(toMs: Int(scrubMs))
                    isScrubbing = false
                }
            }

            Text(TimeFormat.display(ms: player.durationMs))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            Menu {
                ForEach(PlayerController.availableRates, id: \.self) { rate in
                    Button {
                        player.playbackRate = rate
                    } label: {
                        if player.playbackRate == rate {
                            Label(rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(rateLabel(rate))
                        }
                    }
                }
            } label: {
                Text(rateLabel(player.playbackRate))
                    .font(.callout.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == 1.0 ? "1×" : String(format: "%g×", rate)
    }
}
