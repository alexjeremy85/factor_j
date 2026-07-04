import AVFoundation
import Foundation
import Testing

@testable import FactorJCore

@Suite final class AudioFileMergerTests {
    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("factorj-merger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Gera um caf mono com tom senoidal (escopo próprio fecha o arquivo).
    private func makeMonoTone(name: String, seconds: Double, sampleRate: Double) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
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
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] =
                sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
        }
        try file.write(from: buffer)
        return url
    }

    @Test func mergeTwoSourcesProducesStereoLeftMicRightSystem() throws {
        // Mic mais curto (1 s @ 44,1 kHz) e sistema mais longo (2 s @ 48 kHz):
        // exercita resample e padding do canal mais curto.
        let mic = try makeMonoTone(name: "mic.caf", seconds: 1.0, sampleRate: 44_100)
        let system = try makeMonoTone(name: "system.caf", seconds: 2.0, sampleRate: 48_000)
        let output = tempDir.appendingPathComponent("merged.caf")

        try AudioFileMerger.merge(micURL: mic, systemURL: system, output: output)

        let merged = try AVAudioFile(forReading: output)
        #expect(merged.processingFormat.channelCount == 2)
        #expect(merged.processingFormat.sampleRate == 48_000)
        // Duração = fonte mais longa (~2 s).
        #expect(abs(Double(merged.length) / 48_000 - 2.0) < 0.15)

        // Lê um trecho após 1,2 s: mic (L) deve estar em silêncio (padding),
        // sistema (R) ainda com tom.
        merged.framePosition = Int64(1.5 * 48_000)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: merged.processingFormat,
            frameCapacity: 9600
        )!
        try merged.read(into: buffer, frameCount: 9600)
        let left = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let right = UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength))
        let leftPeak = left.map { abs($0) }.max() ?? 0
        let rightPeak = right.map { abs($0) }.max() ?? 0
        #expect(leftPeak < 0.01)
        #expect(rightPeak > 0.1)
    }

    @Test func mergeSingleSourceProducesMonoAtTargetRate() throws {
        let mic = try makeMonoTone(name: "solo.caf", seconds: 1.0, sampleRate: 44_100)
        let output = tempDir.appendingPathComponent("solo-out.caf")

        try AudioFileMerger.merge(micURL: mic, systemURL: nil, output: output)

        let merged = try AVAudioFile(forReading: output)
        #expect(merged.processingFormat.channelCount == 1)
        #expect(merged.processingFormat.sampleRate == 48_000)
        #expect(abs(Double(merged.length) / 48_000 - 1.0) < 0.1)
    }

    @Test func mergeWithoutSourcesThrows() {
        let output = tempDir.appendingPathComponent("none.caf")
        #expect(throws: (any Error).self) {
            try AudioFileMerger.merge(micURL: nil, systemURL: nil, output: output)
        }
    }
}
