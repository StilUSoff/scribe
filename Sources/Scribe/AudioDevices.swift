import CoreAudio
import Foundation

/// Устройство ввода звука (микрофон) в системе.
struct AudioInputDevice: Hashable, Identifiable {
    let id: AudioDeviceID
    /// Постоянный идентификатор — по нему запоминаем выбор пользователя (AudioDeviceID меняется между запусками).
    let uid: String
    let name: String
    let isBuiltIn: Bool
}

/// Обёртка над CoreAudio: список микрофонов, микрофон по умолчанию, уведомление о его смене.
enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func inputs() -> [AudioInputDevice] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { inputChannels($0) > 0 }.map(device)
    }

    static func defaultInput() -> AudioInputDevice? {
        var id = AudioDeviceID(0)
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return device(id)
    }

    static func device(uid: String) -> AudioInputDevice? {
        inputs().first { $0.uid == uid }
    }

    static func builtIn() -> AudioInputDevice? {
        inputs().first(where: \.isBuiltIn)
    }

    /// Вызывать block при смене микрофона по умолчанию в системе. Очередь — не главная: снятие слушателя ждёт
    /// завершения уже запущенного вызова, и если тот стоит в очереди главного потока — взаимная блокировка.
    static func addDefaultInputListener(queue: DispatchQueue, _ block: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in block() }
        AudioObjectAddPropertyListenerBlock(system, &address, queue, listener)
        return listener
    }

    static func removeDefaultInputListener(_ listener: @escaping AudioObjectPropertyListenerBlock, queue: DispatchQueue) {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectRemovePropertyListenerBlock(system, &address, queue, listener)
    }

    // MARK: - CoreAudio

    private static func device(_ id: AudioDeviceID) -> AudioInputDevice {
        var transport = UInt32(0)
        var address = Self.address(kAudioDevicePropertyTransportType)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return AudioInputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID),
                                name: string(id, kAudioObjectPropertyName),
                                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
