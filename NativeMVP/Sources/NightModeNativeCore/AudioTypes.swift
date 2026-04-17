import AudioToolbox
import CoreAudio
import Foundation

public struct AudioDevice: CustomStringConvertible {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let transportType: UInt32
    public let hasInput: Bool
    public let hasOutput: Bool

    public var isVirtual: Bool {
        transportType == fourCharCode("virt")
    }

    public var isBuiltIn: Bool {
        transportType == fourCharCode("bltn")
    }

    public var isBluetooth: Bool {
        transportType == fourCharCode("blue") || name.contains("AirPods")
    }

    public var displayName: String {
        if !manufacturer.isEmpty && !name.contains(manufacturer) {
            return "\(name) (\(manufacturer))"
        }
        return name
    }

    public var description: String {
        "[\(id)] \(name) uid=\(uid) input=\(hasInput) output=\(hasOutput)"
    }
}

public enum DeviceQueryError: Error {
    case propertyReadFailed(OSStatus)
    case stringReadFailed
}

public enum PassThroughError: Error, CustomStringConvertible {
    case componentMissing
    case osStatus(OSStatus, String)
    case blackHoleMissing
    case outputMissing(String)

    public var description: String {
        switch self {
        case .componentMissing:
            return "HAL Output AudioComponent를 찾지 못했습니다."
        case let .osStatus(status, context):
            return "\(context) 실패: OSStatus \(status)"
        case .blackHoleMissing:
            return "BlackHole 입력 장치를 찾지 못했습니다."
        case let .outputMissing(uid):
            return "출력 장치 UID를 찾지 못했습니다: \(uid)"
        }
    }
}

public enum LatencyMode: String, CaseIterable {
    case stable
    case balanced
    case lowLatency

    public var title: String {
        switch self {
        case .stable:
            return "안정"
        case .balanced:
            return "표준"
        case .lowLatency:
            return "저지연"
        }
    }
}

public enum OutputMode: String, CaseIterable {
    case auto
    case manual

    public var title: String {
        switch self {
        case .auto:
            return "자동"
        case .manual:
            return "수동"
        }
    }
}

public func fourCharCode(_ code: String) -> UInt32 {
    code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}
