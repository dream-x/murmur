import Foundation

/// One meeting recording: a folder with mic.aac, system.aac and meta.json.
final class RecordingSession {
    let folder: URL
    let startedAt = Date()
    private(set) var apps: Set<String>
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    init(outputDir: URL, apps: [String]) throws {
        self.apps = Set(apps)
        let stamp = DateFormatter.fileStamp.string(from: startedAt)
        let label = apps.first.map { "_" + Self.shortName($0) } ?? ""
        folder = outputDir.appendingPathComponent(stamp + label, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        do { try mic.start(to: folder.appendingPathComponent("mic.aac")) } catch { log("mic start failed: \(error)") }
        do { try system.start(to: folder.appendingPathComponent("system.aac")) } catch { log("system audio start failed: \(error)") }
        writeMeta(endedAt: nil)
    }

    func noteApps(_ more: [String]) {
        apps.formUnion(more)
    }

    /// Stops recording; returns false if the session was discarded as too short.
    @discardableResult
    func stop(minDuration: TimeInterval) -> Bool {
        mic.stop()
        system.stop()
        let duration = Date().timeIntervalSince(startedAt)
        if duration < minDuration {
            try? FileManager.default.removeItem(at: folder)
            return false
        }
        writeMeta(endedAt: Date())
        return true
    }

    private func writeMeta(endedAt: Date?) {
        let iso = ISO8601DateFormatter()
        var meta: [String: Any] = ["started_at": iso.string(from: startedAt), "apps": apps.sorted()]
        if let endedAt {
            meta["ended_at"] = iso.string(from: endedAt)
            meta["duration_sec"] = Int(endedAt.timeIntervalSince(startedAt))
        }
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("meta.json"))
        }
    }

    private static func shortName(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}

private let logFile: FileHandle? = {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Murmur.log").path
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
}()

func log(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".data(using: .utf8)!
    if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(line) }
    logFile?.write(line)
}
