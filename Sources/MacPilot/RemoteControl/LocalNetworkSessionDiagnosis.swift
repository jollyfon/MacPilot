import Foundation
import SystemConfiguration

/// macOS applies the Local Network privacy decision to the console account,
/// not to the account that owns the running process. After a fast user switch
/// the two can differ, so a denial saved for the account in front of the screen
/// decides whether another account's app may register Bonjour services.
enum LocalNetworkSessionDiagnosis {
    static func consoleUserName() -> String? {
        guard let name = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String?,
              !name.isEmpty else { return nil }
        return name
    }

    static func processUserName() -> String {
        NSUserName()
    }

    static func otherConsoleUser(consoleUser: String?, processUser: String) -> String? {
        guard let consoleUser, !consoleUser.isEmpty, consoleUser != processUser else { return nil }
        return consoleUser
    }
}
