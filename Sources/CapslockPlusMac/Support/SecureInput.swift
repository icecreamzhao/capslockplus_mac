import Foundation
import AppKit
import Carbon
import CoreGraphics

enum SecureInput {
    static func isEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    static func ownerPID() -> pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() else { return nil }
        let dict = session as NSDictionary
        guard let value = dict["kCGSSessionSecureInputPID"] else { return nil }
        if let number = value as? NSNumber {
            return pid_t(number.int32Value)
        }
        if let int = value as? Int {
            return pid_t(int)
        }
        return nil
    }

    static func ownerName() -> String? {
        guard let pid = ownerPID() else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
