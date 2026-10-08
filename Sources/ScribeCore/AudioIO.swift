import AVFoundation

public enum AudioIO {
    public static let sampleRate: Double = 16_000

    /// Формат, в котором работает распознавание: моно, 16 кГц, Float32.
    public static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// Читает любой аудио/видеофайл, который понимает AVFoundation (wav, m4a, mp3, mp4…), в моно 16 кГц.
    public static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let converter = Converter(from: file.processingFormat)
        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) * sampleRate / file.processingFormat.sampleRate) + 1024)
        let block: AVAudioFrameCount = 1 << 16
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else { break }
            try file.read(into: buffer, frameCount: block)
            if buffer.frameLength == 0 { break }
            result += try converter.convert(buffer)
        }
        return result
    }

    /// Потоковый конвертер в моно 16 кГц: держит состояние ресемплера между кусками.
    public final class Converter {
        private let converter: AVAudioConverter?
        private let input: AVAudioFormat

        public init(from input: AVAudioFormat) {
            self.input = input
            let same = input.sampleRate == sampleRate && input.channelCount == 1 && input.commonFormat == .pcmFormatFloat32
            converter = same ? nil : AVAudioConverter(from: input, to: AudioIO.targetFormat)
        }

        public func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
            guard let converter else {
                return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
            let ratio = sampleRate / input.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: AudioIO.targetFormat, frameCapacity: capacity) else { return [] }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
    }
}
