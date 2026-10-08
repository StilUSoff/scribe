import AVFoundation
import CoreAudio
import ScribeCore

/// Запись с микрофона: пишет в файл CAF (моно 16 кГц, 16 бит) и отдаёт тот же звук наружу.
/// CAF читается даже если запись оборвалась на середине (сбой, выключение).
///
/// Устойчивость к созвонам (Meet, Zoom и т.п.):
/// - один AVAudioEngine на всю запись; после «изменилась конфигурация устройства» он поднимается снова — с задержкой,
///   только если действительно остановился, и не чаще 5 раз за 20 с. Иначе собственный перезапуск порождает новое
///   уведомление, и микрофон включается-выключается по кругу;
/// - при смене микрофона по умолчанию в системе (режим «как в системе») — переключение на новый;
/// - сторож тишины: живой микрофон всегда шумит, а 3 с ровных нулей значат, что звук не доходит. Тогда по очереди:
///   перезапуск → режим системной обработки голоса (если приложение созвона держит микрофон в этом режиме, обычным
///   приложениям достаётся тишина) → встроенный микрофон. Что сработало — видно в журнале.
final class MicRecorder {
    enum Event {
        case started(device: String, format: String, voiceProcessing: Bool)
        case recovering(String)
        case silent(device: String)
    }

    /// События для журнала и уведомлений; вызывается на главном потоке.
    var onEvent: ((Event) -> Void)?
    private(set) var recordedSamples = 0
    private(set) var currentDevice: AudioInputDevice?

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AudioIO.Converter?
    private var onSamples: (([Float]) -> Void)?
    private var preferredUID: String?
    private var targetDevice: AudioInputDevice?
    private var voiceProcessing = false
    private var configObserver: NSObjectProtocol?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "scribe.mic.listener")
    private var watchdog: Timer?
    private var pendingRestart: DispatchWorkItem?
    private var restartPending = false
    private var restarts: [Date] = []
    private var silenceStep = 0
    private let lock = NSLock()
    private var lastSignal = Date()
    private var engineStarted = Date()

    static let silenceTimeout: TimeInterval = 3

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// - Parameter preferredUID: выбранный в меню микрофон; nil — как в системе (и следовать за её сменой).
    func start(writingTo url: URL, preferredUID: String?, onSamples: @escaping ([Float]) -> Void) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioIO.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.onSamples = onSamples
        self.preferredUID = preferredUID
        recordedSamples = 0
        targetDevice = (preferredUID.flatMap(AudioDevices.device(uid:))) ?? AudioDevices.defaultInput() ?? AudioDevices.builtIn()
        guard targetDevice != nil else { throw RecorderError.noInputDevice }
        try configure()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.scheduleRestart(reason: "изменилась конфигурация устройства")
        }
        if preferredUID == nil {
            // Слушатель — на своей очереди: снимать его с главного потока, пока он ждёт главный поток, — взаимная блокировка.
            defaultListener = AudioDevices.addDefaultInputListener(queue: listenerQueue) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.file != nil, let device = AudioDevices.defaultInput(),
                          device.uid != self.targetDevice?.uid else { return }
                    self.targetDevice = device
                    self.scheduleRestart(reason: "в системе выбран микрофон «\(device.name)»", force: true)
                }
            }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }
    }

    func stop() {
        file = nil  // дальше никакие перезапуски не делаем; закрывает файл
        pendingRestart?.cancel()
        watchdog?.invalidate()
        watchdog = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let defaultListener { AudioDevices.removeDefaultInputListener(defaultListener, queue: listenerQueue) }
        defaultListener = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onSamples = nil
    }

    // MARK: - Настройка движка

    /// Остановить, выставить устройство и режим, поставить отвод звука, запустить.
    private func configure() throws {
        guard let device = targetDevice else { throw RecorderError.noInputDevice }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let input = engine.inputNode
        // Устройство выставляем, только если оно другое: сама установка вызывает «изменение конфигурации».
        if let unit = input.audioUnit, Self.currentDevice(of: unit) != device.id {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { throw RecorderError.cannotSelect(device.name, status) }
        }
        if input.isVoiceProcessingEnabled != voiceProcessing {
            try input.setVoiceProcessingEnabled(voiceProcessing)
            if voiceProcessing {
                // Не приглушать звук созвона и не подкручивать громкость микрофона.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                input.isVoiceProcessingAGCEnabled = false
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noFormat(device.name) }
        converter = AudioIO.Converter(from: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        currentDevice = device
        lock.withLock { lastSignal = Date(); engineStarted = Date() }
        onEvent?(.started(device: device.name, format: "\(Int(format.sampleRate)) Гц, \(format.channelCount) кан.",
                          voiceProcessing: voiceProcessing))
    }

    /// Перезапуск с задержкой: несколько уведомлений подряд схлопываются в одно, а уведомление, вызванное нашим же
    /// запуском, отбрасывается — к моменту проверки движок уже работает.
    private func scheduleRestart(reason: String, force: Bool = false) {
        guard file != nil else { return }
        pendingRestart?.cancel()
        restartPending = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartPending = false
            guard self.file != nil else { return }
            if !force && self.engine.isRunning { return }
            let now = Date()
            self.restarts = self.restarts.filter { now.timeIntervalSince($0) < 20 }
            guard self.restarts.count < 5 else {
                // Слишком часто — подождать и попробовать ещё раз, а не крутиться в петле.
                self.onEvent?(.recovering("слишком частые перезапуски — пауза 10 с"))
                self.restarts.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.scheduleRestart(reason: reason, force: force) }
                return
            }
            self.restarts.append(now)
            self.onEvent?(.recovering(reason))
            do {
                try self.configure()
            } catch {
                self.onEvent?(.recovering("не удалось запустить «\(self.targetDevice?.name ?? "—")»: \(error.localizedDescription)"))
                if let builtIn = AudioDevices.builtIn(), builtIn.uid != self.targetDevice?.uid {
                    self.targetDevice = builtIn
                    self.voiceProcessing = false
                    self.scheduleRestart(reason: "переход на встроенный микрофон", force: true)
                }
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    // MARK: - Сторож тишины

    private func checkSilence() {
        // silenceStep < 0 — уже предупредили, что ничего не помогло: больше не трогаем микрофон до появления звука.
        guard file != nil, currentDevice != nil, !restartPending, silenceStep >= 0 else { return }
        let (last, started) = lock.withLock { (lastSignal, engineStarted) }
        let now = Date()
        guard now.timeIntervalSince(last) >= Self.silenceTimeout,
              now.timeIntervalSince(started) >= Self.silenceTimeout else { return }
        silenceStep += 1
        let name = currentDevice?.name ?? "—"
        switch silenceStep {
        case 1:
            scheduleRestart(reason: "«\(name)» отдаёт тишину — перезапуск", force: true)
        case 2:
            voiceProcessing = !voiceProcessing
            scheduleRestart(reason: "«\(name)» всё ещё молчит — \(voiceProcessing ? "включаю" : "выключаю") системную обработку голоса",
                            force: true)
        case 3:
            if let builtIn = AudioDevices.builtIn(), builtIn.uid != targetDevice?.uid {
                targetDevice = builtIn
                voiceProcessing = false
                scheduleRestart(reason: "«\(name)» не отдаёт звук — переход на встроенный микрофон", force: true)
            } else {
                fallthrough
            }
        default:
            onEvent?(.silent(device: name))
            silenceStep = -1  // одно предупреждение; снова пробовать начнём, только если звук появится и опять пропадёт
        }
        lock.withLock { lastSignal = Date() }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let samples = try? converter?.convert(buffer), !samples.isEmpty else { return }
        if samples.contains(where: { $0 != 0 }) {
            lock.withLock { lastSignal = Date() }
            DispatchQueue.main.async { if self.silenceStep != 0 { self.silenceStep = 0 } }
        }
        if let out = AVAudioPCMBuffer(pcmFormat: AudioIO.targetFormat, frameCapacity: AVAudioFrameCount(samples.count)) {
            samples.withUnsafeBufferPointer { src in
                out.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            out.frameLength = AVAudioFrameCount(samples.count)
            try? file?.write(from: out)
        }
        recordedSamples += samples.count
        onSamples?(samples)
    }

    private static func currentDevice(of unit: AudioUnit) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return id
    }
}

enum RecorderError: LocalizedError {
    case noInputDevice
    case cannotSelect(String, OSStatus)
    case noFormat(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "В системе нет ни одного микрофона"
        case let .cannotSelect(name, status): return "Не удалось выбрать микрофон «\(name)» (код \(status))"
        case let .noFormat(name): return "Микрофон «\(name)» недоступен"
        }
    }
}
