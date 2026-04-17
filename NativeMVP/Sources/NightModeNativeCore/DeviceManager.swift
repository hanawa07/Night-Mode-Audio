import AudioToolbox
import CoreAudio
import Foundation

public func readPropertyDataSize(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress
) throws -> UInt32 {
    var dataSize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
    guard status == noErr else {
        throw DeviceQueryError.propertyReadFailed(status)
    }
    return dataSize
}

public func readStringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else {
        throw DeviceQueryError.propertyReadFailed(status)
    }
    guard let value = unmanaged?.takeUnretainedValue() else {
        throw DeviceQueryError.stringReadFailed
    }
    return value as String
}

public func readStreamPresence(
    objectID: AudioObjectID,
    scope: AudioObjectPropertyScope
) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    guard let size = try? readPropertyDataSize(objectID: objectID, address: &address) else {
        return false
    }
    return size > 0
}

public func readUInt32Property(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == noErr else {
        return nil
    }
    return value
}

private func hasProperty(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress
) -> Bool {
    AudioObjectHasProperty(objectID, &address)
}

private func readFloat32Property(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress
) -> Float32? {
    guard hasProperty(objectID: objectID, address: &address) else {
        return nil
    }

    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == noErr else {
        return nil
    }
    return value
}

private func setFloat32Property(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    value: Float32
) -> Bool {
    guard hasProperty(objectID: objectID, address: &address) else {
        return false
    }

    var settableDarwin: DarwinBoolean = false
    let settableStatus = AudioObjectIsPropertySettable(objectID, &address, &settableDarwin)
    guard settableStatus == noErr, settableDarwin.boolValue else {
        return false
    }

    var mutableValue = value
    let size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectSetPropertyData(objectID, &address, 0, nil, size, &mutableValue)
    return status == noErr
}

private func volumeAddress(
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: scope,
        mElement: element
    )
}

public func readOutputVolumeScalar(deviceID: AudioDeviceID) -> Float? {
    let candidates: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain,
        1,
        2,
    ]

    for element in candidates {
        var address = volumeAddress(scope: kAudioDevicePropertyScopeOutput, element: element)
        if let value = readFloat32Property(objectID: deviceID, address: &address) {
            return Float(value)
        }
    }
    return nil
}

@discardableResult
public func setOutputVolumeScalar(deviceID: AudioDeviceID, value: Float) -> Bool {
    let clamped = max(0.0, min(1.0, value))
    let candidates: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain,
        1,
        2,
    ]

    var didSet = false
    for element in candidates {
        var address = volumeAddress(scope: kAudioDevicePropertyScopeOutput, element: element)
        if setFloat32Property(objectID: deviceID, address: &address, value: clamped) {
            didSet = true
        }
    }
    return didSet
}

public func listDevices() -> [AudioDevice] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    guard let size = try? readPropertyDataSize(
        objectID: AudioObjectID(kAudioObjectSystemObject),
        address: &address
    ) else {
        return []
    }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = Array(repeating: AudioDeviceID(), count: count)
    var mutableSize = size
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &mutableSize,
        &ids
    )
    guard status == noErr else {
        return []
    }

    return ids.compactMap { id in
        guard
            let uid = try? readStringProperty(objectID: id, selector: kAudioDevicePropertyDeviceUID),
            let name = try? readStringProperty(objectID: id, selector: kAudioObjectPropertyName)
        else {
            return nil
        }

        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            manufacturer: (try? readStringProperty(objectID: id, selector: kAudioObjectPropertyManufacturer)) ?? "",
            transportType: readUInt32Property(objectID: id, selector: kAudioDevicePropertyTransportType) ?? 0,
            hasInput: readStreamPresence(objectID: id, scope: kAudioObjectPropertyScopeInput),
            hasOutput: readStreamPresence(objectID: id, scope: kAudioObjectPropertyScopeOutput)
        )
    }
}

public func readDefaultOutputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID()
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &deviceID
    )
    guard status == noErr else {
        return nil
    }
    return deviceID
}
