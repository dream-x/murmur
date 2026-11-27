import Foundation

enum SummaryProvider: String, CaseIterable, Sendable {
    /// GitHub Copilot CLI (`copilot -p`), uses the Copilot subscription.
    case copilot
    /// Claude Code (`claude -p`), uses the Claude subscription.
    case claude

    var title: String { self == .copilot ? "GitHub Copilot CLI" : "Claude Code" }
    var binaryName: String { rawValue }
    var models: [String] {
        switch self {
        case .copilot: return ["claude-sonnet-5.5", "claude-haiku-5.5", "claude-haiku-4.5", "gemini-3.8-flash"]
        case .claude: return ["haiku", "sonnet"]
        }
    }
}

/// transcript.md -> summary.md (summary, decisions, who owes what) via an LLM CLI agent.
final class Summarizer: @unchecked Sendable {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.npm-global/bin", "~/bin"]
        .map { NSString(string: $0).expandingTildeInPath }

    static let instructions = """
    Ты — ассистент, который разбирает расшифровки рабочих встреч. Это не задача по программированию: \
    просто проанализируй текст ниже и ответь в Markdown на русском. Ничего не выполняй и не используй инструменты.

    Расшифровка автоматическая, возможны ошибки распознавания — исправляй очевидные по смыслу. \
    «Я» — владелец записи, «Собеседники» — все остальные участники (разные люди в одной дорожке). \
    Имена определяй по контексту (обращения, «X, тебе слово», самопредставления). \
    Не выдумывай: если не ясно, кто ответственный или какой срок, пиши «не указан».

    Формат ответа (без вступлений и заключений, начинай сразу с первого заголовка):
    ## Кратко
    3–6 предложений: о чём встреча и чем закончилась.
    ## Участники
    Имена, кто выступал или упоминался, с ролью или темой, если понятно.
    ## Решения
    ## Кто кому что должен
    Таблица | Кто | Что сделать | Для кого | Срок |.
    ## Мои задачи
    Что должен сделать «Я» (владелец записи); если ничего — так и напиши.
    ## Открытые вопросы
    ## По темам
    Кратко по каждой обсуждавшейся теме.

    Расшифровка:

    """

    let provider: SummaryProvider
    let model: String
    private let lock = NSLock()
    private var running: Process?
    private var cancelled = false

    init(provider: SummaryProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    static func findBinary(_ provider: SummaryProvider) -> String? {
        searchPaths.map { "\($0)/\(provider.binaryName)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        running?.terminate()
        lock.unlock()
    }

    func run(folder: URL) throws -> URL {
        let transcriptURL = folder.appendingPathComponent("transcript.md")
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        guard let binary = Self.findBinary(provider) else {
            throw TranscriptionError.toolNotFound("\(provider.binaryName) (\(Self.searchPaths.joined(separator: ", ")))")
        }
        let prompt = Self.instructions + transcript

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // An empty working dir: the agent has no tools anyway, and must not pick up a project's instructions.
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        process.currentDirectoryURL = cwd

        let input = Pipe()
        switch provider {
        case .copilot:
            process.arguments = ["-p", prompt, "--model", model, "-s", "--available-tools", "",
                                 "--no-custom-instructions", "--no-ask-user"]
            process.standardInput = FileHandle.nullDevice
        case .claude:
            process.arguments = ["-p", "--model", model, "--no-session-persistence", "--tools", "",
                                 "--disable-slash-commands"]
            process.standardInput = input
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Self.searchPaths + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        process.environment = env

        let errURL = cwd.appendingPathComponent("err.log")
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

        if provider == .claude {
            DispatchQueue.global().async {
                input.fileHandleForWriting.write(Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
            }
        }
        let name = provider.binaryName
        let watchdog = DispatchWorkItem { [weak process] in
            log("\(name) timed out, terminating")
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        lock.lock(); running = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }

        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else {
            let err = ((try? String(contentsOf: errURL, encoding: .utf8)) ?? "") + text
            let last = err.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
            throw TranscriptionError.toolFailed("\(provider.binaryName): \(last)")
        }

        let title = transcript.split(separator: "\n").first.map { $0.replacingOccurrences(of: "# Встреча", with: "# Итоги встречи") }
            ?? "# Итоги встречи"
        let body = text.drop { $0 != "#" } // drop any chatter before the first heading
        let md = "\(title)\n\n\(body.isEmpty ? Substring(text) : body)\n\n---\n_\(provider.title) · \(model) · [расшифровка](transcript.md)_\n"
        let url = folder.appendingPathComponent("summary.md")
        try md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
