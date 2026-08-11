import Foundation
import IOKit.pwr_mgt

actor PowerAssertionService {
    private var assertionID: IOPMAssertionID = 0

    func update(activeDownloads: Int, enabled: Bool) {
        if enabled, activeDownloads > 0, assertionID == 0 {
            let reason = "Super DD is downloading files" as CFString
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoIdleSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &assertionID
            )
        } else if (!enabled || activeDownloads == 0), assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    deinit {
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }
}
