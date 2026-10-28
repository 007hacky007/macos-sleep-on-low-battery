import Foundation
import IOKit.pwr_mgt

enum KeepAwakeError: LocalizedError {
    case assertionFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .assertionFailed(let code):
            return "macOS refused the keep awake request (IOReturn \(code))."
        }
    }
}

/// Holds a power assertion that prevents idle sleep, like Amphetamine or `caffeinate -i`.
///
/// Only idle sleep assertions are used. They do not block an explicit `pmset sleepnow`,
/// Apple menu sleep, or closing the lid, so the battery threshold can always win.
@MainActor
final class KeepAwakeService {
    private static let assertionName = "Battery Sleep Guard keep awake" as CFString

    private var assertionID = IOPMAssertionID(0)
    private(set) var heldDisplayAwake: Bool?

    var isHolding: Bool { heldDisplayAwake != nil }

    /// `keepDisplayAwake` also stops the display from dimming and sleeping, which implies
    /// keeping the system awake.
    func hold(keepDisplayAwake: Bool) throws {
        if heldDisplayAwake == keepDisplayAwake { return }
        release()

        let type = (keepDisplayAwake ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep") as CFString
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.assertionName, &newID)
        guard result == kIOReturnSuccess else { throw KeepAwakeError.assertionFailed(result) }
        assertionID = newID
        heldDisplayAwake = keepDisplayAwake
    }

    func release() {
        guard isHolding else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        heldDisplayAwake = nil
    }
}
