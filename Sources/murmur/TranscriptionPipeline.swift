import AVFoundation
import Foundation

struct TranscriptSegment: Codable {
    let speaker: String
    let start: Double
    let end: Double
    var text: String
}

enum TranscriptionError: Error, CustomStringConvertible {
    case toolNotFound(String)
    case noAudio(URL)
    case toolFailed(String)
    case modelDownloadFailed(String)

    var description: String {
        switch self {
        case let .toolNotFound(path): return "не найден: \(path)"
        case let .noAudio(url): return "нет аудио в \(url.path)"
        case let .toolFailed(msg): return "распознавание завершилось с ошибкой: \(msg)"
        case let .modelDownloadFailed(msg): return "не удалось скачать модель: \(msg)"
        }
    }
}

enum TranscriptionEngine: Sendable {
    /// whisper.cpp `whisper-cli`: one call per track, no Dock icon, segment timestamps.
    case whisper(cli: String, model: String, language: String)
    /// Handy's `--transcribe-file`: one call per phrase (each one briefly shows Handy in the Dock).
    case handy(path: String)
}

/// Meeting folder -> transcript.md / transcript.json.
final class TranscriptionPipeline: @unchecked Sendable {
    static let sampleRate = 16_000.0
    /// Speaker label and candidate file names (`.aac` is current, `.m4a` is from older versions).
    static let tracks = [("Я", ["mic.aac", "mic.m4a"]), ("Собеседники", ["system.aac", "system.m4a"])]
    static let defaultModelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!

    let engine: TranscriptionEngine
    private let lock = NSLock()
    private var running: Process?
    private var cancelled = false

    init(engine: TranscriptionEngine) { self.engine = engine }

    /// Stops the pipeline and the running child process (e.g. on app quit).
    func cancel() {
        lock.lock()
        cancelled = true
        running?.terminate()
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// - Parameter progress: overall progress from 0 to 1.
    func run(folder: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        switch engine {
        case let .whisper(cli, model, _):
            guard FileManager.default.isExecutableFile(atPath: cli) else { throw TranscriptionError.toolNotFound(cli) }
            if !FileManager.default.fileExists(atPath: model) { try downloadModel(to: URL(fileURLWithPath: model)) }
        case let .handy(path):
            guard FileManager.default.isExecutableFile(atPath: path) else { throw TranscriptionError.toolNotFound(path) }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let available = Self.tracks.compactMap { speaker, names -> (String, URL)? in
            names.lazy.map { folder.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
                .map { (speaker, $0) }
        }
        guard !available.isEmpty else { throw TranscriptionError.noAudio(folder) }

        var segments: [TranscriptSegment] = []
        var loadedAny = false
        progress(0)
        // One track at a time keeps memory bounded to a single decoded track.
        for (trackIndex, (speaker, url)) in available.enumerated() {
            if isCancelled { throw CancellationError() }
            let samples: [Float]
            do {
                samples = try Self.loadMono16k(url)
                loadedAny = true
            } catch {
                log("skipping unreadable track \(url.lastPathComponent): \(error)")
                continue
            }
            let ranges = SpeechDetector.segments(samples, sampleRate: Self.sampleRate)
            let trackProgress = { (f: Double) in progress((Double(trackIndex) + f) / Double(available.count)) }
            let phrases: [TranscriptSegment]
            switch engine {
            case let .whisper(cli, model, language):
                phrases = try transcribeWhisper(samples, ranges: ranges, cli: cli, model: model, language: language, tmp: tmp)
            case let .handy(path):
                phrases = try transcribeHandy(samples, ranges: ranges, path: path, tmp: tmp, progress: trackProgress)
            }
            segments += phrases.map { TranscriptSegment(speaker: speaker, start: $0.start, end: $0.end, text: $0.text) }
            trackProgress(1)
        }
        guard loadedAny else { throw TranscriptionError.noAudio(folder) }

        segments.sort { $0.start < $1.start }
        segments = Self.removeEcho(segments)
        let json = try JSONEncoder.pretty.encode(segments)
        try json.write(to: folder.appendingPathComponent("transcript.json"))
        let md = folder.appendingPathComponent("transcript.md")
        try Self.markdown(segments, folder: folder).write(to: md, atomically: true, encoding: .utf8)
        return md
    }

    // MARK: whisper.cpp

    /// Speech ranges glued together with short gaps, plus a map back to original time.
    /// Feeding Whisper only speech avoids its hallucinations on silence and saves time.
    struct CompactedAudio {
        var samples: [Float] = []
        /// (offset in compacted audio, offset in original audio, length), in samples.
        var chunks: [(compact: Int, original: Int, length: Int)] = []

        init(_ source: [Float], ranges: [Range<Int>], gap: Int) {
            for r in ranges {
                chunks.append((samples.count, r.lowerBound, r.count))
                samples += source[r]
                samples += [Float](repeating: 0, count: gap)
            }
        }

        /// Maps a time in the compacted audio (seconds) to the original recording.
        func originalTime(_ t: Double, sampleRate: Double) -> Double {
            let pos = Int(t * sampleRate)
            guard let chunk = chunks.last(where: { $0.compact <= pos }) else { return 0 }
            let offset = min(pos - chunk.compact, chunk.length)
            return Double(chunk.original + offset) / sampleRate
        }
    }

    private func transcribeWhisper(_ samples: [Float], ranges: [Range<Int>], cli: String, model: String,
                                   language: String, tmp: URL) throws -> [TranscriptSegment] {
        guard !ranges.isEmpty else { return [] }
        let compact = CompactedAudio(samples, ranges: ranges, gap: Int(Self.sampleRate * 0.5))
        let wav = tmp.appendingPathComponent("track.wav")
        try Self.writeWav(compact.samples, to: wav)
        let prefix = tmp.appendingPathComponent("track")
        let seconds = Double(compact.samples.count) / Self.sampleRate
        let threads = max(4, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
        var args = ["-m", model, "-f", wav.path, "-l", language, "-t", "\(threads)",
                              "-oj", "-of", prefix.path, "-np", "-sns",
                              // No carry-over context: stops Whisper drifting into unpunctuated text or loops.
                              "-mc", "0"]
        // A punctuated prompt nudges Whisper to keep punctuation and capitalization.
        if let prompt = Self.prompts[language] { args += ["--prompt", prompt] }
        _ = try runTool(cli, args,
                        timeout: max(300, seconds * 2), errFile: tmp.appendingPathComponent("whisper.err"))

        let jsonURL = prefix.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        // whisper.cpp may cut a multi-byte character between tokens; decode leniently.
        let raw = String(decoding: try Data(contentsOf: jsonURL), as: UTF8.self)
        guard let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let items = obj["transcription"] as? [[String: Any]] else {
            throw TranscriptionError.toolFailed("непонятный JSON от whisper-cli")
        }
        return items.compactMap { item in
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let offsets = item["offsets"] as? [String: Any],
                  let from = (offsets["from"] as? NSNumber)?.doubleValue,
                  let to = (offsets["to"] as? NSNumber)?.doubleValue,
                  !Self.isHallucination(text) else { return nil }
            let start = compact.originalTime(from / 1000, sampleRate: Self.sampleRate)
            let end = max(start, compact.originalTime(to / 1000, sampleRate: Self.sampleRate))
            return TranscriptSegment(speaker: "", start: start, end: end, text: text)
        }
    }

    static let prompts = [
        "ru": "Привет! Давайте начнём встречу. Сначала обсудим задачи, потом — сроки.",
        "en": "Hi! Let's start the meeting. First, the tasks; then, the deadlines.",
    ]

    /// Typical Whisper output on noise/silence (learned from subtitled videos).
    static func isHallucination(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (raw.hasPrefix("[") && raw.hasSuffix("]")) || (raw.hasPrefix("(") && raw.hasSuffix(")")) { return true }
        let t = raw.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if t.isEmpty { return true }
        let markers = ["субтитр", "dimatorzok", "продолжение следует", "спасибо за просмотр",
                       "thanks for watching", "thank you for watching", "amara.org"]
        return markers.contains { t.contains($0) }
    }

    private func downloadModel(to dest: URL) throws {
        log("downloading whisper model to \(dest.path)")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Error?
        let task = URLSession.shared.downloadTask(with: Self.defaultModelURL) { tmpURL, response, error in
            defer { done.signal() }
            if let error { outcome = error; return }
            guard let tmpURL, (response as? HTTPURLResponse)?.statusCode == 200 else {
                outcome = TranscriptionError.modelDownloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmpURL, to: dest)
            } catch { outcome = error }
        }
        task.resume()
        while done.wait(timeout: .now() + 1) == .timedOut {
            if isCancelled { task.cancel(); throw CancellationError() }
        }
        if let outcome { throw TranscriptionError.modelDownloadFailed("\(outcome)") }
        log("whisper model downloaded")
    }

    // MARK: Handy

    private func transcribeHandy(_ samples: [Float], ranges: [Range<Int>], path: String, tmp: URL,
                                 progress: (Double) -> Void) throws -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for (i, range) in ranges.enumerated() {
            let wav = tmp.appendingPathComponent("seg.wav")
            try Self.writeWav(Array(samples[range]), to: wav)
            let seconds = Double(range.count) / Self.sampleRate
            let out = try runTool(path, ["--transcribe-file", wav.path, "--json"],
                                  timeout: max(120, seconds * 5), errFile: tmp.appendingPathComponent("handy.err"))
            // stdout is a single JSON object, but be tolerant of extra lines.
            let text = String(decoding: out, as: UTF8.self).split(separator: "\n").reversed().lazy
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .compactMap { $0["text"] as? String }.first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                result.append(TranscriptSegment(speaker: "", start: Double(range.lowerBound) / Self.sampleRate,
                                                end: Double(range.upperBound) / Self.sampleRate, text: text))
            }
            progress(Double(i + 1) / Double(ranges.count))
        }
        return result
    }

    // MARK: Child processes

    /// Runs a tool with a watchdog; returns stdout. Cancellation terminates it.
    private func runTool(_ path: String, _ args: [String], timeout: TimeInterval, errFile: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        // stderr goes to a file so a chatty child can never block on a full pipe.
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errFile)
        defer { try? errHandle.close() }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = errHandle

        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        try process.run()
        running = process
        lock.unlock()

        let name = URL(fileURLWithPath: path).lastPathComponent
        let watchdog = DispatchWorkItem { [weak process] in
            log("\(name) timed out after \(Int(timeout))s, terminating")
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        lock.lock(); running = nil; lock.unlock()

        if isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let err = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
            let lastLine = err.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
            throw TranscriptionError.toolFailed("\(name): \(lastLine)")
        }
        return data
    }

    // MARK: Audio helpers

    static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false) else {
            throw TranscriptionError.noAudio(url)
        }

        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) * sampleRate / inFormat.sampleRate) + 1024)
        let inBlock: AVAudioFrameCount = 48_000
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inBlock),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: inBlock),
              let monoConverter = AVAudioConverter(from: mono.format, to: outFormat),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: inBlock) else {
            throw TranscriptionError.noAudio(url)
        }

        var eof = false
        while !eof {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = monoConverter.convert(to: outBuffer, error: &error) { _, inputStatus in
                inBuffer.frameLength = 0
                do { try file.read(into: inBuffer, frameCount: inBlock) } catch { inBuffer.frameLength = 0 }
                guard inBuffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                downmix(inBuffer, into: mono)
                inputStatus.pointee = .haveData
                return mono
            }
            if let error { throw error }
            if let ch = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error { eof = true }
        }
        return result
    }

    private static func downmix(_ src: AVAudioPCMBuffer, into dst: AVAudioPCMBuffer) {
        let frames = Int(src.frameLength)
        let channels = Int(src.format.channelCount)
        guard let s = src.floatChannelData, let d = dst.floatChannelData?[0] else { return }
        let gain = 1 / Float(channels)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += s[c][i] }
            d[i] = sum * gain
        }
        dst.frameLength = AVAudioFrameCount(frames)
    }

    static func writeWav(_ samples: [Float], to url: URL) throws {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for s in samples { append(Int16(max(-1, min(1, s)) * 32767)) }
        try data.write(to: url)
    }

    // MARK: Output

    /// Without headphones the mic hears the speakers, so remote speech shows up twice.
    /// Drop mic phrases that overlap in time with system phrases and mostly repeat their words.
    static func removeEcho(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let me = tracks[0].0
        let remote = segments.filter { $0.speaker != me }
        return segments.filter { seg in
            guard seg.speaker == me else { return true }
            let words = wordSet(seg.text)
            guard !words.isEmpty else { return false }
            let nearby = remote.filter { $0.start < seg.end + 1.5 && $0.end > seg.start - 1.5 }
            let remoteWords = nearby.reduce(into: Set<String>()) { $0.formUnion(wordSet($1.text)) }
            let echoed = Double(words.intersection(remoteWords).count) / Double(words.count)
            return echoed < 0.6
        }
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { $0.count > 1 })
    }

    static func markdown(_ segments: [TranscriptSegment], folder: URL) -> String {
        var header = "# Встреча"
        if let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.dateFormat = "d MMMM yyyy, HH:mm"
            if let started = (meta["started_at"] as? String).flatMap(ISO8601DateFormatter().date(from:)) {
                header += " — \(f.string(from: started))"
            }
            let apps = (meta["apps"] as? [String] ?? []).filter { $0 != "manual" }
            if !apps.isEmpty { header += " · \(apps.joined(separator: ", "))" }
            if let d = meta["duration_sec"] as? Int { header += " · \(max(1, d / 60)) мин" }
        }

        // Merge consecutive phrases of the same speaker into paragraphs.
        var paragraphs: [TranscriptSegment] = []
        for seg in segments {
            if var last = paragraphs.last, last.speaker == seg.speaker, seg.start - last.end < 3 {
                last.text += " " + seg.text
                paragraphs[paragraphs.count - 1] = TranscriptSegment(speaker: last.speaker, start: last.start, end: seg.end, text: last.text)
            } else {
                paragraphs.append(seg)
            }
        }

        var out = header + "\n\n"
        if paragraphs.isEmpty { out += "_Речь не обнаружена._\n" }
        for p in paragraphs {
            out += "**[\(timestamp(p.start))] \(p.speaker):** \(p.text)\n\n"
        }
        return out
    }

    static func timestamp(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// Simple energy-based voice activity detection with an adaptive noise floor.
enum SpeechDetector {
    static func segments(_ samples: [Float], sampleRate: Double) -> [Range<Int>] {
        let frame = Int(sampleRate * 0.03)
        let frameCount = samples.count / frame
        guard frameCount > 0 else { return [] }

        var db = [Float](repeating: -100, count: frameCount)
        samples.withUnsafeBufferPointer { p in
            for f in 0..<frameCount {
                var sum: Float = 0
                for i in (f * frame)..<((f + 1) * frame) { sum += p[i] * p[i] }
                db[f] = 10 * log10(max(sum / Float(frame), 1e-10))
            }
        }
        let sorted = db.sorted()
        let noiseFloor = sorted[Int(Double(sorted.count) * 0.2)]
        // Cap the threshold so near-continuous speech is not mistaken for the noise floor.
        let threshold = min(max(noiseFloor + 10, -55), -40)

        let maxGapFrames = Int(0.8 / 0.03)      // pause that ends a phrase
        let minSpeechFrames = Int(0.3 / 0.03)   // drop clicks
        let padFrames = Int(0.25 / 0.03)
        let maxLenFrames = Int(30 / 0.03)       // split very long monologues for finer timestamps

        var ranges: [Range<Int>] = []
        var start: Int?
        var lastVoiced = 0
        for f in 0..<frameCount {
            if db[f] > threshold {
                if start == nil { start = f }
                lastVoiced = f
            }
            if let s = start {
                let ended = f - lastVoiced > maxGapFrames || f == frameCount - 1
                let tooLong = f - s >= maxLenFrames
                if ended || tooLong {
                    var end = ended ? lastVoiced + 1 : f
                    if tooLong && !ended {
                        // cut at the quietest frame in the last third
                        let window = (s + maxLenFrames * 2 / 3)..<f
                        end = window.min(by: { db[$0] < db[$1] }) ?? f
                    }
                    if end - s >= minSpeechFrames { ranges.append(s..<end) }
                    start = tooLong && !ended ? end : nil
                }
            }
        }

        return ranges.map { r in
            let lo = max(0, r.lowerBound - padFrames) * frame
            let hi = min(frameCount, r.upperBound + padFrames) * frame
            return lo..<hi
        }
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }()
}
