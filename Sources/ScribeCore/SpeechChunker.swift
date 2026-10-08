import Foundation

/// Режет непрерывный поток звука (моно 16 кГц) на куски по паузам в речи.
///
/// Whisper работает окнами по 30 с, поэтому кусок — от `minSeconds` до `maxSeconds`: режем в ближайшей паузе
/// после `minSeconds`, а если паузы нет — в самом тихом месте последних секунд перед `maxSeconds`.
/// Куски почти без речи помечаются `isSilent`, их не надо отдавать модели (на тишине Whisper «галлюцинирует»).
public struct SpeechChunker {
    public struct Chunk: Sendable {
        public let startSample: Int
        public let samples: [Float]
        public let isSilent: Bool
        public var startSeconds: Double { Double(startSample) / AudioIO.sampleRate }
        public var durationSeconds: Double { Double(samples.count) / AudioIO.sampleRate }
    }

    public var minSeconds = 12.0
    public var maxSeconds = 28.0
    public var pauseSeconds = 0.35
    /// Доля «речевых» кадров, ниже которой кусок считается тишиной.
    public var minSpeechRatio = 0.04

    private let frame = 480  // 30 мс
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var frameRMS: [Float] = []  // по кадрам текущего буфера
    /// Последние ~20 с уровней кадров — по ним считается фон (записи бывают очень тихими, абсолютный порог не годится).
    private var recentRMS: [Float] = []
    private var noiseFloor: Float = 0.0003

    public init() {}

    /// Добавляет звук; возвращает куски, которые уже можно распознавать.
    public mutating func append(_ samples: [Float]) -> [Chunk] {
        buffer += samples
        while frameRMS.count * frame + frame <= buffer.count {
            let start = frameRMS.count * frame
            var sum: Float = 0
            for i in start..<(start + frame) { sum += buffer[i] * buffer[i] }
            let rms = (sum / Float(frame)).squareRoot()
            frameRMS.append(rms)
            recentRMS.append(rms)
            if recentRMS.count > 667 { recentRMS.removeFirst(recentRMS.count - 667) }
            if frameRMS.count % 33 == 0 {
                // Фон — 15-й перцентиль уровней за последние ~20 с, пересчитываем раз в секунду.
                // Опускается сразу, а растёт не быстрее 2% в секунду: иначе за долгий монолог без пауз
                // «фоном» станет сама речь и её примут за тишину.
                let sorted = recentRMS.sorted()
                noiseFloor = min(sorted[sorted.count * 15 / 100], noiseFloor * 1.02)
            }
        }
        var ready: [Chunk] = []
        while let cut = findCut() {
            ready.append(takeChunk(frames: cut))
        }
        return ready
    }

    /// Отдаёт остаток (конец записи).
    public mutating func flush() -> Chunk? {
        guard !buffer.isEmpty else { return nil }
        let speech = speechRatio(frameRMS[...])
        let chunk = Chunk(startSample: bufferStart, samples: buffer, isSilent: speech < minSpeechRatio || buffer.count < frame * 10)
        bufferStart += buffer.count
        buffer.removeAll()
        frameRMS.removeAll()
        return chunk
    }

    private var threshold: Float { max(0.00025, noiseFloor * 3) }

    private func isSpeech(_ rms: Float) -> Bool { rms > threshold }

    private func speechRatio(_ frames: ArraySlice<Float>) -> Double {
        guard !frames.isEmpty else { return 0 }
        return Double(frames.filter(isSpeech).count) / Double(frames.count)
    }

    /// Номер кадра, по который отрезать кусок, или nil, если ещё рано.
    private func findCut() -> Int? {
        let fps = AudioIO.sampleRate / Double(frame)
        let minF = Int(minSeconds * fps), maxF = Int(maxSeconds * fps), pauseF = Int(pauseSeconds * fps)
        guard frameRMS.count > minF else { return nil }

        // Первая пауза длиной pauseF после minF — режем посередине неё.
        var run = 0
        for i in minF..<min(frameRMS.count, maxF) {
            if isSpeech(frameRMS[i]) {
                run = 0
            } else {
                run += 1
                if run >= pauseF { return i - run / 2 }
            }
        }
        guard frameRMS.count >= maxF else { return nil }
        // Паузы нет: самый тихий кадр в последних 6 секундах перед maxF.
        let from = max(minF, maxF - Int(6 * fps))
        let quietest = (from..<maxF).min { frameRMS[$0] < frameRMS[$1] } ?? maxF
        return quietest
    }

    private mutating func takeChunk(frames: Int) -> Chunk {
        let count = frames * frame
        let chunk = Chunk(
            startSample: bufferStart,
            samples: Array(buffer[..<count]),
            isSilent: speechRatio(frameRMS[..<frames]) < minSpeechRatio
        )
        buffer.removeFirst(count)
        frameRMS.removeFirst(frames)
        bufferStart += count
        return chunk
    }
}
