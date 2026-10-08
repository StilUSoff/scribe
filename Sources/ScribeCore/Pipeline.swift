import Foundation

/// Звук → куски по паузам → текст. Куски распознаются по одному, пока звук ещё идёт,
/// поэтому после «стоп» остаётся дождаться только последнего куска.
/// Текст после каждого куска дописывается в файл: при сбое уже распознанное не теряется.
public final class TranscriptionPipeline: @unchecked Sendable {
    /// Сколько звука уже обработано и с какой скоростью модель его распознаёт.
    public struct Progress: Sendable {
        /// Секунд звука, по которые уже есть текст.
        public let doneSeconds: Double
        /// Секунд речи за секунду работы модели (в среднем за запись); nil, пока не распознан ни один кусок.
        public let speed: Double?

        public init(doneSeconds: Double, speed: Double?) {
            self.doneSeconds = doneSeconds
            self.speed = speed
        }

        /// Примерно сколько секунд осталось, чтобы распознать звук до отметки totalSeconds.
        public func remaining(until totalSeconds: Double) -> Double? {
            guard let speed, speed > 0 else { return nil }
            return max(totalSeconds - doneSeconds, 0) / speed
        }
    }

    private let continuation: AsyncStream<[Float]>.Continuation
    private let task: Task<String, Never>

    /// - Parameter onChunk: вызывается после каждого куска — сколько звука обработано и текущая скорость.
    public init(transcriber: Transcriber, partialURL: URL?, chunker: SpeechChunker = SpeechChunker(),
                onChunk: (@Sendable (Progress) -> Void)? = nil) {
        var cont: AsyncStream<[Float]>.Continuation!
        let stream = AsyncStream<[Float]>(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        task = Task.detached(priority: .userInitiated) {
            await transcriber.reset()
            let writer = TranscriptWriter(url: partialURL)
            var chunker = chunker
            var speechSeconds = 0.0, busySeconds = 0.0
            var speed: Double? { busySeconds > 0 ? speechSeconds / busySeconds : nil }

            func handle(_ chunk: SpeechChunker.Chunk) async {
                if chunk.isSilent {
                    writer.paragraphBreak()
                } else {
                    let started = Date()
                    do {
                        writer.append(try await transcriber.transcribe(chunk.samples))
                        speechSeconds += chunk.durationSeconds
                        busySeconds += Date().timeIntervalSince(started)
                    } catch {
                        writer.append("[не распознано \(Self.clock(chunk.startSeconds))–\(Self.clock(chunk.startSeconds + chunk.durationSeconds))]")
                    }
                }
                onChunk?(Progress(doneSeconds: chunk.startSeconds + chunk.durationSeconds, speed: speed))
            }

            // Отмена (cancel()) срабатывает между кусками: текущий кусок дорасшифровывается, остальные — нет.
            for await samples in stream {
                for chunk in chunker.append(samples) where !Task.isCancelled { await handle(chunk) }
                if Task.isCancelled { break }
            }
            if !Task.isCancelled, let tail = chunker.flush() { await handle(tail) }
            return writer.text
        }
    }

    /// Подать очередную порцию звука (моно 16 кГц). Можно звать с любого потока.
    public func feed(_ samples: [Float]) {
        continuation.yield(samples)
    }

    /// Звук закончился: дождаться распознавания остатка и получить весь текст.
    public func finish() async -> String {
        continuation.finish()
        return await task.value
    }

    /// Прервать распознавание: finish() вернёт то, что успели распознать (в течение одного куска, ~2 с).
    public func cancel() {
        continuation.finish()
        task.cancel()
    }

    /// Прогнать целый файл (тот же конвейер, что и для микрофона).
    public static func transcribeFile(_ url: URL, transcriber: Transcriber, chunker: SpeechChunker = SpeechChunker(),
                                      progress: (@Sendable (_ fraction: Double, _ remaining: Double?) -> Void)? = nil)
        async throws -> String {
        let audio = try AudioIO.loadMono16k(url)
        let total = max(Double(audio.count) / AudioIO.sampleRate, 0.001)
        let started = Date()
        let pipeline = TranscriptionPipeline(transcriber: transcriber, partialURL: nil, chunker: chunker) { p in
            // Файл подаётся целиком сразу, модель занята без перерывов — честнее всего фактический темп.
            let elapsed = Date().timeIntervalSince(started)
            // Первые куски нерепрезентативны (оценка выходит вдвое меньше) — до 10% честнее «считаю…».
            let remaining = p.doneSeconds / total >= 0.1 && elapsed > 0
                ? max(total - p.doneSeconds, 0) * elapsed / p.doneSeconds : nil
            progress?(min(p.doneSeconds / total, 1), remaining)
        }
        let second = Int(AudioIO.sampleRate)
        for start in stride(from: 0, to: audio.count, by: second) {
            pipeline.feed(Array(audio[start..<min(start + second, audio.count)]))
        }
        let text = await withTaskCancellationHandler {
            await pipeline.finish()
        } onCancel: {
            pipeline.cancel()
        }
        try Task.checkCancellation()  // отменили — бросаем CancellationError, недорасшифрованный текст не нужен
        return text
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Собирает текст по абзацам (абзац — после длинной паузы) и дописывает его в файл по мере поступления.
final class TranscriptWriter {
    private var paragraphs: [String] = [""]
    private let handle: FileHandle?

    init(url: URL?) {
        if let url {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        } else {
            handle = nil
        }
    }

    deinit { try? handle?.close() }

    var text: String {
        paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func append(_ piece: String) {
        guard !piece.isEmpty else { return }
        let last = paragraphs.count - 1
        let separator = paragraphs[last].isEmpty ? "" : " "
        paragraphs[last] += separator + piece
        write(separator + piece)
    }

    func paragraphBreak() {
        guard !(paragraphs.last ?? "").isEmpty else { return }
        paragraphs.append("")
        write("\n\n")
    }

    private func write(_ s: String) {
        guard let handle, let data = s.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
        try? handle.synchronize()
    }
}
