import AVFoundation
import Foundation

/// Records the default input device (your microphone) and follows device changes (e.g. AirPods connect).
/// All control methods and engine mutations happen on the main thread.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var observer: NSObjectProtocol?
    private var retryWork: DispatchWorkItem?
    private var retryCount = 0

    func start(to url: URL) throws {
        writer = try AudioFileWriter(url: url, sampleRate: 48_000, channels: 1, label: "mic")
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            log("mic configuration changed, restarting input")
            self?.restart()
        }
        restart()
    }

    func stop() {
        retryWork?.cancel()
        retryWork = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
        writer = nil
    }

    private func restart() {
        guard writer != nil else { return }
        retryWork?.cancel()
        do {
            try startEngine()
            retryCount = 0
        } catch {
            // Input often reports 0 Hz for a moment while Bluetooth routes switch; retry with backoff.
            retryCount += 1
            let delay = min(Double(retryCount), 10)
            log("mic start failed (\(error)), retrying in \(Int(delay))s")
            let work = DispatchWorkItem { [weak self] in self?.restart() }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func startEngine() throws {
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0, let writer else {
            throw CoreAudioError.status("no input device", -1)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            // Keep only the first channel; the writer resamples to the file format.
            guard let copy = buffer.deepCopy() else { return }
            writer.write(copy.firstChannel() ?? copy)
        }
        engine.prepare()
        try engine.start()
    }
}

private extension AVAudioPCMBuffer {
    func firstChannel() -> AVAudioPCMBuffer? {
        guard format.channelCount > 1, !format.isInterleaved,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frameLength),
              let src = floatChannelData?[0], let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = frameLength
        memcpy(dst, src, Int(frameLength) * MemoryLayout<Float>.size)
        return out
    }
}
