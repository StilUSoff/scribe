import AVFoundation
import CoreAudio
import ScribeCore

/// Запись с микрофона: пишет в файл CAF (моно 16 кГц, 16 бит) и отдаёт тот же звук наружу.
/// CAF читается даже если запись оборвалась на середине (сбой, выключение).
///
/// Устойчивость к созвонам: AVAudioEngine сам не следует за сменой микрофона в системе (macOS переключает вход,
/// например, на микрофон iPhone, когда Meet/Zoom открывает звук) и продолжает слушать устройство, которое отдаёт
/// цифровую тишину. Поэтому:
/// - движок явно привязан к устройству и пересоздаётся, когда в системе меняется микрофон по умолчанию;
/// - сторож тишины: 3 с подряд ровно нулевых сэмплов (живой микрофон всегда шумит) — перезапуск устройства,
///   ещё раз — переход на встроенный микрофон. Файл и распознавание при этом не прерываются.
final class MicRecorder {
    enum Event {
        case started(device: String, format: String)
        case switched(from: String, to: String, reason: String)
        case silent(device: String)
    }

    /// События для журнала и уведомлений; вызывается на главном потоке.
    var onEvent: ((Event) -> Void)?
    private(set) var recordedSamples = 0
    private(set) var currentDevice: AudioInputDevice?

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var converter: AudioIO.Converter?
    private var onSamples: (([Float]) -> Void)?
    private var preferredUID: String?
    private var configObserver: NSObjectProtocol?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var watchdog: Timer?
    private var silentRestarts = 0
    private var reportedSilent = false
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
        guard let device = resolveDevice() else { throw RecorderError.noInputDevice }
        try startEngine(on: device)

        if preferredUID == nil {
            defaultListener = AudioDevices.addDefaultInputListener { [weak self] in
                guard let self, let device = AudioDevices.defaultInput(), device.uid != self.currentDevice?.uid else { return }
                self.switchTo(device, reason: "в системе выбран другой микрофон")
            }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let defaultListener { AudioDevices.removeDefaultInputListener(defaultListener) }
        defaultListener = nil
        stopEngine()
        file = nil  // закрывает файл
        onSamples = nil
    }

    // MARK: - Устройство

    private func resolveDevice() -> AudioInputDevice? {
        if let preferredUID, let device = AudioDevices.device(uid: preferredUID) { return device }
        return AudioDevices.defaultInput() ?? AudioDevices.builtIn()
    }

    private func startEngine(on device: AudioInputDevice) throws {
        stopEngine()
        let engine = AVAudioEngine()
        if let unit = engine.inputNode.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { throw RecorderError.cannotSelect(device.name, status) }
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noFormat(device.name) }
        converter = AudioIO.Converter(from: format)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        currentDevice = device
        lock.withLock { lastSignal = Date(); engineStarted = Date() }
        // Устройство сменило формат или отвалилось — движок остановился; поднимаем заново на том же устройстве.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.file != nil else { return }
            self.switchTo(self.resolveDevice() ?? device, reason: "изменилась конфигурация устройства")
        }
        onEvent?(.started(device: device.name,
                          format: "\(Int(format.sampleRate)) Гц, \(format.channelCount) кан."))
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func switchTo(_ device: AudioInputDevice, reason: String) {
        let from = currentDevice?.name ?? "—"
        do {
            try startEngine(on: device)
            onEvent?(.switched(from: from, to: device.name, reason: reason))
        } catch {
            // Новое устройство не открылось — вернуться на встроенный микрофон, лишь бы запись шла.
            if let builtIn = AudioDevices.builtIn(), builtIn.uid != device.uid, (try? startEngine(on: builtIn)) != nil {
                onEvent?(.switched(from: from, to: builtIn.name, reason: "«\(device.name)» не открылся: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Сторож тишины

    private func checkSilence() {
        guard file != nil, let device = currentDevice else { return }
        let (last, started) = lock.withLock { (lastSignal, engineStarted) }
        let now = Date()
        guard now.timeIntervalSince(last) >= Self.silenceTimeout,
              now.timeIntervalSince(started) >= Self.silenceTimeout else { return }
        silentRestarts += 1
        if silentRestarts == 1 {
            switchTo(device, reason: "микрофон отдаёт тишину — перезапускаю")
        } else if let builtIn = AudioDevices.builtIn(), builtIn.uid != device.uid {
            switchTo(builtIn, reason: "«\(device.name)» не отдаёт звук")
        } else if !reportedSilent {
            reportedSilent = true
            onEvent?(.silent(device: device.name))
            lock.withLock { lastSignal = Date() }  // не дёргать каждую секунду
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let samples = try? converter?.convert(buffer), !samples.isEmpty else { return }
        if samples.contains(where: { $0 != 0 }) {
            lock.withLock { lastSignal = Date() }
            if silentRestarts > 0 || reportedSilent {
                DispatchQueue.main.async { self.silentRestarts = 0; self.reportedSilent = false }
            }
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
