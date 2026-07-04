import AVFoundation
import Foundation

/// Conversão de qualquer mídia legível pelo AVFoundation para WAV 16 kHz
/// mono (RF-A1/RF-A2), com leitura em streaming — o áudio nunca é carregado
/// inteiro em memória (RF-A6).
public enum AudioConverter {
    public static let sampleRate = 16_000.0

    /// Extensões aceitas na importação (RF-A1).
    public static let supportedExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "caf", "mp4", "mov", "aiff", "aif", "flac",
    ]

    /// Converte `source` para WAV Int16 16 kHz mono em `destination`.
    /// - Parameter progress: fração 0…1 do arquivo convertido.
    /// - Returns: duração do áudio em segundos.
    @discardableResult
    public static func convertToWav16k(
        source: URL,
        destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Double {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw PipelineError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PipelineError.audioReadFailed("AVAssetReader recusou a trilha de áudio.")
        }
        reader.add(output)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw PipelineError.audioReadFailed("Formato PCM inválido.")
        }

        try? FileManager.default.removeItem(at: destination)
        // WAV Int16 em disco: metade do tamanho do Float32; AVAudioFile
        // converte na escrita.
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outFile = try AVAudioFile(
            forWriting: destination,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard reader.startReading() else {
            throw PipelineError.audioReadFailed(
                reader.error?.localizedDescription ?? "não foi possível iniciar a leitura"
            )
        }

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            let frameCount = byteCount / MemoryLayout<Float>.size
            guard frameCount > 0,
                  let pcmBuffer = AVAudioPCMBuffer(
                      pcmFormat: format,
                      frameCapacity: AVAudioFrameCount(frameCount)
                  )
            else { continue }

            pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
            let status = CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: pcmBuffer.floatChannelData![0]
            )
            guard status == kCMBlockBufferNoErr else {
                throw PipelineError.audioReadFailed("erro ao copiar amostras (\(status))")
            }
            try outFile.write(from: pcmBuffer)

            if duration > 0, let progress {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                if pts.isFinite { progress(min(pts / duration, 1)) }
            }
        }

        if reader.status == .cancelled { throw CancellationError() }
        guard reader.status == .completed else {
            throw PipelineError.audioReadFailed(
                reader.error?.localizedDescription ?? "leitura incompleta"
            )
        }
        progress?(1)
        return duration
    }
}

/// Leitura em janelas de um WAV já convertido para 16 kHz mono.
/// Usada pelo pipeline para processar arquivos longos com memória estável.
public final class WavWindowReader {
    private let file: AVAudioFile
    public let totalFrames: Int64
    public let sampleRate: Double

    public init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        totalFrames = file.length
        sampleRate = file.processingFormat.sampleRate
    }

    public var durationSeconds: Double {
        Double(totalFrames) / sampleRate
    }

    /// Lê `frameCount` quadros a partir de `startFrame` como Float32 mono.
    public func read(startFrame: Int64, frameCount: Int) throws -> [Float] {
        guard startFrame < totalFrames, frameCount > 0 else { return [] }
        let count = min(frameCount, Int(totalFrames - startFrame))
        file.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(count)
        ) else {
            throw PipelineError.audioReadFailed("buffer de leitura inválido")
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard let channel = buffer.floatChannelData?[0] else {
            throw PipelineError.audioReadFailed("canal de áudio ausente")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Procura, perto de `targetFrame`, o quadro de menor energia (100 ms de
    /// granularidade) para cortar janelas em silêncio e não no meio de uma
    /// palavra. Busca no intervalo [targetFrame - lookbackSeconds, targetFrame].
    public func quietestFrame(near targetFrame: Int64, lookbackSeconds: Double = 20) throws -> Int64 {
        let lookbackFrames = Int64(lookbackSeconds * sampleRate)
        let start = max(0, targetFrame - lookbackFrames)
        guard start < targetFrame, targetFrame <= totalFrames else {
            return min(targetFrame, totalFrames)
        }
        let samples = try read(startFrame: start, frameCount: Int(targetFrame - start))
        guard !samples.isEmpty else { return targetFrame }

        let frameSize = Int(sampleRate / 10)  // 100 ms
        var bestOffset = samples.count - frameSize
        var bestEnergy = Double.greatestFiniteMagnitude
        var offset = 0
        while offset + frameSize <= samples.count {
            var energy = 0.0
            for i in offset..<(offset + frameSize) {
                energy += Double(samples[i] * samples[i])
            }
            if energy < bestEnergy {
                bestEnergy = energy
                bestOffset = offset
            }
            offset += frameSize
        }
        return start + Int64(bestOffset + frameSize / 2)
    }
}
