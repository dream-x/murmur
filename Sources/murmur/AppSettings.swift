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
    /// "whisper" or "handy".
    @Published var engine: String { didSet { defaults.set(engine, forKey: "engine") } }
    @Published var whisperPath: String { didSet { defaults.set(whisperPath, forKey: "whisperPath") } }
    @Published var whisperModel: String { didSet { defaults.set(whisperModel, forKey: "whisperModel") } }
    /// Whisper language code ("ru", "en", …) or "auto".
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
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
            "engine": "whisper",
            "whisperPath": ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
                .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/whisper-cli",
            "whisperModel": "~/Library/Application Support/Murmur/models/ggml-large-v3-turbo-q5_0.bin",
            "language": "auto",
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
        engine = defaults.string(forKey: "engine")!
        whisperPath = defaults.string(forKey: "whisperPath")!
        whisperModel = defaults.string(forKey: "whisperModel")!
        language = defaults.string(forKey: "language")!
        if let data = defaults.data(forKey: "hotKey") {
            hotKey = data.isEmpty ? nil : try? JSONDecoder().decode(HotKeyCombo.self, from: data)
        } else {
            hotKey = .defaultCombo
        }
    }

    var outputDir: URL {
        URL(fileURLWithPath: NSString(string: outputPath).expandingTildeInPath, isDirectory: true)
    }

    var transcriptionEngine: TranscriptionEngine {
        engine == "handy"
            ? .handy(path: handyPath)
            : .whisper(cli: NSString(string: whisperPath).expandingTildeInPath, model: NSString(string: whisperModel).expandingTildeInPath, language: language)
    }

    var ignore: [String] {
        Self.builtinIgnore + ignoreList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
