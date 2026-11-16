import Foundation
import IOKit.pwr_mgt
import TabCore

/// Keeps the Mac from idle-sleeping while held. The display may still sleep,
/// and closing a laptop's lid still sleeps it.
protocol IdleSleepPreventing: AnyObject, Sendable {
    func hold(_ held: Bool)
}

/// An IOKit power assertion, created on the first hold and released on the last.
final class IdleSleepAssertion: IdleSleepPreventing, @unchecked Sendable {
    private let reason: String
    private let lock = NSLock()
    private var assertion: IOPMAssertionID?

    init(reason: String) {
        self.reason = reason
    }

    deinit {
        if let assertion { IOPMAssertionRelease(assertion) }
    }

    func hold(_ held: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if held, assertion == nil {
            var created = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     reason as CFString, &created)
            guard result == kIOReturnSuccess else {
                Log.mobile.error("couldn't keep the Mac awake for phones: \(result)")
                return
            }
            assertion = created
            Log.mobile.info("keeping the Mac awake for paired phones")
        } else if !held, let current = assertion {
            IOPMAssertionRelease(current)
            assertion = nil
            Log.mobile.info("letting the Mac sleep")
        }
    }
}
