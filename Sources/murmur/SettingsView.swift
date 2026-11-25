import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Запись") {
                LabeledContent("Папка") {
                    HStack {
                        Text(settings.outputPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Выбрать…", action: chooseFolder)
                    }
                }
                LabeledContent("Горячая клавиша") {
                    HotKeyRecorder(settings: settings)
                }
                Toggle("Звук при начале и конце записи", isOn: $settings.playSounds)
            }

            Section("Автозапись встреч") {
                Toggle("Записывать, когда приложение использует микрофон", isOn: $settings.autoRecord)
                Stepper(value: $settings.startDelay, in: 0...60, step: 1) {
                    LabeledContent("Начинать через", value: "\(Int(settings.startDelay)) с")
                }
                Stepper(value: $settings.stopDelay, in: 1...300, step: 5) {
                    LabeledContent("Останавливать через", value: "\(Int(settings.stopDelay)) с тишины микрофона")
                }
                Stepper(value: $settings.minDuration, in: 0...600, step: 10) {
                    LabeledContent("Удалять записи короче", value: "\(Int(settings.minDuration)) с")
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Игнорировать приложения", text: $settings.ignoreList)
                    Text("Bundle ID через запятую — их использование микрофона не запускает запись.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Расшифровка (Handy)") {
                Toggle("Автоматически расшифровывать после записи", isOn: $settings.autoTranscribe)
                LabeledContent("Handy") {
                    HStack {
                        Image(systemName: handyInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(handyInstalled ? .green : .orange)
                        Text(settings.handyPath).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Button("Выбрать…", action: chooseHandy)
                    }
                }
                Text("Используется модель, выбранная в настройках Handy. Результат — transcript.md в папке встречи.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Система") {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.outputDir
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputPath = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private var handyInstalled: Bool { FileManager.default.isExecutableFile(atPath: settings.handyPath) }

    private func chooseHandy() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Выбрать"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension == "app", let exe = Bundle(url: url)?.executableURL {
            settings.handyPath = exe.path
        } else {
            settings.handyPath = url.path
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct HotKeyRecorder: View {
    @ObservedObject var settings: AppSettings
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { settings.capturingHotKey ? stopCapture() : startCapture() }) {
                Text(settings.capturingHotKey ? "Нажмите сочетание…" : (settings.hotKey?.display ?? "Не задана"))
                    .frame(minWidth: 130)
            }
            if settings.hotKey != nil && !settings.capturingHotKey {
                Button { settings.hotKey = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Убрать горячую клавишу")
            }
        }
        .onDisappear(perform: stopCapture)
    }

    private func startCapture() {
        settings.capturingHotKey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels
                stopCapture()
            } else if let combo = HotKeyCombo(event: event) {
                settings.hotKey = combo
                stopCapture()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        settings.capturingHotKey = false
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Murmur — Настройки"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
