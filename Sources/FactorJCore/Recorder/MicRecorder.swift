import AVFoundation
import Foundation

/// Captura do microfone via AVAudioEngine (RF-G1), gravando incrementalmente
/// em um arquivo .caf no formato nativo do dispositivo de entrada.
public final class MicRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let onLevel: (Float) -> Void

    /// Pausa: buffers são descartados sem parar o hardware.
    public var isPaused = false

    public init(onLevel: @escaping (Float) -> Void = { _ in }) {
        self.onLevel = onLevel
    }

    /// Pede permissão de microfone se necessário.
    /// - Returns: false se o usuário negou (RF-G5).
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    public func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PipelineError.audioReadFailed("microfone indisponível")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // Downmix para mono na escrita quando a entrada for multicanal.
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let converter = format.channelCount == 1 ? nil : AVAudioConverter(from: format, to: monoFormat)

        input.installTap(onBus: 0, bufferSize: 4800, format: format) { [weak self] buffer, _ in
            guard let self, !self.isPaused, let file = self.file else { return }
            do {
                if let converter {
                    let frames = AVAudioFrameCount(buffer.frameLength)
                    guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames)
                    else { return }
                    var consumed = false
                    converter.convert(to: mono, error: nil) { _, status in
                        if consumed {
                            status.pointee = .noDataNow
                            return nil
                        }
                        consumed = true
                        status.pointee = .haveData
                        return buffer
                    }
                    try file.write(from: mono)
                    self.onLevel(Self.rms(mono))
                } else {
                    try file.write(from: buffer)
                    self.onLevel(Self.rms(buffer))
                }
            } catch {
                // Falha de escrita não pode derrubar o thread de áudio;
                // o merge final detecta arquivo curto.
            }
        }

        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil  // fecha o arquivo (flush no deinit do AVAudioFile)
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let count = Int(buffer.frameLength)
        for i in 0..<count { sum += data[i] * data[i] }
        return min(sqrt(sum / Float(count)) * 3, 1)  // ganho p/ VU visível
    }
}
