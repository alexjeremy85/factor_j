import AVFoundation
import CoreAudio
import Foundation

/// Captura o áudio do sistema (Teams/Zoom/Meet/qualquer app) via
/// **Core Audio Process Taps** (macOS 14.4+, RF-G2) — sem drivers virtuais.
///
/// Fluxo: CATapDescription global → AudioHardwareCreateProcessTap →
/// aggregate device privado com o tap → IOProc lê os buffers → .caf.
/// A primeira criação do tap dispara o pedido de permissão
/// "Gravação de Áudio do Sistema" do macOS.
public final class SystemAudioTap {
    public enum TapError: LocalizedError {
        case creationFailed(OSStatus)
        case aggregateFailed(OSStatus)
        case formatUnavailable(OSStatus)
        case ioProcFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .creationFailed(let status):
                return "Sem acesso ao áudio do sistema (erro \(status)). Autorize em Ajustes do Sistema → Privacidade e Segurança → Gravação de Áudio do Sistema."
            case .aggregateFailed(let status):
                return "Falha ao criar dispositivo de captura (erro \(status))."
            case .formatUnavailable(let status):
                return "Formato do áudio do sistema indisponível (erro \(status))."
            case .ioProcFailed(let status):
                return "Falha ao iniciar a captura do sistema (erro \(status))."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "com.factorj.systemtap")
    private let onLevel: (Float) -> Void

    public var isPaused = false

    public init(onLevel: @escaping (Float) -> Void = { _ in }) {
        self.onLevel = onLevel
    }

    public func start(writingTo url: URL) throws {
        // 1. Tap global (mixdown estéreo de todos os processos).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Factor J — captura de reunião"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw TapError.creationFailed(status)
        }

        // 2. Formato entregue pelo tap.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr,
              let tapFormat = AVAudioFormat(streamDescription: &asbd)
        else {
            cleanup()
            throw TapError.formatUnavailable(status)
        }

        // 3. Aggregate device privado contendo só o tap.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Factor J Tap",
            kAudioAggregateDeviceUIDKey: "com.factorj.tap." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateID
        )
        guard status == noErr else {
            cleanup()
            throw TapError.aggregateFailed(status)
        }

        // 4. Arquivo de destino (mono 16-bit; downmix na escrita).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: tapFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // 5. IOProc: recebe os buffers do tap.
        //
        // ATENÇÃO ao layout: o tap costuma entregar PCM Float32
        // INTERCALADO (L/R alternados num único buffer). Ler intercalado
        // como se fosse por-canal embaralha as amostras no tempo e produz
        // áudio "robotizado". Tratamos os dois layouts explicitamente.
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard asbd.mFormatID == kAudioFormatLinearPCM, isFloat else {
            cleanup()
            throw TapError.formatUnavailable(-1)
        }
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let channels = max(Int(tapFormat.channelCount), 1)

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, !self.isPaused, let file = self.file else { return }
            let bufferList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard bufferList.count > 0 else { return }

            let frames: Int
            if isInterleaved {
                frames = Int(bufferList[0].mDataByteSize)
                    / (MemoryLayout<Float>.size * channels)
            } else {
                frames = Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
            }
            guard frames > 0,
                  let mono = AVAudioPCMBuffer(
                      pcmFormat: monoFormat,
                      frameCapacity: AVAudioFrameCount(frames)
                  ),
                  let dst = mono.floatChannelData?[0]
            else { return }
            mono.frameLength = AVAudioFrameCount(frames)

            if isInterleaved {
                guard let data = bufferList[0].mData?
                    .assumingMemoryBound(to: Float.self) else { return }
                for i in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += data[i * channels + ch] }
                    dst[i] = sum / Float(channels)
                }
            } else {
                for i in 0..<frames { dst[i] = 0 }
                var mixed = 0
                for buffer in bufferList {
                    guard let data = buffer.mData?
                        .assumingMemoryBound(to: Float.self) else { continue }
                    let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                    for i in 0..<count { dst[i] += data[i] }
                    mixed += 1
                }
                if mixed > 1 {
                    for i in 0..<frames { dst[i] /= Float(mixed) }
                }
            }

            do {
                try file.write(from: mono)
                self.onLevel(MicRecorder.rms(mono))
            } catch {
                // Nunca derrubar o thread de áudio por erro de escrita.
            }
        }
        guard status == noErr, ioProcID != nil else {
            cleanup()
            throw TapError.ioProcFailed(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanup()
            throw TapError.ioProcFailed(status)
        }
    }

    public func stop() {
        cleanup()
    }

    private func cleanup() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        file = nil
    }
}
