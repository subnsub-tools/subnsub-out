import Foundation

/// Strict hardware-UID binding policy for audio input devices.
///
/// Once a user selects a specific microphone (`!boundUID.isEmpty`), input permanently locks to that
/// exact hardware UID. Even if the device disconnects or powers off, input never silently falls
/// back to the system default or built-in microphone; it holds a no-input warning state until that
/// device returns or the user explicitly switches to another device.
public enum MicrophoneBinding {
    public struct DeviceInfo: Equatable, Sendable {
        public let uid: String
        public let name: String

        public init(uid: String, name: String) {
            self.uid = uid
            self.name = name
        }
    }

    public enum Resolution: Equatable, Sendable {
        /// Bound to a specific microphone that is currently connected and ready.
        case boundAvailable(DeviceInfo)
        /// Bound to a specific microphone that is currently disconnected; maintain no-input state.
        case boundMissing(uid: String, name: String)
        /// Unbound ("System default") and at least one input device is present.
        case systemDefault(DeviceInfo)
        /// Unbound, and the Mac currently has no audio input hardware at all.
        case noInputDevices

        public var canRecord: Bool {
            switch self {
            case .boundAvailable, .systemDefault:
                return true
            case .boundMissing, .noInputDevices:
                return false
            }
        }

        public var isBound: Bool {
            switch self {
            case .boundAvailable, .boundMissing:
                return true
            case .systemDefault, .noInputDevices:
                return false
            }
        }

        public var missingMessage: String? {
            switch self {
            case .boundAvailable, .systemDefault:
                return nil
            case .boundMissing(_, let name):
                return tr("The locked microphone “%@” is not connected, so there is no input. Reconnect it or switch to another microphone.", name)
            case .noInputDevices:
                return tr("No microphone is available. Connect an audio input device.")
            }
        }
    }

    public static func displayLabel(boundName: String, uid: String) -> String {
        let trimmed = boundName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let fallback = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? tr("Locked microphone") : fallback
    }

    public static func resolve(
        boundUID: String,
        boundName: String,
        available: [DeviceInfo],
        systemDefault: DeviceInfo?
    ) -> Resolution {
        if !boundUID.isEmpty {
            if let matched = available.first(where: { $0.uid == boundUID }) {
                return .boundAvailable(matched)
            }
            return .boundMissing(uid: boundUID, name: displayLabel(boundName: boundName, uid: boundUID))
        }
        if let current = systemDefault ?? available.first {
            return .systemDefault(current)
        }
        return .noInputDevices
    }
}
