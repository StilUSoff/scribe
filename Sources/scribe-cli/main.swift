import Foundation
import ScribeCore

// Прогон файла через тот же конвейер, что и «Расшифровать файл…» в приложении:
// печатает прогресс и оценку оставшегося времени, в конце — фактическое время и число знаков.
//
//   scribe-cli <аудиофайл> [--out файл.txt] [--model имя] [--context] [--timestamps] [--min с --max с] [--glossary файл] [--fix-text] [--cancel-after сек]

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

@Sendable func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

guard CommandLine.arguments.count > 1, !CommandLine.arguments[1].hasPrefix("--") else {
    print("usage: scribe-cli <audio> [--out file.txt] [--model name] [--context] [--timestamps]")
    exit(2)
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: arg("--out") ?? input.deletingPathExtension().path + ".scribe.txt")
let model = arg("--model") ?? Transcriber.defaultModel
let flags = Set(CommandLine.arguments)

// --fix-text: прогнать словарь по готовой расшифровке (без модели), результат — в stdout.
if flags.contains("--fix-text") {
    let glossary = arg("--glossary").map { Glossary(contentsOf: URL(fileURLWithPath: $0)) } ?? Glossary(Glossary.defaultText)
    print(glossary.apply(to: try String(contentsOf: input, encoding: .utf8)), terminator: "")
    exit(0)
}
let transcriber = Transcriber()
await transcriber.configure(rollingContext: flags.contains("--context"), withTimestamps: flags.contains("--timestamps"))
var t = Date()
log("Загрузка модели \(model)…")
try await transcriber.load(model: model) { p in
    if p < 1 { log(String(format: "  скачивание: %.0f%%", p * 100)) }
}
log(String(format: "Модель готова за %.1fs", Date().timeIntervalSince(t)))

t = Date()
if let path = arg("--glossary") {
    let glossary = Glossary(contentsOf: URL(fileURLWithPath: path))
    await transcriber.setGlossary(glossary)
    log("словарь: \(glossary.terms.count) терминов")
}
// --unload-test: выгрузить модель и убедиться, что расшифровка загрузит её сама (как после 5 минут простоя в приложении).
if flags.contains("--unload-test") {
    await transcriber.unload()
    log("выгружено, isLoaded = \(await transcriber.isLoaded)")
}
var chunker = SpeechChunker()
if let v = arg("--min").flatMap(Double.init) { chunker.minSeconds = v }
if let v = arg("--max").flatMap(Double.init) { chunker.maxSeconds = v }
let job = Task { [chunker] in
    try await TranscriptionPipeline.transcribeFile(input, transcriber: transcriber, chunker: chunker) { fraction, remaining in
        let filled = Int((fraction * 20).rounded())
        let bar = String(repeating: "▓", count: filled) + String(repeating: "░", count: 20 - filled)
        let eta = remaining.map { String(format: "осталось ≈ %.0f с", $0) } ?? "осталось: считаю…"
        log(String(format: "  %@ %3.0f%%  %@", bar, fraction * 100, eta))
    }
}
// --cancel-after N: проверка отмены — через N секунд отменяем и меряем, как быстро остановилось.
if let after = arg("--cancel-after").flatMap(Double.init) {
    try await Task.sleep(nanoseconds: UInt64(after * 1e9))
    let cancelAt = Date()
    job.cancel()
    do {
        _ = try await job.value
        log("ОШИБКА: отмена не сработала, расшифровка дошла до конца")
    } catch is CancellationError {
        log(String(format: "Отменено: остановилось через %.1f с после отмены", Date().timeIntervalSince(cancelAt)))
    }
    // Модель после прерывания должна работать как обычно (в приложении следом может пойти новая расшифровка).
    if let again = arg("--then") {
        let text = try await TranscriptionPipeline.transcribeFile(URL(fileURLWithPath: again), transcriber: transcriber)
        log("Следующая расшифровка после отмены: \(text.count) символов: \(text.prefix(80))")
    }
    exit(0)
}
let text = try await job.value
let took = Date().timeIntervalSince(t)
try (text + "\n").write(to: output, atomically: true, encoding: .utf8)
log(String(format: "Готово за %.1f с: %d символов, %d «.», %d «?», %d «!», %d «,» → %@", took,
           text.count, text.filter { $0 == "." }.count, text.filter { $0 == "?" }.count,
           text.filter { $0 == "!" }.count, text.filter { $0 == "," }.count, output.path))
