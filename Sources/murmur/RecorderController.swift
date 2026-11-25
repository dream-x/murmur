import AppKit
import Foundation

/// Decides when to record: automatically while another app uses the mic, or manually via hotkey/menu.
@MainActor
final class RecorderController: ObservableObject {
    enum Mode { case auto, manual }

    @Published private(set) var session: RecordingSession?
    @Published private(set) var mode: Mode?
    @Published private(set) var micUsers: [String] = []
    private(set) var lastSaved: URL?

    var onChange: (() -> Void)?
    var onSaved: ((URL) -> Void)?

    private let settings: AppSettings
    private var activeSince: Date?
    private var inactiveSince: Date?
    /// Set when the user manually stops an auto recording; prevents immediate restart until the mic is released.
    private var suppressAuto = false
    private var timer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isRecording: Bool { session != nil }

    func startMonitoring() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common keeps ticking while the status menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func toggleManual() {
        if isRecording {
            if !micUsers.isEmpty { suppressAuto = true }
            stop()
        } else {
            start(mode: .manual, apps: micUsers.isEmpty ? ["manual"] : micUsers)
        }
    }

    func stop() {
        guard let session else { return }
        let minDuration = mode == .manual ? 0 : settings.minDuration
        if session.stop(minDuration: minDuration) {
            lastSaved = session.folder
            log("recording saved: \(session.folder.path)")
            onSaved?(session.folder)
        } else {
            log("recording discarded (shorter than \(Int(minDuration))s)")
        }
        self.session = nil
        mode = nil
        activeSince = nil
        inactiveSince = nil
        playSound("Pop")
        onChange?()
    }

    private func start(mode: Mode, apps: [String]) {
        do {
            let session = try RecordingSession(outputDir: settings.outputDir, apps: apps)
            self.session = session
            self.mode = mode
            log("recording started [\(mode)] (\(apps.joined(separator: ", "))) -> \(session.folder.lastPathComponent)")
            playSound("Tink")
        } catch {
            log("failed to start recording: \(error)")
        }
        onChange?()
    }

    private func tick() {
        let users = AudioProcesses.inputUsers(ignoring: settings.ignore)
        let names = Array(Set(users.map { displayName(for: $0) })).sorted()
        if names != micUsers {
            log("mic users: \(users.map { "\($0.bundleID)[\($0.pid)]" }.joined(separator: ", "))")
        }
        micUsers = names
        let now = Date()
        defer { onChange?() }

        if users.isEmpty { suppressAuto = false }
        if let session { session.noteApps(micUsers) }
        if mode == .manual { return }

        if !users.isEmpty {
            inactiveSince = nil
            guard session == nil, settings.autoRecord, !suppressAuto else { return }
            if activeSince == nil { activeSince = now }
            if now.timeIntervalSince(activeSince!) >= settings.startDelay {
                start(mode: .auto, apps: micUsers)
            }
        } else {
            activeSince = nil
            guard session != nil else { return }
            if inactiveSince == nil { inactiveSince = now }
            if now.timeIntervalSince(inactiveSince!) >= settings.stopDelay {
                stop()
            }
        }
    }

    private func displayName(for process: AudioProcessInfo) -> String {
        if let app = NSRunningApplication(processIdentifier: process.pid), let name = app.localizedName {
            return name.replacingOccurrences(of: " Helper", with: "").replacingOccurrences(of: " (Renderer)", with: "")
        }
        return process.bundleID
    }

    private func playSound(_ name: String) {
        guard settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
