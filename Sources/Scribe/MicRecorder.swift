import AVFoundation
import ScribeCore

/// Запись с микрофона по умолчанию: пишет в файл CAF (моно 16 кГц, 16 бит) и отдаёт тот же звук наружу.
/// CAF читается даже если запись оборвалась на середине (сбой, выключение).
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AudioIO.Converter?
    private var onSamples: (([Float]) -> Void)?
    private var configObserver: NSObjectProtocol?
    private(set) var recordedSamples = 0

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(writingTo url: URL, onSamples: @escaping ([Float]) -> Void) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioIO.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.onSamples = onSamples
        recordedSamples = 0
        installTap()
        engine.prepare()
        try engine.start()
        // Сменился микрофон (подключили AirPods и т.п.) — движок останавливается; подхватываем новый вход.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterDeviceChange()
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil  // закрывает файл
        onSamples = nil
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AudioIO.Converter(from: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let samples = try? converter?.convert(buffer), !samples.isEmpty else { return }
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

    private func restartAfterDeviceChange() {
        guard file != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        installTap()
        engine.prepare()
        try? engine.start()
    }
}
