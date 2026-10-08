import Foundation
import WhisperKit

/// Распознавание кусков речи через WhisperKit. Один экземпляр, куски — строго по очереди.
public actor Transcriber {
    /// Полная large-v3: на 30-минутном созвоне теряет на треть меньше фраз, чем turbo, ~2.6× быстрее реального времени.
    public static let accurateModel = "openai_whisper-large-v3"
    /// large-v3-turbo: ~8× быстрее реального времени, но чаще проглатывает короткие реплики.
    public static let fastModel = "openai_whisper-large-v3-v20240930"
    public static let defaultModel = accurateModel

    public static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe/Models", isDirectory: true)
    }

    public let language: String
    /// Образец текста с пунктуацией — подсказка модели перед каждым куском. Whisper подстраивает стиль под подсказку:
    /// без неё на русском часто пишет без знаков.
    public var initialPrompt = "Привет! Давай обсудим задачи на неделю. Что у нас по срокам? Хорошо, тогда начнём."
    /// Добавлять к подсказке конец уже распознанного текста. По умолчанию выключено: стоит одному куску выйти
    /// без знаков, следующий получает подсказку без знаков, и пунктуация пропадает лавиной до конца записи
    /// (так было на 30-минутном созвоне: после 3-й минуты — ни одной точки).
    public var rollingContext = false
    /// Сколько последних символов распознанного текста подсказывать при rollingContext.
    public var contextCharacters = 220
    /// Декодировать с таймкодами: Whisper в этом режиме реже пропускает фразы.
    public var withTimestamps = false
    /// Словарь терминов: замена типичных ошибок в готовом тексте.
    public private(set) var glossary = Glossary()
    private var kit: WhisperKit?
    private var context = ""
    private var modelName = Transcriber.defaultModel
    private var modelFolder: URL?
    private var loading: Task<Void, Error>?

    /// Модель сейчас в памяти.
    public var isLoaded: Bool { kit != nil }

    public init(language: String = "ru") {
        self.language = language
    }

    public func setGlossary(_ glossary: Glossary) {
        self.glossary = glossary
    }

    public func configure(rollingContext: Bool, withTimestamps: Bool) {
        self.rollingContext = rollingContext
        self.withTimestamps = withTimestamps
    }

    /// Выбрать модель и убедиться, что она скачана (при первом выборе — скачать), но не грузить в память.
    /// Если была загружена другая модель — она выгружается.
    public func prepare(model: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if model != modelName {
            modelName = model
            modelFolder = nil
            kit = nil
        }
        if modelFolder == nil {
            modelFolder = try await WhisperKit.download(variant: model, downloadBase: Self.modelsDirectory) { p in
                progress?(p.fractionCompleted)
            }
        }
    }

    /// Загрузить модель в память, если её там нет. Одновременные вызовы ждут одну и ту же загрузку.
    public func ensureLoaded() async throws {
        if kit != nil { return }
        if let loading { return try await loading.value }
        let task = Task { try await self.performLoad() }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func performLoad() async throws {
        if modelFolder == nil { try await prepare(model: modelName) }
        guard let folder = modelFolder else { throw ScribeError.modelNotLoaded }
        let config = WhisperKitConfig(model: modelName, modelFolder: folder.path, verbose: false,
                                      logLevel: .error, prewarm: true, load: true, download: false)
        kit = try await WhisperKit(config)
    }

    /// Скачать (если нужно) и сразу загрузить в память.
    public func load(model: String = Transcriber.defaultModel,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await prepare(model: model, progress: progress)
        try await ensureLoaded()
    }

    /// Выгрузить модель из памяти; при следующей расшифровке она загрузится снова (~6 с).
    public func unload() {
        kit = nil
    }

    /// Начать новую запись: забыть контекст предыдущей.
    public func reset() {
        context = ""
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        let audio = Self.normalized(samples)
        var text = try await decode(audio, temperature: 0)
        // Страховка: длинный кусок совсем без знаков — пробуем ещё раз с небольшой случайностью и берём вариант со знаками.
        if text.count >= 80 && Self.punctuationCount(text) == 0 {
            let retry = try await decode(audio, temperature: 0.3)
            if Self.punctuationCount(retry) > 0 { text = retry }
        }
        text = glossary.apply(to: text)
        if !text.isEmpty && rollingContext {
            context = String((context + " " + text).suffix(contextCharacters))
        }
        return text
    }

    private func decode(_ audio: [Float], temperature: Float) async throws -> String {
        try await ensureLoaded()  // модель могли выгрузить по бездействию — загрузится сама
        guard let kit else { throw ScribeError.modelNotLoaded }
        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: temperature,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: !withTimestamps
        )
        if let tokenizer = kit.tokenizer {
            var prompt = initialPrompt  // словарь сюда не добавляем — см. Glossary
            if rollingContext && !context.isEmpty { prompt += " " + context }
            let begin = tokenizer.specialTokens.specialTokenBegin
            options.promptTokens = tokenizer.encode(text: " " + prompt).filter { $0 < begin }
        }
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        let segments = results.flatMap(\.segments).filter { !Self.isHallucination($0) }
        return Self.clean(segments.map(\.text).joined(separator: " "))
    }

    static func punctuationCount(_ text: String) -> Int {
        text.filter { ".,?!…".contains($0) }.count
    }

    /// Тихие записи поднимаем до пика ~0.5 (не больше чем в 30 раз), громкие не трогаем.
    static func normalized(_ samples: [Float]) -> [Float] {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return samples }
        let gain = min(30, 0.5 / peak)
        return gain > 1 ? samples.map { $0 * gain } : samples
    }

    // MARK: - Очистка

    /// Фразы, которые Whisper выдумывает на тишине и шуме (из субтитров, на которых он учился).
    static let hallucinationPatterns: [NSRegularExpression] = [
        "субтитр", "продолжение следует", "спасибо за просмотр", "подписывайтесь на канал",
        "редактор субтитров", "корректор", "dimatorzok", "amara\\.org", "ставьте лайк",
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func isHallucination(_ segment: TranscriptionSegment) -> Bool {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        if segment.noSpeechProb > 0.6 && segment.avgLogprob < -1.0 { return true }
        let range = NSRange(text.startIndex..., in: text)
        return hallucinationPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ScribeError: LocalizedError {
    case modelNotLoaded

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Модель распознавания ещё не загружена"
        }
    }
}
