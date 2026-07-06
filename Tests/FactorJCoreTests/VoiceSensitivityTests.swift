import Testing

@testable import FactorJCore

@Suite struct VoiceSensitivityTests {
    @Test func thresholdsOrderedBySensitivity() {
        // Mais sensível = limiar menor = mais falantes (nos dois motores).
        #expect(VoiceSensitivity.high.standardThreshold < VoiceSensitivity.normal.standardThreshold)
        #expect(VoiceSensitivity.normal.standardThreshold < VoiceSensitivity.low.standardThreshold)
        #expect(VoiceSensitivity.high.vbxThreshold < VoiceSensitivity.normal.vbxThreshold)
        #expect(VoiceSensitivity.normal.vbxThreshold < VoiceSensitivity.low.vbxThreshold)
        // Nível padrão bate com os defaults dos motores.
        #expect(VoiceSensitivity.normal.standardThreshold == 0.7)
        #expect(VoiceSensitivity.normal.vbxThreshold == 0.6)
    }

    @Test func recordingPersistsSensitivityAndFallsBackToNormal() throws {
        let db = try AppDatabase.inMemory()
        let saved = try db.createRecording(Recording(
            title: "Teste",
            audioPath: "Audio/x.m4a",
            clusteringSensitivity: VoiceSensitivity.high.rawValue
        ))
        let id = try #require(saved.id)

        let fetched = try #require(try db.fetchRecording(id: id))
        #expect(fetched.voiceSensitivity == .high)

        // Sem valor gravado (nil) ou com valor desconhecido → padrão.
        let plain = try db.createRecording(Recording(title: "T2", audioPath: "Audio/y.m4a"))
        #expect(plain.voiceSensitivity == .normal)
        var corrupted = plain
        corrupted.clusteringSensitivity = "banana"
        #expect(corrupted.voiceSensitivity == .normal)
    }
}
