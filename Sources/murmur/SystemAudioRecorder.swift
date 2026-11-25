import AVFoundation
import CoreAudio
import Foundation

/// Records all system output audio (other meeting participants) via a global Core Audio process tap.
///
/// The private aggregate device contains only the tap (no hardware sub-device), so headset inputs are
/// never activated and the capture keeps working when the output device changes. If the tap format
/// changes (e.g. switching to a device with another sample rate) the capture is rebuilt and the writer
/// resamples into the file's fixed format. All control methods must be called on the main thread.
final class SystemAudioRecorder {
    private var writer: AudioFileWriter?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func start(to url: URL) throws {
        writer = try AudioFileWriter(url: url, sampleRate: 48_000, channels: 2, label: "system")
        try startCapture()
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    func stop() {
        removeListeners()
        stopCapture()
        writer?.close()
        writer = nil
    }

    private func startCapture() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Murmur Tap"
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmur Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")

        var asbd: AudioStreamBasicDescription = try readValue(tapID, kAudioTapPropertyFormat,
                                                              default: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError.status("tap format", -1)
        }
        tapFormat = format
        let writer = self.writer
        // The tap's streams are the last buffers of the aggregate's input list.
        let tapBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inInput, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            guard list.count >= tapBufferCount, let first = list.last, first.mDataByteSize > 0 else { return }
            let frames = first.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame
            guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            copy.frameLength = frames
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (i, src) in list.suffix(tapBufferCount).enumerated() where i < dst.count {
                guard let s = src.mData, let d = dst[i].mData else { continue }
                memcpy(d, s, Int(min(src.mDataByteSize, dst[i].mDataByteSize)))
            }
            writer?.write(copy)
        }, "AudioDeviceCreateIOProcIDWithBlock")

        try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        addListener(tapID, kAudioTapPropertyFormat)
    }

    private func stopCapture() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func restartCapture(reason: String) {
        guard writer != nil else { return }
        log("system audio: \(reason), restarting capture")
        removeListeners(on: tapID)
        stopCapture()
        do { try startCapture() } catch { log("system audio restart failed: \(error)") }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var addr = address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if selector == kAudioTapPropertyFormat {
                var asbd = (try? readValue(self.tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription()))
                    ?? AudioStreamBasicDescription()
                if let new = AVAudioFormat(streamDescription: &asbd), new == self.tapFormat { return }
                self.restartCapture(reason: "tap format changed")
            } else {
                self.restartCapture(reason: "output device changed")
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &addr, .main, block) == noErr {
            listeners.append((object, addr, block))
        }
    }

    private func removeListeners(on object: AudioObjectID? = nil) {
        listeners.removeAll { entry in
            guard object == nil || entry.0 == object else { return false }
            var addr = entry.1
            AudioObjectRemovePropertyListenerBlock(entry.0, &addr, .main, entry.2)
            return true
        }
    }
}
