import Testing

@testable import FactorJCore

@Suite struct AlignerTests {
    private func word(_ text: String, _ start: Int, _ end: Int, p: Double = 0.9) -> TranscribedWord {
        TranscribedWord(text: text, startMs: start, endMs: end, probability: p)
    }

    @Test func twoSpeakersSplitInsideOneWhisperSegment() {
        // Um único segmento do Whisper que atravessa a troca de falante.
        let transcription = [
            TranscribedSegment(
                text: "olá tudo bem sim tudo ótimo",
                startMs: 0,
                endMs: 6000,
                confidence: 0.9,
                words: [
                    word("olá", 0, 800),
                    word("tudo", 900, 1400),
                    word("bem", 1500, 2000),
                    word("sim", 3200, 3700),
                    word("tudo", 3800, 4300),
                    word("ótimo", 4400, 5000),
                ]
            )
        ]
        let diarization = [
            DiarizedSpan(speakerKey: "A", startMs: 0, endMs: 2500),
            DiarizedSpan(speakerKey: "B", startMs: 3000, endMs: 5500),
        ]

        let turns = Aligner.align(transcription: transcription, diarization: diarization)

        #expect(turns.count == 2)
        #expect(turns[0].speakerKey == "A")
        #expect(turns[0].text == "olá tudo bem")
        #expect(turns[1].speakerKey == "B")
        #expect(turns[1].text == "sim tudo ótimo")
        #expect(turns[0].endMs <= turns[1].startMs)
    }

    @Test func overlapIsFlagged() {
        let transcription = [
            TranscribedSegment(
                text: "fala cruzada",
                startMs: 0,
                endMs: 2000,
                confidence: 0.8,
                words: [
                    word("fala", 0, 900),
                    word("cruzada", 1000, 1900),
                ]
            )
        ]
        // Dois falantes ativos no mesmo intervalo.
        let diarization = [
            DiarizedSpan(speakerKey: "A", startMs: 0, endMs: 2000),
            DiarizedSpan(speakerKey: "B", startMs: 500, endMs: 2000),
        ]

        let turns = Aligner.align(transcription: transcription, diarization: diarization)

        #expect(turns.count == 1)
        #expect(turns[0].isOverlap)
    }

    @Test func withoutDiarizationEachSegmentBecomesATurn() {
        let transcription = [
            TranscribedSegment(text: "primeira frase", startMs: 0, endMs: 2000, confidence: 0.9),
            TranscribedSegment(text: "segunda frase", startMs: 2500, endMs: 4000, confidence: 0.8),
        ]

        let turns = Aligner.align(transcription: transcription, diarization: [])

        #expect(turns.count == 2)
        #expect(turns[0].speakerKey == nil)
        #expect(turns[0].text == "primeira frase")
        #expect(turns[1].confidence == 0.8)
    }

    @Test func segmentLevelFallbackAssignsBestOverlap() {
        // Sem word timestamps: segmento inteiro vai para o falante com maior interseção.
        let transcription = [
            TranscribedSegment(text: "texto sem palavras", startMs: 0, endMs: 4000, confidence: 0.9)
        ]
        let diarization = [
            DiarizedSpan(speakerKey: "A", startMs: 0, endMs: 1000),
            DiarizedSpan(speakerKey: "B", startMs: 1000, endMs: 4000),
        ]

        let turns = Aligner.align(transcription: transcription, diarization: diarization)

        #expect(turns.count == 1)
        #expect(turns[0].speakerKey == "B")
    }

    @Test func orphanWordAdoptsNearestSpeakerWithinRadius() {
        let transcription = [
            TranscribedSegment(
                text: "palavra órfã",
                startMs: 0,
                endMs: 3000,
                confidence: 0.9,
                words: [
                    word("palavra", 0, 500),
                    // Fora de qualquer trecho diarizado, mas a 300 ms do fim de A.
                    word("órfã", 1300, 1800),
                ]
            )
        ]
        let diarization = [
            DiarizedSpan(speakerKey: "A", startMs: 0, endMs: 1000)
        ]

        let turns = Aligner.align(transcription: transcription, diarization: diarization)

        #expect(turns.count == 1)
        #expect(turns[0].speakerKey == "A")
        #expect(turns[0].text == "palavra órfã")
    }

    @Test func longPauseBreaksTurnOfSameSpeaker() {
        let transcription = [
            TranscribedSegment(
                text: "antes depois",
                startMs: 0,
                endMs: 10000,
                confidence: 0.9,
                words: [
                    word("antes", 0, 500),
                    word("depois", 5000, 5500),  // pausa de 4,5 s
                ]
            )
        ]
        let diarization = [
            DiarizedSpan(speakerKey: "A", startMs: 0, endMs: 600),
            DiarizedSpan(speakerKey: "A", startMs: 4900, endMs: 5600),
        ]

        let turns = Aligner.align(transcription: transcription, diarization: diarization)

        #expect(turns.count == 2)
        #expect(turns[0].speakerKey == "A")
        #expect(turns[1].speakerKey == "A")
    }

    @Test func emptyTranscriptionYieldsNoTurns() {
        let turns = Aligner.align(
            transcription: [],
            diarization: [DiarizedSpan(speakerKey: "A", startMs: 0, endMs: 1000)]
        )
        #expect(turns.isEmpty)
    }

    @Test func confidenceIsAverageOfWordProbabilities() {
        let transcription = [
            TranscribedSegment(
                text: "a b",
                startMs: 0,
                endMs: 1000,
                confidence: 0.5,
                words: [
                    word("a", 0, 400, p: 1.0),
                    word("b", 500, 900, p: 0.5),
                ]
            )
        ]
        let diarization = [DiarizedSpan(speakerKey: "A", startMs: 0, endMs: 1000)]

        let turns = Aligner.align(transcription: transcription, diarization: diarization)

        #expect(abs((turns[0].confidence ?? 0) - 0.75) < 0.001)
    }
}
