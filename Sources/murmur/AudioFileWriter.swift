import AVFoundation
import Foundation

/// Serial, thread-safe writer that converts incoming buffers to the file's fixed format.
///
/// Recordings are written as ADTS AAC (`.aac`): every frame is self-contained, so the file
/// stays readable even if the app crashes or is killed mid-meeting (unlike `.m4a`).
final class AudioFileWriter: @unchecked Sendable {
    let format: AVAudioFormat
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let queue: DispatchQueue

    init(url: URL, sampleRate: Double, channels: AVAudioChannelCount, label: String) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: channels, interleaved: false) else {
            throw CoreAudioError.status("writer format", -1)
        }
        self.format = format
        queue = DispatchQueue(label: "murmur.writer.\(label)")
        file = try AVAudioFile(forWriting: url, settings: aacSettings(sampleRate: sampleRate, channels: channels),
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Takes ownership of `buffer` (it must not be reused by the caller).
    func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard let file else { return }
            do {
                if buffer.format == format {
                    try file.write(from: buffer)
                } else if let converted = convert(buffer) {
                    try file.write(from: converted)
                }
            } catch {
                log("write error: \(error)")
            }
        }
    }

    func close() {
        queue.sync { file = nil }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            if buffer.format.channelCount == 1, format.channelCount == 2 {
                converter?.channelMap = [0, 0]
            }
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { log("convert error: \(error)"); return nil }
        return out
    }
}

func aacSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
    [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: channels > 1 ? 128_000 : 64_000,
    ]
}

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sData = s.mData, let dData = d.mData else { continue }
            memcpy(dData, sData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }
}
