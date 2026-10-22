import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Core Audio device enumeration, plus a notification when devices come and go.
enum AudioDevices {
    static let didChange = Notification.Name("YaprAudioDevicesDidChange")

    static func inputs() -> [AudioDevice] { all().filter { channelCount($0.id, scope: kAudioObjectPropertyScopeInput) > 0 } }
    static func outputs() -> [AudioDevice] { all().filter { channelCount($0.id, scope: kAudioObjectPropertyScopeOutput) > 0 } }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return all().first { $0.uid == uid }?.id
    }

    /// The connected device a saved choice refers to. Exact UID first; then, because a USB device's UID embeds the
    /// port it is plugged into (AppleUSBAudioEngine:vendor:product:location:n), the same device on another port;
    /// then a device with the same name.
    static func match(uid: String, name: String, in devices: [AudioDevice]) -> AudioDevice? {
        guard !uid.isEmpty else { return nil }
        if let exact = devices.first(where: { $0.uid == uid }) { return exact }
        let key = portIndependentKey(uid)
        if let moved = devices.first(where: { portIndependentKey($0.uid) == key }) { return moved }
        return name.isEmpty ? nil : devices.first { $0.name == name }
    }

    private static func portIndependentKey(_ uid: String) -> String {
        var parts = uid.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard uid.hasPrefix("AppleUSBAudioEngine:"), parts.count >= 5 else { return uid }
        parts[parts.count - 2] = "*"
        return parts.joined(separator: ":")
    }

    static func startObserving() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
