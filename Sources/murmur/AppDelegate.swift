import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private lazy var recorder = RecorderController(settings: settings)
    private lazy var transcriber = TranscriptionQueue(settings: settings)
    private lazy var settingsWindow = SettingsWindowController(settings: settings)
    private var statusBar: StatusBarController?
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(recorder: recorder, transcriber: transcriber, settings: settings) { [weak self] in
            self?.settingsWindow.show()
        }
        recorder.onChange = { [weak self] in self?.statusBar?.refresh() }
        transcriber.onChange = { [weak self] in self?.statusBar?.refresh() }
        recorder.onSaved = { [weak self] folder in
            guard let self, self.settings.autoTranscribe else { return }
            self.transcriber.enqueue(folder)
        }

        hotKey = GlobalHotKey { [weak self] in
            MainActor.assumeIsolated { self?.recorder.toggleManual() }
        }
        settings.$hotKey.combineLatest(settings.$capturingHotKey)
            .sink { [weak self] combo, capturing in self?.hotKey?.register(capturing ? nil : combo) }
            .store(in: &cancellables)

        enableLaunchAtLoginOnFirstRun()
        recorder.startMonitoring()
        log("Murmur started; recordings -> \(settings.outputDir.path)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.stop()
        transcriber.cancelAll()
    }

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didConfigureLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        do { try SMAppService.mainApp.register() } catch { log("launch at login: \(error)") }
    }
}
