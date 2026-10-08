import XCTest
@testable import ScribeCore

final class SpeechChunkerTests: XCTestCase {
    let sr = Int(AudioIO.sampleRate)

    /// «Речь» — тон, нарезанный на слоги по ~200 мс с короткими провалами между ними; «тишина» — слабый шум.
    func speech(_ seconds: Double, amp: Float = 0.003) -> [Float] {
        (0..<Int(seconds * Double(sr))).map { i in
            let inSyllable = (i / (sr / 50)) % 10 < 8  // 160 мс звука, 40 мс провал
            return (inSyllable ? amp : amp * 0.05) * sin(Float(i) * 0.07) + Float.random(in: -0.00005...0.00005)
        }
    }

    func silence(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(sr))).map { _ in Float.random(in: -0.00005...0.00005) }
    }

    func feed(_ audio: [Float], into chunker: inout SpeechChunker) -> [SpeechChunker.Chunk] {
        var out: [SpeechChunker.Chunk] = []
        for start in stride(from: 0, to: audio.count, by: sr) {
            out += chunker.append(Array(audio[start..<min(start + sr, audio.count)]))
        }
        if let tail = chunker.flush() { out.append(tail) }
        return out
    }

    func testCutsAtPauseAfterMinimum() {
        // 5 с речи, пауза 1 с (до минимума — не режем), 10 с речи, пауза 1 с (после минимума — режем), 8 с речи.
        let audio = speech(5) + silence(1) + speech(10) + silence(1) + speech(8)
        var chunker = SpeechChunker()
        let chunks = feed(audio, into: &chunker)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].durationSeconds, 16.5, accuracy: 0.6)  // режем посреди второй паузы
        XCTAssertEqual(chunks.map(\.samples.count).reduce(0, +), audio.count, "звук не теряется и не дублируется")
        XCTAssertFalse(chunks.contains(where: \.isSilent))
    }

    func testHardCutWithoutPauses() {
        let audio = speech(70)
        var chunker = SpeechChunker()
        let chunks = feed(audio, into: &chunker)
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.durationSeconds <= chunker.maxSeconds + 0.1 })
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.durationSeconds >= chunker.minSeconds })
        XCTAssertEqual(chunks.map(\.samples.count).reduce(0, +), audio.count)
    }

    func testQuietRecordingIsStillSpeech() {
        // Как в реальных записях Handy: речь на уровне ~0.002 RMS при пике −24 дБ.
        let audio = speech(15, amp: 0.002) + silence(1) + speech(5, amp: 0.002)
        var chunker = SpeechChunker()
        let chunks = feed(audio, into: &chunker)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertFalse(chunks.contains(where: \.isSilent))
    }

    func testLongMonologueStaysSpeech() {
        // Сначала тишина задаёт фон, потом 2 минуты речи без пауз — ни один кусок не должен стать «тишиной».
        let audio = silence(3) + speech(120)
        var chunker = SpeechChunker()
        let chunks = feed(audio, into: &chunker)
        XCTAssertGreaterThanOrEqual(chunks.count, 4)
        XCTAssertFalse(chunks.dropFirst().contains(where: \.isSilent))
    }

    func testLongSilenceIsMarkedSilent() {
        let audio = speech(13) + silence(40) + speech(13)
        var chunker = SpeechChunker()
        let chunks = feed(audio, into: &chunker)
        XCTAssertTrue(chunks.contains(where: \.isSilent))
        XCTAssertEqual(chunks.filter { !$0.isSilent }.count, 2)
    }

    func testWriterParagraphsAndFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let writer = TranscriptWriter(url: url)
        writer.paragraphBreak()  // в начале — ничего
        writer.append("Привет.")
        writer.append("Как дела?")
        writer.paragraphBreak()
        writer.paragraphBreak()  // двойной разрыв схлопывается
        writer.append("Хорошо.")
        XCTAssertEqual(writer.text, "Привет. Как дела?\n\nХорошо.")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Привет. Как дела?\n\nХорошо.")
    }

    func testNormalizationBoostsQuietAudioOnly() {
        let quiet: [Float] = [0.01, -0.02]
        XCTAssertEqual(Transcriber.normalized(quiet).map { abs($0) }.max()!, 0.5, accuracy: 0.001)
        let loud: [Float] = [0.9, -0.3]
        XCTAssertEqual(Transcriber.normalized(loud), loud)
        let nearSilence: [Float] = [0.0001]
        XCTAssertEqual(Transcriber.normalized(nearSilence)[0], 0.003, accuracy: 0.0001, "усиление не больше 30×")
    }
}

final class ProgressTests: XCTestCase {
    func testRemainingUsesSpeed() {
        let p = TranscriptionPipeline.Progress(doneSeconds: 60, speed: 6)
        XCTAssertEqual(p.remaining(until: 120)!, 10, accuracy: 0.001)  // 60 с звука при 6× → 10 с
        XCTAssertEqual(p.remaining(until: 30)!, 0)                      // уже всё обработано
        XCTAssertNil(TranscriptionPipeline.Progress(doneSeconds: 0, speed: nil).remaining(until: 100))
    }
}
