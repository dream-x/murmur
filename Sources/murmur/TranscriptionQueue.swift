import AppKit
import Foundation
import UserNotifications

/// Runs transcriptions one at a time in the background and reports progress to the menu bar.
@MainActor
final class TranscriptionQueue: NSObject, UNUserNotificationCenterDelegate {
    private(set) var current: URL?
    private(set) var progress = 0.0
    private var pipeline: TranscriptionPipeline?
    private var pending: [URL] = []
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
        current == folder || pending.contains(folder)
    }

    func enqueue(_ folder: URL) {
        guard !isQueued(folder) else { return }
        pending.append(folder)
        startNext()
    }

    private func startNext() {
        guard current == nil, !pending.isEmpty else { onChange?(); return }
        let folder = pending.removeFirst()
        current = folder
        progress = 0
        onChange?()

        let pipeline = TranscriptionPipeline(handyPath: settings.handyPath)
        self.pipeline = pipeline
        log("transcribing \(folder.lastPathComponent)")
        worker.async { [weak self] in
            let started = Date()
            let result = Result {
                try pipeline.run(folder: folder) { fraction in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.progress = fraction
                            self?.onChange?()
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(folder, result, seconds: Date().timeIntervalSince(started)) }
            }
        }
    }

    private func finish(_ folder: URL, _ result: Result<URL, Error>, seconds: TimeInterval) {
        switch result {
        case let .success(md):
            log("transcript ready in \(Int(seconds))s: \(md.path)")
            notify(title: "Расшифровка готова", body: folder.lastPathComponent, file: md)
        case .failure(is CancellationError):
            log("transcription cancelled: \(folder.lastPathComponent)")
        case let .failure(error):
            log("transcription failed for \(folder.lastPathComponent): \(error)")
            notify(title: "Ошибка расшифровки", body: "\(error)", file: nil)
        }
        current = nil
        pipeline = nil
        startNext()
    }

    /// Stops the running job (its handy process included) and drops the queue.
    func cancelAll() {
        pending.removeAll()
        pipeline?.cancel()
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
