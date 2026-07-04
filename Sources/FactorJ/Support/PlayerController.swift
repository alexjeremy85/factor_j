import AVFoundation
import Combine
import Foundation

/// Player de áudio da tela de transcrição (§7.3): play/pause, velocidade
/// 0,5×–2×, seek. Reproduz o arquivo original importado.
@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var currentMs: Int = 0
    @Published private(set) var isPlaying = false
    @Published var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying { player?.rate = playbackRate }
        }
    }
    @Published private(set) var durationMs: Int = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    static let availableRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    func load(url: URL, fallbackDurationMs: Int) {
        unload()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        durationMs = fallbackDurationMs

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if time.seconds.isFinite {
                    self.currentMs = Int(time.seconds * 1000)
                }
                self.isPlaying = (self.player?.rate ?? 0) > 0
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
            }
        }
    }

    func unload() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        currentMs = 0
        isPlaying = false
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if durationMs > 0, currentMs >= durationMs - 200 {
                player.seek(to: .zero)
            }
            player.rate = playbackRate
            isPlaying = true
        }
    }

    func seek(toMs ms: Int) {
        guard let player else { return }
        let clamped = max(0, min(ms, durationMs))
        currentMs = clamped
        player.seek(
            to: CMTime(seconds: Double(clamped) / 1000, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func skip(seconds: Double) {
        seek(toMs: currentMs + Int(seconds * 1000))
    }
}
