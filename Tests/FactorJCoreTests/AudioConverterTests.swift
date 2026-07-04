import AVFoundation
import Foundation
import Testing

@testable import FactorJCore

@Suite final class AudioConverterTests {
    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("escriba-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Gera um WAV estéreo 44,1 kHz com um tom de 440 Hz.
    private func makeStereoWav(seconds: Double) throws -> URL {
        let url = tempDir.appendingPathComponent("tone.wav")
        let sampleRate = 44_100.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
            }
        }
        try file.write(from: buffer)
        return file.url
    }

    @Test func convertToWav16kMono() async throws {
        let source = try makeStereoWav(seconds: 2.0)
        let destination = tempDir.appendingPathComponent("out.wav")

        let duration = try await AudioConverter.convertToWav16k(
            source: source,
            destination: destination
        )

        #expect(abs(duration - 2.0) < 0.1)

        let converted = try AVAudioFile(forReading: destination)
        #expect(converted.processingFormat.sampleRate == 16_000)
        #expect(converted.processingFormat.channelCount == 1)
        #expect(abs(Double(converted.length) / 16_000 - 2.0) < 0.1)
    }

    @Test func wavWindowReaderReadsWindows() async throws {
        let source = try makeStereoWav(seconds: 2.0)
        let destination = tempDir.appendingPathComponent("out.wav")
        try await AudioConverter.convertToWav16k(source: source, destination: destination)

        let reader = try WavWindowReader(url: destination)
        #expect(abs(reader.durationSeconds - 2.0) < 0.1)

        let firstHalf = try reader.read(startFrame: 0, frameCount: 16_000)
        #expect(firstHalf.count == 16_000)
        // O tom de 440 Hz sobrevive à conversão (amostras não nulas).
        #expect((firstHalf.map { abs($0) }.max() ?? 0) > 0.1)

        // Leitura além do fim é truncada sem erro.
        let tail = try reader.read(startFrame: reader.totalFrames - 100, frameCount: 16_000)
        #expect(tail.count == 100)
        #expect(try reader.read(startFrame: reader.totalFrames, frameCount: 100).isEmpty)
    }

    /// Escreve o WAV num escopo próprio para o AVAudioFile fechar (deinit)
    /// antes da leitura.
    private func makeGapWav() throws -> URL {
        // 1 s de tom + 0,5 s de silêncio + 1 s de tom.
        let url = tempDir.appendingPathComponent("gap.wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let total = 40_000  // 2,5 s
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        for i in 0..<total {
            let inGap = i >= 16_000 && i < 24_000
            buffer.floatChannelData![0][i] = inGap
                ? 0
                : sinf(2 * .pi * 440 * Float(i) / 16_000) * 0.5
        }
        try file.write(from: buffer)
        return url
    }

    @Test func quietestFrameFindsSilence() throws {
        let url = try makeGapWav()
        let reader = try WavWindowReader(url: url)
        // Procurando perto do fim (2,5 s) com lookback de 2,5 s, deve achar o gap.
        let cut = try reader.quietestFrame(near: reader.totalFrames, lookbackSeconds: 2.5)
        #expect(cut >= 15_500)
        #expect(cut <= 24_500)
    }
}
