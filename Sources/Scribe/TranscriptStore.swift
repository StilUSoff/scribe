import AVFoundation
import Foundation

/// Папка с записями и расшифровками: ~/Documents/Transcripts.
///
/// Звук лежит отдельно, в подпапке audio, чтобы не мешаться с расшифровками.
/// Во время записи: «audio/<дата>.caf» (звук) и «<дата>.partial.txt» (текст по мере распознавания).
/// После: «<дата>.txt» и «audio/<дата>.m4a»; caf и partial удаляются. caf — незавершённая запись.
struct TranscriptStore {
    let folder: URL
    var audioFolder: URL { folder.appendingPathComponent("audio", isDirectory: true) }
    static let audioExtensions: Set<String> = ["caf", "m4a"]

    init(folder: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcripts", isDirectory: true)) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        moveLooseAudio()
    }

    /// Записи, сохранённые до появления подпапки audio, переносим туда.
    private func moveLooseAudio() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where Self.audioExtensions.contains(file.pathExtension) {
            let target = audioFolder.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.moveItem(at: file, to: target)
            }
        }
    }

    static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

    func newBaseName(_ date: Date = Date()) -> String {
        Self.nameFormatter.string(from: date)
    }

    func url(_ base: String, _ ext: String) -> URL {
        (Self.audioExtensions.contains(ext) ? audioFolder : folder).appendingPathComponent("\(base).\(ext)")
    }

    /// Записи, которые не успели расшифроваться (сбой, выход во время записи).
    func unfinished() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: audioFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "caf" }.sorted { $0.path < $1.path }
    }

    /// Сохранить итог: txt, звук в m4a (в ~5 раз меньше), убрать промежуточные файлы.
    func finalize(base: String, text: String) async -> URL {
        let txt = url(base, "txt")
        try? (text.isEmpty ? "" : text + "\n").write(to: txt, atomically: true, encoding: .utf8)
        let caf = url(base, "caf")
        if FileManager.default.fileExists(atPath: caf.path) {
            if await Self.exportM4A(from: caf, to: url(base, "m4a")) {
                try? FileManager.default.removeItem(at: caf)
            }
        }
        try? FileManager.default.removeItem(at: url(base, "partial.txt"))
        return txt
    }

    static func exportM4A(from source: URL, to target: URL) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return false }
        try? FileManager.default.removeItem(at: target)
        session.outputURL = target
        session.outputFileType = .m4a
        await session.export()
        return session.status == .completed
    }
}
