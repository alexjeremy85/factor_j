import AVFoundation
import Foundation

/// Combina as duas fontes gravadas (mic e sistema) em um único arquivo
/// estéreo: **mic no canal esquerdo, sistema no direito** (RF-G3).
/// Leitura/escrita em chunks — memória estável para gravações longas.
public enum AudioFileMerger {
    static let targetRate = 48_000.0
    static let chunkFrames: AVAudioFrameCount = 48_000  // 1 s

    /// Converte um arquivo para mono Float32 na taxa alvo, em streaming.
    private static func normalize(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let monoTarget = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let converter = AVAudioConverter(from: input.processingFormat, to: monoTarget) else {
            throw PipelineError.audioReadFailed("conversor indisponível")
        }

        var reachedEnd = false
        while !reachedEnd {
            let outBuffer = AVAudioPCMBuffer(pcmFormat: monoTarget, frameCapacity: chunkFrames)!
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { requested, outStatus in
                let inBuffer = AVAudioPCMBuffer(
                    pcmFormat: input.processingFormat,
                    frameCapacity: requested
                )!
                do {
                    try input.read(into: inBuffer, frameCount: requested)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let conversionError {
                throw PipelineError.audioReadFailed(conversionError.localizedDescription)
            }
            if outBuffer.frameLength > 0 {
                try output.write(from: outBuffer)
            }
            reachedEnd = (status == .endOfStream) || (status == .error) || outBuffer.frameLength == 0
        }
    }

    /// Junta mic (L) e sistema (R) em um caf estéreo. Qualquer um dos dois
    /// pode faltar (gravação de uma fonte só): o canal ausente fica em
    /// silêncio quando há as duas fontes, ou o resultado sai mono.
    public static func merge(
        micURL: URL?,
        systemURL: URL?,
        output: URL
    ) throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        let sources = [micURL, systemURL].compactMap { $0 }
        guard !sources.isEmpty else {
            throw PipelineError.audioReadFailed("nenhuma fonte gravada")
        }

        // Uma fonte só: normaliza direto para o destino (mono).
        if sources.count == 1 {
            try? fm.removeItem(at: output)
            try normalize(sources[0], to: output)
            return
        }

        // Duas fontes: normaliza cada uma e intercala L/R.
        let micNorm = temp.appendingPathComponent("factorj-mic-\(UUID().uuidString).caf")
        let sysNorm = temp.appendingPathComponent("factorj-sys-\(UUID().uuidString).caf")
        defer {
            try? fm.removeItem(at: micNorm)
            try? fm.removeItem(at: sysNorm)
        }
        try normalize(micURL!, to: micNorm)
        try normalize(systemURL!, to: sysNorm)

        let mic = try AVAudioFile(forReading: micNorm)
        let sys = try AVAudioFile(forReading: sysNorm)
        let stereo = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 2,
            interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        try? fm.removeItem(at: output)
        let out = try AVAudioFile(
            forWriting: output,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let totalFrames = max(mic.length, sys.length)
        var written: Int64 = 0
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        )!

        func readChunk(_ file: AVAudioFile) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkFrames)!
            try? file.read(into: buffer, frameCount: chunkFrames)
            return buffer
        }

        while written < totalFrames {
            let micChunk = readChunk(mic)
            let sysChunk = readChunk(sys)
            let frames = max(micChunk.frameLength, sysChunk.frameLength)
            guard frames > 0 else { break }

            let outBuffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: frames)!
            outBuffer.frameLength = frames
            let left = outBuffer.floatChannelData![0]
            let right = outBuffer.floatChannelData![1]
            for i in 0..<Int(frames) {
                left[i] = i < Int(micChunk.frameLength)
                    ? micChunk.floatChannelData![0][i] : 0
                right[i] = i < Int(sysChunk.frameLength)
                    ? sysChunk.floatChannelData![0][i] : 0
            }
            try out.write(from: outBuffer)
            written += Int64(frames)
        }
    }
}
