import AppKit
import Combine
import ScribeCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loadingModel(Double)
        case ready
        case recording(Date)
        case finishing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loadingModel(0)
    @Published private(set) var elapsed = ""
    @Published private(set) var unfinished: [URL] = []
    /// Идущая расшифровка (файла или конца записи после «стоп») — для прогресса в меню.
    struct Job: Equatable {
        var title: String
        var fraction: Double
        /// Примерно сколько секунд осталось; nil — пока не на чем оценить скорость.
        var remaining: Double?
    }

    @Published private(set) var job: Job?
    /// Нажали «Отменить» — ждём, пока дорасшифруется текущий кусок (до пары секунд).
    @Published private(set) var cancelling = false
    private var jobTask: Task<Void, Never>?
    @Published private(set) var hotKeyProblem: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    enum ModelChoice: String, CaseIterable, Identifiable {
        case accurate = "openai_whisper-large-v3"
        case fast = "openai_whisper-large-v3-v20240930"

        var id: String { rawValue }

        /// Нарезка под модель. Whisper выдаёт за проход не больше ~224 токенов, а русская речь дробится на 2,5–3 токена
        /// на слово: в 25-секундный кусок плотной речи текст не помещается и конец обрезается. Для точной модели
        /// куски 6–15 с: на 30-минутном созвоне пропавших предложений 12 из 228 против 16 (при 12–28 с),
        /// цена — ~2× реального времени вместо ~2,6×. Быстрой модели короткие куски не помогли — оставляем как было.
        var chunker: SpeechChunker {
            var chunker = SpeechChunker()
            if self == .accurate {
                chunker.minSeconds = 6
                chunker.maxSeconds = 15
            }
            return chunker
        }

        var title: String {
            switch self {
            case .accurate: return "Точная (large-v3)"
            case .fast: return "Быстрая (large-v3-turbo)"
            }
        }
    }

    @Published private(set) var modelChoice =
        ModelChoice(rawValue: UserDefaults.standard.string(forKey: "model") ?? "") ?? .accurate

    let store = TranscriptStore()
    private let transcriber = Transcriber()
    private let hotKey = HotKey()
    private var recorder: MicRecorder?
    private var pipeline: TranscriptionPipeline?
    private var base = ""
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var started = false
    /// Сколько записи уже распознано по ходу и сколько всего записано (известно после «стоп»).
    private var liveProgress = TranscriptionPipeline.Progress(doneSeconds: 0, speed: nil)
    private var liveTotal: Double = 0
    /// Модель в памяти; после 5 минут без записи и расшифровки выгружается.
    @Published private(set) var modelLoaded = false
    static let idleUnloadAfter: TimeInterval = 5 * 60
    /// Словарь терминов (редактируется в TextEdit из меню, перечитывается перед каждой записью и расшифровкой).
    static let glossaryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Scribe/Словарь.txt")
    @Published private(set) var glossaryTerms = 0
    private var idleTimer: Timer?

    func start() {
        guard !started else { return }
        started = true
        AppLog.write("запуск Scribe")
        if !hotKey.register(action: { [weak self] in self?.toggle() }) {
            AppLog.write("⌥Space занят другим приложением")
            hotKeyProblem = "⌥Space уже занят другим приложением (Handy?) — закройте его и перезапустите Scribe"
        }
        refresh()
        if !FileManager.default.fileExists(atPath: Self.glossaryURL.path) {
            try? FileManager.default.createDirectory(at: Self.glossaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var text = Glossary.defaultText
            // Личная часть словаря (имена, внутренние термины) — кладётся в приложение при сборке, в git её нет.
            if let url = Bundle.main.url(forResource: "glossary.private", withExtension: "txt"),
               let extra = try? String(contentsOf: url, encoding: .utf8) {
                text += "\n\n" + extra
            }
            try? (text + "\n").write(to: Self.glossaryURL, atomically: true, encoding: .utf8)
        }
        Task { await reloadGlossary() }
        Task { await prepareModel() }
    }

    /// Перечитать словарь с диска и передать модели.
    private func reloadGlossary() async {
        let glossary = Glossary(contentsOf: Self.glossaryURL)
        await transcriber.setGlossary(glossary)
        glossaryTerms = glossary.terms.count
    }

    func openGlossary() {
        NSWorkspace.shared.open(Self.glossaryURL)
    }

    func refresh() {
        let current = pipeline == nil ? nil : store.url(base, "caf")
        unfinished = store.unfinished().filter { $0 != current }
    }

    /// Сменить модель; только когда ничего не пишется и не расшифровывается.
    func selectModel(_ choice: ModelChoice) {
        guard choice != modelChoice else { return }
        switch phase {
        case .ready, .failed: break
        default: NSSound.beep(); return
        }
        modelChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "model")
        Task { await prepareModel() }
    }

    /// Выбрать модель и скачать её, если её ещё нет на диске. В память не грузим: это произойдёт при первой
    /// записи или расшифровке файла (~6 с, параллельно с записью).
    private func prepareModel() async {
        phase = .loadingModel(0)
        do {
            try await transcriber.prepare(model: modelChoice.rawValue) { [weak self] p in
                Task { @MainActor in self?.phase = .loadingModel(p) }
            }
            modelLoaded = await transcriber.isLoaded
            AppLog.write("модель выбрана: \(modelChoice.rawValue)")
            phase = .ready
        } catch {
            AppLog.write("ошибка подготовки модели: \(error)")
            phase = .failed("Не удалось скачать модель: \(error.localizedDescription)")
        }
    }

    /// Загрузить модель в память (если выгружена). Ошибку показываем, но запись не прерываем: звук сохранится.
    private func warmUpModel() async -> Bool {
        idleTimer?.invalidate()
        if await transcriber.isLoaded { return true }
        let started = Date()
        AppLog.write("загрузка модели в память: \(modelChoice.rawValue)")
        do {
            try await transcriber.ensureLoaded()
            modelLoaded = true
            AppLog.write(String(format: "модель загружена за %.1f с", Date().timeIntervalSince(started)))
            return true
        } catch {
            AppLog.write("ошибка загрузки модели: \(error)")
            Notifier.show(title: "Не удалось загрузить модель", body: error.localizedDescription)
            return false
        }
    }

    /// После записи/расшифровки: если 5 минут ничего не происходит — выгрузить модель из памяти.
    private func scheduleIdleUnload() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleUnloadAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .ready, self.modelLoaded else { return }
                await self.transcriber.unload()
                self.modelLoaded = false
                AppLog.write("модель выгружена после 5 минут бездействия")
            }
        }
    }

    // MARK: - Запись

    func toggle() {
        switch phase {
        case .ready: Task { await startRecording() }
        case .recording: Task { await stopRecording() }
        default: NSSound.beep()
        }
    }

    private func startRecording() async {
        guard await MicRecorder.requestAccess() else {
            Notifier.show(title: "Нет доступа к микрофону",
                          body: "Разрешите Scribe микрофон: Системные настройки → Конфиденциальность → Микрофон")
            return
        }
        await reloadGlossary()
        base = store.newBaseName()
        liveProgress = TranscriptionPipeline.Progress(doneSeconds: 0, speed: nil)
        let pipeline = TranscriptionPipeline(transcriber: transcriber, partialURL: store.url(base, "partial.txt"),
                                             chunker: modelChoice.chunker) { [weak self] p in
            Task { @MainActor in self?.liveChunk(p) }
        }
        let recorder = MicRecorder()
        recorder.onEvent = { [weak self] event in self?.recorderEvent(event) }
        do {
            try recorder.start(writingTo: store.url(base, "caf"), preferredUID: micUID) { samples in pipeline.feed(samples) }
        } catch {
            AppLog.write("не удалось начать запись: \(error.localizedDescription)")
            Notifier.show(title: "Не удалось начать запись", body: error.localizedDescription)
            return
        }
        self.pipeline = pipeline
        self.recorder = recorder
        AppLog.write("запись начата: \(base)")
        idleTimer?.invalidate()
        Task { _ = await warmUpModel() }  // параллельно с записью: первый кусок будет не раньше чем через 12 с
        // Не даём Mac уснуть и macOS «заморозить» приложение, пока идёт запись.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Запись диктовки")
        let started = Date()
        phase = .recording(started)
        elapsed = "0:00"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Self.format(Date().timeIntervalSince(started)) }
        }
    }

    private func stopRecording() async {
        guard let recorder, let pipeline else { return }
        timer?.invalidate()
        recorder.stop()
        let seconds = Double(recorder.recordedSamples) / AudioIO.sampleRate
        liveTotal = max(seconds, 0.001)
        phase = .finishing
        liveChunk(liveProgress)
        AppLog.write(String(format: "запись остановлена: %.0f с, дорасшифровка конца", seconds))
        let text = await pipeline.finish()
        let cancelled = cancelling
        AppLog.write(cancelled ? "расшифровка записи отменена" : "расшифровка записи готова: \(text.count) символов")
        var txt: URL?
        if !cancelled {
            job = Job(title: "конец записи", fraction: 1, remaining: 0)
            txt = await store.finalize(base: base, text: text)
        }
        // При отмене звук (audio/….caf) и уже распознанное (….partial.txt) остаются — запись появится
        // в «Дорасшифровать незавершённые».
        job = nil
        cancelling = false
        liveTotal = 0
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        self.recorder = nil
        micInUse = nil
        self.pipeline = nil
        base = ""
        phase = .ready
        refresh()
        scheduleIdleUnload()
        guard let txt else {
            Notifier.show(title: "Расшифровка отменена",
                          body: "Запись \(Self.format(seconds)) сохранена — её можно дорасшифровать из меню")
            return
        }
        if text.isEmpty {
            Notifier.show(title: "Речь не распознана", body: "Запись \(Self.format(seconds)) сохранена", file: txt)
        } else {
            Notifier.show(title: "Расшифровка готова", body: "\(Self.format(seconds)) · \(txt.lastPathComponent)", file: txt)
        }
    }

    private func liveChunk(_ p: TranscriptionPipeline.Progress) {
        liveProgress = p
        guard phase == .finishing, liveTotal > 0, !cancelling else { return }
        job = Job(title: "конец записи", fraction: min(p.doneSeconds / liveTotal, 1), remaining: p.remaining(until: liveTotal))
    }

    private func recorderEvent(_ event: MicRecorder.Event) {
        switch event {
        case let .started(device, format, voiceProcessing):
            AppLog.write("микрофон: \(device) (\(format)\(voiceProcessing ? ", с системной обработкой голоса" : ""))")
            if let previous = micInUse, previous != device {
                Notifier.show(title: "Микрофон переключён", body: "Запись продолжается с «\(device)»")
            }
            micInUse = device
        case let .recovering(reason):
            AppLog.write("микрофон: \(reason)")
        case let .silent(device):
            AppLog.write("микрофон «\(device)» отдаёт тишину, ни один способ не помог")
            Notifier.show(title: "Микрофон не отдаёт звук",
                          body: "«\(device)» пишет тишину. Проверьте, не выключен ли микрофон, или выберите другой в меню Scribe")
        }
    }

    // MARK: - Микрофон

    /// UID выбранного в меню микрофона; nil — как в системе.
    @Published private(set) var micUID: String? = UserDefaults.standard.string(forKey: "micUID")
    /// С какого микрофона идёт запись прямо сейчас.
    @Published private(set) var micInUse: String?

    func selectMic(_ uid: String?) {
        micUID = uid
        UserDefaults.standard.set(uid, forKey: "micUID")
        AppLog.write("выбран микрофон: \(uid.flatMap { AudioDevices.device(uid: $0)?.name } ?? "как в системе")")
    }

    // MARK: - Файлы

    func transcribeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        jobTask = Task { await transcribe(url, base: store.newBaseName(), removeSource: false) }
    }

    /// Отменить идущую расшифровку: файла, незавершённых записей или конца только что остановленной записи.
    func cancelJob() {
        guard phase == .finishing, !cancelling else { return }
        cancelling = true
        job?.title = "отменяю…"
        if let pipeline {
            pipeline.cancel()  // конец живой записи
        } else {
            jobTask?.cancel()
        }
    }

    func finishUnfinished() {
        let files = unfinished
        jobTask = Task {
            for caf in files where !Task.isCancelled {
                await transcribe(caf, base: caf.deletingPathExtension().lastPathComponent, removeSource: true)
            }
        }
    }

    private func transcribe(_ url: URL, base: String, removeSource: Bool) async {
        guard phase == .ready else { NSSound.beep(); return }
        phase = .finishing
        let name = url.lastPathComponent
        job = Job(title: name, fraction: 0, remaining: nil)
        let jobStarted = Date()
        AppLog.write("расшифровка файла: \(url.path)")
        await reloadGlossary()
        defer { job = nil; cancelling = false; phase = .ready; refresh(); scheduleIdleUnload() }
        if !(await transcriber.isLoaded) {
            job = Job(title: "\(name) — загружаю модель…", fraction: 0, remaining: nil)
            guard await warmUpModel(), !Task.isCancelled else { return }
        }
        job = Job(title: name, fraction: 0, remaining: nil)
        do {
            let text = try await TranscriptionPipeline.transcribeFile(url, transcriber: transcriber,
                                                                      chunker: modelChoice.chunker) { fraction, remaining in
                Task { @MainActor in
                    guard !self.cancelling else { return }
                    self.job = Job(title: name, fraction: fraction, remaining: remaining)
                }
            }
            job = Job(title: name, fraction: 1, remaining: 0)
            let txt: URL
            if removeSource {
                txt = await store.finalize(base: base, text: text)  // незавершённая запись: ещё и caf → m4a
            } else {
                txt = store.url(base, "txt")
                try? (text + "\n").write(to: txt, atomically: true, encoding: .utf8)
            }
            AppLog.write(String(format: "файл готов за %.0f с: %d символов → %@", Date().timeIntervalSince(jobStarted), text.count, txt.lastPathComponent))
            Notifier.show(title: "Расшифровка готова", body: txt.lastPathComponent, file: txt)
        } catch is CancellationError {
            AppLog.write("расшифровка файла отменена")
            Notifier.show(title: "Расшифровка отменена", body: removeSource
                ? "Запись сохранена — её можно дорасшифровать из меню" : name)
        } catch {
            AppLog.write("ошибка расшифровки файла: \(error)")
            Notifier.show(title: "Не удалось расшифровать", body: error.localizedDescription)
        }
    }

    func openFolder() {
        NSWorkspace.shared.open(store.folder)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Notifier.show(title: "Автозапуск", body: error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
