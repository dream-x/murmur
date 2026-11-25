import AVFoundation
import Foundation

struct TranscriptSegment: Codable {
    let speaker: String
    let start: Double
    let end: Double
    var text: String
}

enum TranscriptionError: Error, CustomStringConvertible {
    case handyNotFound(String)
    case noAudio(URL)
    case handyFailed(String)

    var description: String {
        switch self {
        case let .handyNotFound(path): return "Handy не найден: \(path)"
        case let .noAudio(url): return "нет аудио в \(url.path)"
        case let .handyFailed(msg): return "handy завершился с ошибкой: \(msg)"
        }
    }
}

/// Meeting folder -> transcript.md / transcript.json, using Handy's headless `--transcribe-file` mode.
final class TranscriptionPipeline: @unchecked Sendable {
    static let sampleRate = 16_000.0
    /// Speaker label and candidate file names (`.aac` is current, `.m4a` is from older versions).
    static let tracks = [("Я", ["mic.aac", "mic.m4a"]), ("Собеседники", ["system.aac", "system.m4a"])]

    let handyPath: String
    private let lock = NSLock()
    private var running: Process?
    private var cancelled = false

    init(handyPath: String) { self.handyPath = handyPath }

    /// Stops the pipeline and the running handy process (e.g. on app quit).
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
        guard FileManager.default.isExecutableFile(atPath: handyPath) else {
            throw TranscriptionError.handyNotFound(handyPath)
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
            let samples: [Float]
            do {
                samples = try Self.loadMono16k(url)
                loadedAny = true
            } catch {
                log("skipping unreadable track \(url.lastPathComponent): \(error)")
                continue
            }
            let ranges = SpeechDetector.segments(samples, sampleRate: Self.sampleRate)
            for (i, range) in ranges.enumerated() {
                if isCancelled { throw CancellationError() }
                let wav = tmp.appendingPathComponent("seg.wav")
                try Self.writeWav(Array(samples[range]), to: wav)
                let seconds = Double(range.count) / Self.sampleRate
                let text = try transcribe(wav, timeout: max(120, seconds * 5)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(TranscriptSegment(speaker: speaker,
                                                      start: Double(range.lowerBound) / Self.sampleRate,
                                                      end: Double(range.upperBound) / Self.sampleRate,
                                                      text: text))
                }
                progress((Double(trackIndex) + Double(i + 1) / Double(ranges.count)) / Double(available.count))
            }
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

    private func transcribe(_ wav: URL, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: handyPath)
        process.arguments = ["--transcribe-file", wav.path, "--json"]
        // stderr goes to a file so a chatty child can never block on a full pipe.
        let errURL = wav.deletingPathExtension().appendingPathExtension("err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? errHandle.close() }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = errHandle

        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        try process.run()
        running = process
        lock.unlock()

        let watchdog = DispatchWorkItem { [weak process] in
            log("handy timed out after \(Int(timeout))s, terminating")
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        lock.lock(); running = nil; lock.unlock()

        if isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            throw TranscriptionError.handyFailed(err.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)")
        }
        // stdout is a single JSON object, but be tolerant of extra lines.
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let text = obj["text"] as? String {
                return text
            }
        }
        return ""
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
