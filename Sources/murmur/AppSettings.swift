import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
    ]
    private static let namedKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// Builds a combo from a key event; plain keys need at least one modifier, F-keys may go alone.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isFunctionKey = Self.functionKeys[event.keyCode] != nil
        guard !flags.isEmpty || isFunctionKey else { return nil }

        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }

        let key = Self.functionKeys[event.keyCode]
            ?? Self.namedKeys[event.keyCode]
            ?? event.charactersIgnoringModifiers?.uppercased()
            ?? "?"
        keyCode = UInt32(event.keyCode)
        carbonModifiers = carbon
        display = symbols + key
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    static let defaultCombo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_R),
                                          carbonModifiers: UInt32(controlKey | optionKey),
                                          display: "⌃⌥R")
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let builtinIgnore = ["com.apple.CoreSpeech", "corespeechd", "com.apple.siri", "com.apple.assistant",
                                "com.apple.SpeechRecognitionCore", "com.apple.dictation", "com.apple.accessibility",
                                "com.apple.controlcenter", "com.apple.voicememos"]

    private let defaults = UserDefaults.standard

    @Published var outputPath: String { didSet { defaults.set(outputPath, forKey: "outputPath") } }
    @Published var autoRecord: Bool { didSet { defaults.set(autoRecord, forKey: "autoRecord") } }
    @Published var startDelay: Double { didSet { defaults.set(startDelay, forKey: "startDelay") } }
    @Published var stopDelay: Double { didSet { defaults.set(stopDelay, forKey: "stopDelay") } }
    @Published var minDuration: Double { didSet { defaults.set(minDuration, forKey: "minDuration") } }
    @Published var ignoreList: String { didSet { defaults.set(ignoreList, forKey: "ignoreList") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var autoTranscribe: Bool { didSet { defaults.set(autoTranscribe, forKey: "autoTranscribe") } }
    @Published var handyPath: String { didSet { defaults.set(handyPath, forKey: "handyPath") } }
    @Published var hotKey: HotKeyCombo? {
        didSet {
            if let hotKey, let data = try? JSONEncoder().encode(hotKey) {
                defaults.set(data, forKey: "hotKey")
            } else {
                defaults.set(Data(), forKey: "hotKey")
            }
        }
    }
    /// True while the settings window is capturing a new shortcut (global hotkey is paused).
    @Published var capturingHotKey = false

    private init() {
        defaults.register(defaults: [
            "outputPath": "~/Recordings/Meetings",
            "autoRecord": true,
            "startDelay": 3.0,
            "stopDelay": 15.0,
            "minDuration": 30.0,
            "ignoreList": "com.pais.handy",
            "playSounds": true,
            "autoTranscribe": true,
            "handyPath": "/Applications/Handy.app/Contents/MacOS/handy",
        ])
        outputPath = defaults.string(forKey: "outputPath")!
        autoRecord = defaults.bool(forKey: "autoRecord")
        startDelay = defaults.double(forKey: "startDelay")
        stopDelay = defaults.double(forKey: "stopDelay")
        minDuration = defaults.double(forKey: "minDuration")
        ignoreList = defaults.string(forKey: "ignoreList")!
        playSounds = defaults.bool(forKey: "playSounds")
        autoTranscribe = defaults.bool(forKey: "autoTranscribe")
        handyPath = defaults.string(forKey: "handyPath")!
        if let data = defaults.data(forKey: "hotKey") {
            hotKey = data.isEmpty ? nil : try? JSONDecoder().decode(HotKeyCombo.self, from: data)
        } else {
            hotKey = .defaultCombo
        }
    }

    var outputDir: URL {
        URL(fileURLWithPath: NSString(string: outputPath).expandingTildeInPath, isDirectory: true)
    }

    var ignore: [String] {
        Self.builtinIgnore + ignoreList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
