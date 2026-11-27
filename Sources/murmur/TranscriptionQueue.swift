import AppKit
import Foundation
import UserNotifications

/// Runs transcriptions (and summaries) one at a time in the background and reports progress to the menu bar.
@MainActor
final class TranscriptionQueue: NSObject, UNUserNotificationCenterDelegate {
    enum Job { case transcribe, summarize }

    private(set) var current: URL?
    private(set) var stage = ""
    private(set) var progress = 0.0
    private var pipeline: TranscriptionPipeline?
    private var summarizer: Summarizer?
    private var pending: [(URL, Job)] = []
    private let settings: AppSettings
    private let worker = DispatchQueue(label: "murmur.transcription", qos: .utility)
    var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var isBusy: Bool { current != nil }
    var queuedCount: Int { pending.count }

    func isQueued(_ folder: URL) -> Bool {
        current == folder || pending.contains { $0.0 == folder }
    }

    /// `.transcribe` also summarizes afterwards when auto-summary is on.
    func enqueue(_ folder: URL, _ job: Job = .transcribe) {
        guard !isQueued(folder) else { return }
        pending.append((folder, job))
        startNext()
    }

    private func setStage(_ name: String, _ fraction: Double) {
        stage = name
        progress = fraction
        onChange?()
    }

    private func startNext() {
        guard current == nil, !pending.isEmpty else { onChange?(); return }
        let (folder, job) = pending.removeFirst()
        current = folder

        let pipeline = job == .transcribe ? TranscriptionPipeline(engine: settings.transcriptionEngine) : nil
        let summarizer = job == .summarize || settings.autoSummarize ? settings.makeSummarizer() : nil
        self.pipeline = pipeline
        self.summarizer = summarizer
        setStage(pipeline != nil ? "Расшифровка" : "Саммари", 0)
        log("\(pipeline != nil ? "transcribing" : "summarizing") \(folder.lastPathComponent)")

        worker.async { [weak self] in
            let started = Date()
            let report: @Sendable (String, Double) -> Void = { name, fraction in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setStage(name, fraction) } }
            }
            var transcript: Result<URL, Error>?
            if let pipeline {
                transcript = Result { try pipeline.run(folder: folder) { report("Расшифровка", $0) } }
            }
            var summary: Result<URL, Error>?
            if let summarizer, (try? transcript?.get()) != nil || transcript == nil {
                report("Саммари", 0)
                summary = Result { try summarizer.run(folder: folder) }
            }
            let seconds = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(folder, transcript: transcript, summary: summary, seconds: seconds) }
            }
        }
    }

    private func finish(_ folder: URL, transcript: Result<URL, Error>?, summary: Result<URL, Error>?, seconds: TimeInterval) {
        let name = folder.lastPathComponent
        var done: URL?
        if case let .failure(error)? = transcript {
            if error is CancellationError { log("transcription cancelled: \(name)") } else {
                log("transcription failed for \(name): \(error)")
                notify(title: "Ошибка расшифровки", body: "\(error)", file: nil)
            }
        } else if case let .success(md)? = transcript {
            log("transcript ready: \(md.path)")
            done = md
        }
        switch summary {
        case let .success(md)?:
            log("summary ready: \(md.path)")
            done = md
        case .failure(is CancellationError)?:
            log("summary cancelled: \(name)")
        case let .failure(error)?:
            log("summary failed for \(name): \(error)")
            notify(title: "Ошибка саммари", body: "\(error)", file: nil)
        case nil:
            break
        }
        if let done {
            log("done in \(Int(seconds))s: \(name)")
            let title = done.lastPathComponent == "summary.md" ? "Итоги встречи готовы" : "Расшифровка готова"
            notify(title: title, body: name, file: done)
        }
        current = nil
        pipeline = nil
        summarizer = nil
        startNext()
    }

    /// Stops the running job (its child process included) and drops the queue.
    func cancelAll() {
        pending.removeAll()
        pipeline?.cancel()
        summarizer?.cancel()
    }

    private func notify(title: String, body: String, file: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let file { content.userInfo = ["file": file.path] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["file"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
