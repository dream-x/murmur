import CoreAudio
import Foundation

enum CoreAudioError: Error, CustomStringConvertible {
    case status(String, OSStatus)

    var description: String {
        switch self {
        case let .status(what, code): return "\(what) failed: OSStatus \(code) (\(fourCC(code)))"
        }
    }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError.status(what, status) }
}

private func fourCC(_ code: OSStatus) -> String {
    let n = UInt32(bitPattern: code)
    let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((n >> $0) & 0xFF))) }
    return String(chars)
}

func address(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) throws -> T {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var result = value
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result), "get \(fourCC(OSStatus(bitPattern: selector)))")
    return result
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func readArray(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var addr = address(selector)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "size")
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids), "array")
    return ids
}

struct AudioProcessInfo {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
}

enum AudioProcesses {
    static func all() -> [AudioProcessInfo] {
        guard let ids = try? readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) else {
            return []
        }
        return ids.compactMap { id in
            guard let pid: pid_t = try? readValue(id, kAudioProcessPropertyPID, default: pid_t(0)) else { return nil }
            let running: UInt32 = (try? readValue(id, kAudioProcessPropertyIsRunningInput, default: UInt32(0))) ?? 0
            let bundle = readString(id, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 } ?? processName(pid)
            return AudioProcessInfo(objectID: id, pid: pid, bundleID: bundle, isRunningInput: running != 0)
        }
    }

    /// Processes other than ourselves that currently capture audio input.
    static func inputUsers(ignoring ignored: [String]) -> [AudioProcessInfo] {
        let me = getpid()
        return all().filter { p in
            p.isRunningInput && p.pid != me && p.bundleID != ownBundleID && !ignored.contains(where: { p.bundleID.localizedCaseInsensitiveContains($0) })
        }
    }

    static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.dreamx.murmur"

    static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0
            ? URL(fileURLWithPath: String(cString: buf)).lastPathComponent
            : "pid\(pid)"
    }
}

enum AudioDevices {
    static func defaultOutputUID() throws -> String {
        let id: AudioDeviceID = try readValue(AudioObjectID(kAudioObjectSystemObject),
                                              kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              default: AudioDeviceID(0))
        guard let uid = readString(id, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError.status("read output device UID", -1)
        }
        return uid
    }
}
