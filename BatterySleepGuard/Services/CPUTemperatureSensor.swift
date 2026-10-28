import Foundation
import IOKit

/// Average CPU core temperature from the System Management Controller.
///
/// The SMC keys differ per chip generation; the per-core keys below are the ones the Stats
/// app uses. The connection and the key list are resolved once, after which a read is one
/// IOKit call per core, about 0.15 ms each, so roughly 1.5 ms for a whole reading.
@MainActor
final class CPUTemperatureSensor {
    private static let plausibleTemperature = 10.0...120.0

    private var connection: io_connect_t = 0
    private var keys: [SMCKey]?

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func read() -> Double? {
        guard let keys = resolvedKeys(), !keys.isEmpty else { return nil }
        let values = keys.compactMap { value(of: $0) }.filter { Self.plausibleTemperature.contains($0) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Opens the SMC and keeps the candidate keys this Mac answers for. A Mac without any
    /// of them gets an empty list, so later reads return nil without touching the SMC.
    private func resolvedKeys() -> [SMCKey]? {
        if let keys { return keys }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { keys = []; return keys }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            connection = 0
            keys = []
            return keys
        }
        let found = Self.candidateKeys(chip: Self.chipName()).compactMap(keyInfo)
        keys = found
        if found.isEmpty {
            IOServiceClose(connection)
            connection = 0
        }
        return found
    }

    nonisolated static func chipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// Per-core keys for the chip generation named in `machdep.cpu.brand_string`, such as
    /// "Apple M1 Pro". Intel Macs report a single CPU die or proximity sensor instead.
    nonisolated static func candidateKeys(chip: String) -> [String] {
        if chip.contains("Intel") { return ["TC0D", "TC0E", "TC0F", "TC0P"] }
        let generation = chip.split(separator: " ").first { $0.hasPrefix("M") && $0.count >= 2 }
        switch generation {
        case "M1":
            return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        case "M2":
            return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        case "M3":
            return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                    "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        case "M4":
            return ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        case "M5":
            return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X",
                    "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        case "M6":
            return ["Tp0j", "Tp0g", "Tp09", "Tp07", "Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G",
                    "Tp0b", "Tp05", "Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"]
        default:
            return []
        }
    }

    // MARK: - SMC protocol

    private struct SMCKey {
        let code: UInt32
        let info: SMCKeyInfo
    }

    private static let typeFloat = fourCharCode("flt ")
    private static let typeSP78 = fourCharCode("sp78")

    private func keyInfo(_ name: String) -> SMCKey? {
        var input = SMCParam()
        input.key = Self.fourCharCode(name)
        input.command = SMCParam.readKeyInfo
        guard let output = call(&input) else { return nil }
        let type = output.keyInfo.dataType
        guard type == Self.typeFloat || type == Self.typeSP78 else { return nil }
        return SMCKey(code: input.key, info: output.keyInfo)
    }

    private func value(of key: SMCKey) -> Double? {
        var input = SMCParam()
        input.key = key.code
        input.keyInfo = key.info
        input.command = SMCParam.readBytes
        guard var output = call(&input) else { return nil }
        return withUnsafeBytes(of: &output.bytes) { bytes in
            if key.info.dataType == Self.typeFloat {
                return Double(bytes.load(as: Float.self))
            }
            // Signed fixed point, 7 integer and 8 fraction bits, big endian.
            return Double(Int16(bigEndian: bytes.load(as: Int16.self))) / 256
        }
    }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.stride
        let result = IOConnectCallStructMethod(
            connection, SMCParam.kernelIndex, &input, MemoryLayout<SMCParam>.stride, &output, &outputSize
        )
        return result == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private nonisolated static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Mirrors the 12 byte `SMCKeyData_keyInfo_t` of the AppleSMC user client. The explicit
/// padding matters: Swift would otherwise place the next field of `SMCParam` in the tail.
private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

/// Mirrors the 80 byte `SMCKeyData_t` passed to selector 2 of the AppleSMC user client.
private struct SMCParam {
    static let kernelIndex: UInt32 = 2
    static let readBytes: UInt8 = 5
    static let readKeyInfo: UInt8 = 9

    var key: UInt32 = 0
    var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var powerLimits: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}
