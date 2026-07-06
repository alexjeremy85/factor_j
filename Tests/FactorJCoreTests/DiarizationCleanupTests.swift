import Testing

@testable import FactorJCore

@Suite struct DiarizationCleanupTests {
    private func span(_ key: String, _ start: Int, _ end: Int) -> DiarizedSpan {
        DiarizedSpan(speakerKey: key, startMs: start, endMs: end)
    }

    @Test func microSpeakerInsideAnotherTurnIsAbsorbed() {
        // B tem 2 s no meio de uma fala longa de A → vira A.
        let spans = [
            span("A", 0, 40_000),
            span("B", 41_000, 43_000),
            span("A", 44_000, 90_000),
        ]
        let cleaned = DiarizationCleanup.absorbMicroSpeakers(spans)
        #expect(Set(cleaned.map(\.speakerKey)) == ["A"])
    }

    @Test func substantiveSpeakersAreNeverTouched() {
        let spans = [
            span("A", 0, 60_000),
            span("B", 61_000, 121_000),
        ]
        let cleaned = DiarizationCleanup.absorbMicroSpeakers(spans)
        #expect(cleaned.map(\.speakerKey) == ["A", "B"])
    }

    @Test func microSpeakerFarFromEveryoneIsKept() {
        // C fala 3 s mas isolado, a 60 s de distância de todos — mantém.
        let spans = [
            span("A", 0, 60_000),
            span("C", 120_000, 123_000),
        ]
        let cleaned = DiarizationCleanup.absorbMicroSpeakers(spans)
        #expect(cleaned.map(\.speakerKey) == ["A", "C"])
    }

    @Test func allMicroSpeakersMeansNoReference() {
        // Gravação curta: todo mundo abaixo do mínimo — nada muda.
        let spans = [
            span("A", 0, 5_000),
            span("B", 6_000, 11_000),
        ]
        let cleaned = DiarizationCleanup.absorbMicroSpeakers(spans)
        #expect(cleaned.map(\.speakerKey) == ["A", "B"])
    }

    @Test func absorptionPicksNearestAnchorInTime() {
        let spans = [
            span("A", 0, 60_000),
            span("micro", 61_000, 63_000),  // 1 s de A, 37 s de B
            span("B", 100_000, 160_000),
        ]
        let cleaned = DiarizationCleanup.absorbMicroSpeakers(spans)
        #expect(cleaned[1].speakerKey == "A")
    }
}
