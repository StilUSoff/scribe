import SwiftUI

@main
struct ScribeApp: App {
    @StateObject private var model = AppModel()

    init() {
        Notifier.setup()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
                .task { model.start() }
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.phase {
        case .recording:
            Image(systemName: "record.circle.fill")  // таймер — только в выпадающем меню
        case .finishing:
            Image(systemName: "ellipsis.circle")
        case .loadingModel:
            Image(systemName: "arrow.down.circle")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
        case .ready:
            Image(systemName: "waveform")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        status
        if let problem = model.hotKeyProblem { Text(problem) }

        switch model.phase {
        case .ready:
            Button("Начать запись   ⌥Space") { model.toggle() }
        case .recording:
            Button("Остановить запись   ⌥Space") { model.toggle() }
        case .finishing:
            Button("Отменить расшифровку") { model.cancelJob() }
                .disabled(model.cancelling || model.job?.fraction ?? 0 >= 1)
        default:
            EmptyView()
        }

        Divider()
        if !model.unfinished.isEmpty {
            Button("Дорасшифровать незавершённые (\(model.unfinished.count))") { model.finishUnfinished() }
                .disabled(model.phase != .ready)
        }
        Button("Расшифровать файл…") { model.transcribeFile() }
            .disabled(model.phase != .ready)
        Button("Открыть папку с расшифровками") { model.openFolder() }
        Button("Словарь терминов… (\(model.glossaryTerms))") { model.openGlossary() }

        Divider()
        Picker("Микрофон", selection: Binding(get: { model.micUID ?? "" }, set: { model.selectMic($0.isEmpty ? nil : $0) })) {
            Text("Как в системе (сейчас: \(AudioDevices.defaultInput()?.name ?? "—"))").tag("")
            ForEach(AudioDevices.inputs()) { Text($0.name).tag($0.uid) }
        }
        .disabled(isRecording)  // меняется со следующей записи
        Picker("Модель", selection: Binding(get: { model.modelChoice }, set: { model.selectModel($0) })) {
            ForEach(AppModel.ModelChoice.allCases) { Text($0.title).tag($0) }
        }
        .disabled(!canChangeModel)
        Toggle("Запускать при входе", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Button("Выйти") { NSApp.terminate(nil) }
            .disabled(isRecording)  // выход посреди записи оставит её незавершённой
    }

    static func bar(_ fraction: Double, width: Int = 14) -> String {
        let filled = min(width, max(0, Int((fraction * Double(width)).rounded())))
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: width - filled)
    }

    static func remaining(_ seconds: Double?) -> String {
        guard let seconds else { return "— считаю…" }
        switch seconds {
        case ..<5: return "пара секунд"
        case ..<60: return "≈ \(Int((seconds / 5).rounded(.up)) * 5) с"
        case ..<600:
            let s = Int((seconds / 10).rounded()) * 10
            return s % 60 == 0 ? "≈ \(s / 60) мин" : "≈ \(s / 60) мин \(s % 60) с"
        default: return "≈ \(Int((seconds / 60).rounded())) мин"
        }
    }

    private var canChangeModel: Bool {
        switch model.phase {
        case .ready, .failed: return true
        default: return false
        }
    }

    private var isRecording: Bool {
        if case .recording = model.phase { return true }
        return false
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .loadingModel(let p):
            Text(p > 0 && p < 1 ? "Скачиваю модель… \(Int(p * 100))%"
                                : "Загружаю модель «\(model.modelChoice.title)»… (в первый раз — до пары минут)")
        case .ready:
            Text("Готов к записи")
            Text(model.modelLoaded ? "Модель в памяти — выгрузится через 5 мин без дела"
                                   : "Модель выгружена — загрузится при старте записи (~6 с)")
        case .recording:
            Text("● Идёт запись — \(model.elapsed)")
            if let mic = model.micInUse { Text("Микрофон: \(mic)") }
        case .finishing:
            if let job = model.job {
                Text("Расшифровываю: \(job.title)")
                Text("\(Self.bar(job.fraction))  \(Int(job.fraction * 100))%")
                if model.cancelling {
                    Text("Отменяю — дорасшифровываю текущий кусок…")
                } else {
                    Text(job.fraction >= 1 ? "Сохраняю файлы…" : "Осталось \(Self.remaining(job.remaining))")
                }
            } else {
                Text("Расшифровываю…")
            }
        case .failed(let message):
            Text(message)
        }
    }
}
