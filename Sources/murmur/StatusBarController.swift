import AppKit
import Foundation

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let recorder: RecorderController
    private let transcriber: TranscriptionQueue
    private let settings: AppSettings
    private let openSettings: () -> Void
    private let menu = NSMenu()

    init(recorder: RecorderController, transcriber: TranscriptionQueue, settings: AppSettings,
         openSettings: @escaping () -> Void) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.settings = settings
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        refresh()
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        if let session = recorder.session {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Запись")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = false
            button.title = " " + formatElapsed(Date().timeIntervalSince(session.startedAt))
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else if transcriber.isBusy {
            button.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Расшифровка")
            button.image?.isTemplate = true
            button.title = " \(Int(transcriber.progress * 100))%"
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            let symbol = settings.autoRecord ? "mic" : "mic.slash"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
            button.image?.isTemplate = true
            button.title = ""
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if let session = recorder.session {
            let apps = session.apps.filter { $0 != "manual" }.sorted().joined(separator: ", ")
            let kind = recorder.mode == .manual ? "Ручная запись" : "Запись встречи"
            status = "● \(kind) · \(formatElapsed(Date().timeIntervalSince(session.startedAt)))" + (apps.isEmpty ? "" : " · \(apps)")
        } else if !settings.autoRecord {
            status = "Автозапись выключена"
        } else if !recorder.micUsers.isEmpty {
            status = "Микрофон занят: \(recorder.micUsers.joined(separator: ", "))"
        } else {
            status = "Ожидание встречи…"
        }
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let current = transcriber.current {
            var text = "Расшифровка: \(current.lastPathComponent) · \(Int(transcriber.progress * 100))%"
            if transcriber.queuedCount > 0 { text += " (+\(transcriber.queuedCount) в очереди)" }
            let t = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            t.isEnabled = false
            menu.addItem(t)
        }
        menu.addItem(.separator())

        let toggle = item(recorder.isRecording ? "Остановить запись" : "Начать запись",
                          symbol: recorder.isRecording ? "stop.circle" : "record.circle",
                          action: #selector(toggleRecording))
        if let hk = settings.hotKey { toggle.title += "    \(hk.display)" }
        menu.addItem(toggle)

        let auto = item("Автозапись встреч", symbol: "waveform", action: #selector(toggleAuto))
        auto.state = settings.autoRecord ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())

        menu.addItem(item("Открыть папку записей", symbol: "folder", action: #selector(openFolder), key: "o"))
        let recentItem = NSMenuItem(title: "Последние записи", action: nil, keyEquivalent: "")
        recentItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        recentItem.submenu = recentMenu()
        menu.addItem(recentItem)
        menu.addItem(.separator())

        menu.addItem(item("Настройки…", symbol: "gearshape", action: #selector(showSettings), key: ","))
        menu.addItem(item("Выйти", symbol: "power", action: #selector(quit), key: "q"))
    }

    private func recentMenu() -> NSMenu {
        let sub = NSMenu()
        let recordings = RecordingInfo.list(in: settings.outputDir, limit: 15)
            .filter { $0.folder.standardizedFileURL != recorder.session?.folder.standardizedFileURL }
        if recordings.isEmpty {
            let empty = NSMenuItem(title: "Пока нет записей", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        }
        for rec in recordings {
            let transcript = rec.folder.appendingPathComponent("transcript.md")
            let hasTranscript = FileManager.default.fileExists(atPath: transcript.path)
            let queued = transcriber.isQueued(rec.folder)
            let mi = NSMenuItem(title: rec.title, action: nil, keyEquivalent: "")
            mi.image = NSImage(systemSymbolName: queued ? "hourglass" : (hasTranscript ? "doc.text" : "waveform"),
                               accessibilityDescription: nil)
            let actions = NSMenu()
            if hasTranscript {
                let open = item("Открыть расшифровку", symbol: "doc.text", action: #selector(openTranscript(_:)))
                open.representedObject = transcript
                actions.addItem(open)
            }
            let reveal = item("Показать в Finder", symbol: "folder", action: #selector(revealRecording(_:)))
            reveal.representedObject = rec.folder
            actions.addItem(reveal)
            let run = item(hasTranscript ? "Расшифровать заново" : "Расшифровать", symbol: "text.bubble",
                           action: #selector(transcribeRecording(_:)))
            run.representedObject = rec.folder
            run.isEnabled = !queued
            actions.addItem(run)
            mi.submenu = actions
            sub.addItem(mi)
        }
        return sub
    }

    private func item(_ title: String, symbol: String?, action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return mi
    }

    // MARK: Actions

    @objc private func toggleRecording() { recorder.toggleManual() }

    @objc private func toggleAuto() {
        settings.autoRecord.toggle()
        refresh()
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: settings.outputDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.outputDir)
    }

    @objc private func revealRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openTranscript(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func transcribeRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        transcriber.enqueue(url)
    }

    @objc private func showSettings() { openSettings() }

    @objc private func quit() {
        recorder.stop()
        NSApp.terminate(nil)
    }
}

func formatElapsed(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%02d:%02d", s / 60, s % 60)
}

struct RecordingInfo {
    let folder: URL
    let title: String

    static func list(in dir: URL, limit: Int) -> [RecordingInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let display = DateFormatter()
        display.locale = Locale(identifier: "ru_RU")
        display.dateFormat = "d MMM, HH:mm"

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .map { folder in
                var title = folder.lastPathComponent
                if let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
                   let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let started = (meta["started_at"] as? String).flatMap(ISO8601DateFormatter().date(from:)) {
                    var parts = [display.string(from: started)]
                    let apps = (meta["apps"] as? [String] ?? []).filter { $0 != "manual" }
                    if !apps.isEmpty { parts.append(apps.joined(separator: ", ")) }
                    if let d = meta["duration_sec"] as? Int { parts.append(d >= 60 ? "\(d / 60) мин" : "\(d) с") }
                    title = parts.joined(separator: " · ")
                }
                return RecordingInfo(folder: folder, title: title)
            }
    }
}
