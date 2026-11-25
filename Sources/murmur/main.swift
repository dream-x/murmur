import AppKit
import ServiceManagement
import Foundation

let usage = """
murmur — automatic meeting recorder (mic + system audio)

USAGE:
  murmur                     run the menu bar app
  murmur record [--out DIR]  record right now until Ctrl-C
  murmur list                show processes using audio input
  murmur transcribe DIR      transcribe a recording folder via Handy
"""

private var signalSources: [DispatchSourceSignal] = []

func installSignalHandlers(_ handler: @escaping () -> Void) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler(handler: handler)
        src.resume()
        signalSources.append(src)
    }
}

let args = Array(CommandLine.arguments.dropFirst())

MainActor.assumeIsolated {
    switch args.first {
    case "record":
        var outDir = AppSettings.shared.outputDir
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            outDir = URL(fileURLWithPath: NSString(string: args[i + 1]).expandingTildeInPath)
        }
        do {
            let session = try RecordingSession(outputDir: outDir, apps: ["manual"])
            log("recording -> \(session.folder.path) (Ctrl-C to stop)")
            installSignalHandlers {
                session.stop(minDuration: 0)
                log("saved: \(session.folder.path)")
                exit(0)
            }
            RunLoop.main.run()
        } catch {
            log("failed: \(error)")
            exit(1)
        }

    case "list":
        for p in AudioProcesses.all() {
            print("\(p.isRunningInput ? "🎙 " : "   ") pid=\(p.pid) \(p.bundleID)")
        }

    case "transcribe":
        guard args.count > 1 else { print(usage); exit(1) }
        let folder = URL(fileURLWithPath: NSString(string: args[1]).expandingTildeInPath)
        do {
            let md = try TranscriptionPipeline(handyPath: AppSettings.shared.handyPath).run(folder: folder) { fraction in
                FileHandle.standardError.write("\r\(Int(fraction * 100))%".data(using: .utf8)!)
            }
            FileHandle.standardError.write("\n".data(using: .utf8)!)
            print(md.path)
        } catch {
            log("transcription failed: \(error)")
            exit(1)
        }

    case "unregister-login":
        try? SMAppService.mainApp.unregister()

    case "help", "--help", "-h":
        print(usage)

    default:
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dreamx.murmur"
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            log("Murmur is already running")
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        installSignalHandlers { NSApp.terminate(nil) }
        app.run()
    }
}
