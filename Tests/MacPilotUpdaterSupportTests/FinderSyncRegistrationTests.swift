import Foundation
import Testing
@testable import MacPilotUpdaterSupport

struct UpdaterLaunchPlanTests {
    @Test func relaunchPlanRunsTheReplacedBundleExecutable() {
        let application = URL(fileURLWithPath: "/Applications/MacPilot.app")

        #expect(
            UpdaterLaunchPlan.directExecutableURL(for: application).path
                == "/Applications/MacPilot.app/Contents/MacOS/MacPilot"
        )
        #expect(
            UpdaterLaunchPlan.directExecutableURL(
                for: URL(fileURLWithPath: "/Applications/OctoPilot.app"),
                executableName: "OctoPilot"
            ).path == "/Applications/OctoPilot.app/Contents/MacOS/OctoPilot"
        )
    }

    @Test func finderSyncRecoveryFailureDoesNotBlockRelaunchOfRestoredApplication() {
        #expect(
            UpdaterLaunchPlan.shouldRelaunchAfterFailedUpdate(
                destinationExists: true,
                applicationRollbackFailed: false
            )
        )
        #expect(
            !UpdaterLaunchPlan.shouldRelaunchAfterFailedUpdate(
                destinationExists: true,
                applicationRollbackFailed: true
            )
        )
        #expect(
            !UpdaterLaunchPlan.shouldRelaunchAfterFailedUpdate(
                destinationExists: false,
                applicationRollbackFailed: false
            )
        )
    }
}

struct FinderSyncRegistrationTests {
    @Test func recoveryContinuesAfterPlugInKitConfirmsFailedRemovalAlreadyRemovedTheExactTarget() throws {
        try withTemporaryJournal { journal in
            let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
            let targetPath = app.appendingPathComponent("Contents/PlugIns/FinderSync.appex").path
            let attempt = try attemptRemovalRecovery(
                journal: journal,
                applicationURL: app,
                removalError: NSError(
                    domain: "PlugInKit",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "remove: no plugin at \(targetPath)"]
                ),
                targetDisappearsAfterRemoval: true
            )

            if case .success(let recovered) = attempt.result {
                #expect(recovered)
            } else if case .failure(let error) = attempt.result {
                Issue.record("A vanished exact target should be re-added: \(error)")
            }
            #expect(attempt.commands == [
                FinderSyncRegistration.queryArguments(),
                FinderSyncRegistration.queryArguments(includeAllVersions: true),
                ["-e", "ignore", "-i", FinderSyncRegistration.extensionBundleIdentifier],
                ["-r", targetPath],
                FinderSyncRegistration.queryArguments(includeAllVersions: true),
                ["-a", targetPath],
                ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier],
                FinderSyncRegistration.queryArguments()
            ])
            #expect(!attempt.journalHasIntent)
        }
    }

    @Test func missingPluginRemovalErrorIsNotIgnoredWhileTheExactTargetRemainsRegistered() throws {
        try assertRemovalRecoveryFailure(
            removalMessage: "remove: no plugin at /Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex",
            removalDomain: "PlugInKit",
            targetDisappearsAfterRemoval: false
        )
    }

    @Test func permissionRemovalErrorIsNotIgnoredEvenWhenTheTargetDisappears() throws {
        try assertRemovalRecoveryFailure(
            removalMessage: "not authorized to remove extension",
            removalDomain: "PlugInKit",
            targetDisappearsAfterRemoval: true
        )
    }

    @Test func missingPluginErrorForAnotherPathIsNotIgnored() throws {
        try assertRemovalRecoveryFailure(
            removalMessage: "remove: no plugin at /Users/other/MacPilot.app/Contents/PlugIns/FinderSync.appex",
            removalDomain: "PlugInKit",
            targetDisappearsAfterRemoval: true
        )
    }

    @Test func matchingMissingPluginMessageFromAnotherDomainIsNotIgnored() throws {
        try assertRemovalRecoveryFailure(
            removalMessage: "remove: no plugin at /Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex",
            removalDomain: "UnrelatedCommandRunner",
            targetDisappearsAfterRemoval: true
        )
    }

    @Test func addFailureAfterConfirmedRemovalRetainsRecoveryIntent() throws {
        try withTemporaryJournal { journal in
            let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
            let attempt = try attemptRemovalRecovery(
                journal: journal,
                applicationURL: app,
                removalError: missingPluginError(at: app),
                targetDisappearsAfterRemoval: true,
                addError: NSError(domain: "PlugInKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "add failed"])
            )

            expectFailure(attempt.result, domain: "PlugInKit", message: "add failed")
            #expect(attempt.journalHasIntent)
        }
    }

    @Test func electionFailureAfterConfirmedRemovalRetainsRecoveryIntent() throws {
        try withTemporaryJournal { journal in
            let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
            let attempt = try attemptRemovalRecovery(
                journal: journal,
                applicationURL: app,
                removalError: missingPluginError(at: app),
                targetDisappearsAfterRemoval: true,
                useError: NSError(domain: "PlugInKit", code: 3, userInfo: [NSLocalizedDescriptionKey: "use election failed"])
            )

            expectFailure(attempt.result, domain: "PlugInKit", message: "use election failed")
            #expect(attempt.journalHasIntent)
        }
    }

    @Test func enabledExtensionIsPausedBeforeReplacementAndResumedAfterRegistration() throws {
        try withTemporaryJournal { journal in
            var elected = true
            var events: [String] = []
            try FinderSyncRegistration.withSuspendedElection(
                applicationURL: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                journal: journal,
                execute: { arguments in
                    events.append(arguments.joined(separator: " "))
                    if arguments.contains("ignore") { elected = false }
                    if arguments.contains("use") { elected = true }
                },
                query: { _ in finderSyncOutput(enabled: elected, at: URL(fileURLWithPath: "/Applications/MacPilot.app")) },
                operation: {
                    events.append("replace bundle")
                    events.append("refresh registration")
                }
            )
            #expect(events == [
                "-e ignore -i com.misswell.macpilot.finder-sync",
                "replace bundle",
                "refresh registration",
                "-e use -i com.misswell.macpilot.finder-sync"
            ])
        }
    }

    @Test func failedReplacementRestoresElectionAndPreservesTheOriginalError() {
        enum Failure: Error { case replacement }
        do {
            try withTemporaryJournal { journal in
                var elected = true
                var events: [String] = []
                do {
                    try FinderSyncRegistration.withSuspendedElection(
                        applicationURL: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                        journal: journal,
                        execute: { arguments in
                            events.append(arguments.joined(separator: " "))
                            if arguments.contains("ignore") { elected = false }
                            if arguments.contains("use") { elected = true }
                        },
                        query: { _ in finderSyncOutput(enabled: elected, at: URL(fileURLWithPath: "/Applications/MacPilot.app")) },
                        operation: { throw Failure.replacement }
                    )
                    Issue.record("Replacement failure must propagate")
                } catch {
                    #expect(error is Failure)
                }
                #expect(events == [
                    "-e ignore -i com.misswell.macpilot.finder-sync",
                    "-e use -i com.misswell.macpilot.finder-sync"
                ])
            }
        } catch {
            Issue.record("Temporary journal setup failed: \(error)")
        }
    }

    @Test func disabledElectionIsLeftDisabledThroughoutReplacement() throws {
        try withTemporaryJournal { journal in
            var replaced = false
            try FinderSyncRegistration.withSuspendedElection(
                applicationURL: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                journal: journal,
                execute: { _ in Issue.record("A disabled extension must not be elected") },
                query: { _ in finderSyncOutput(enabled: false, at: URL(fileURLWithPath: "/Applications/MacPilot.app")) },
                operation: { replaced = true }
            )
            #expect(replaced)
        }
    }

    @Test func failedSuspensionPreventsBundleReplacement() {
        enum Failure: Error { case suspension }
        do {
            try withTemporaryJournal { journal in
                var elected = true
                var replaced = false
                #expect(throws: Failure.self) {
                    try FinderSyncRegistration.withSuspendedElection(
                        applicationURL: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                        journal: journal,
                        execute: { arguments in
                            if arguments.contains("ignore") {
                                elected = false
                                throw Failure.suspension
                            }
                            if arguments.contains("use") { elected = true }
                        },
                        query: { _ in finderSyncOutput(enabled: elected, at: URL(fileURLWithPath: "/Applications/MacPilot.app")) },
                        operation: { replaced = true }
                    )
                }
                #expect(!replaced)
            }
        } catch {
            Issue.record("Temporary journal setup failed: \(error)")
        }
    }

    @Test func restorationFailureIsReportedWithoutMaskingReplacementFailure() {
        enum Failure: Error, Equatable { case replacement, restoration }
        do {
            try withTemporaryJournal { journal in
                var elected = true
                var reported: Failure?
                do {
                    try FinderSyncRegistration.withSuspendedElection(
                        applicationURL: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                        journal: journal,
                        execute: { arguments in
                            if arguments.contains("ignore") { elected = false }
                            if arguments.contains("use") { throw Failure.restoration }
                        },
                        query: { _ in finderSyncOutput(enabled: elected, at: URL(fileURLWithPath: "/Applications/MacPilot.app")) },
                        restorationFailed: { reported = $0 as? Failure },
                        operation: { throw Failure.replacement }
                    )
                    Issue.record("Replacement failure must propagate")
                } catch {
                    #expect((error as? Failure) == .replacement)
                }
                #expect(reported == .restoration)
            }
        } catch {
            Issue.record("Temporary journal setup failed: \(error)")
        }
    }

    @Test func startupRecoveryDoesNotOverrideADisabledSystemExtension() throws {
        try withTemporaryJournal { journal in
            var commands: [[String]] = []
            let recovered = try FinderSyncRegistration.recoverIfEnabled(
                at: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                journal: journal,
                execute: {
                    commands.append($0)
                    return "-    com.misswell.macpilot.finder-sync(1.1.501)"
                }
            )
            #expect(!recovered)
            #expect(commands == [FinderSyncRegistration.queryArguments()])
        }
    }

    @Test func startupRecoveryRemovesStaleVersionsWhileLaunchesAreSuspended() throws {
        let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
        let current = "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"
        let stale = "/Users/developer/Code/MacPilot.app/Contents/PlugIns/FinderSync.appex"
        try withTemporaryJournal { journal in
            var commands: [[String]] = []
            var elected = true
            let recovered = try FinderSyncRegistration.recoverIfEnabled(at: app, journal: journal, execute: {
                commands.append($0)
                if $0 == FinderSyncRegistration.queryArguments() {
                    return finderSyncOutput(enabled: elected, at: app)
                }
                if $0 == FinderSyncRegistration.queryArguments(includeAllVersions: true) {
                    return """
                    + com.misswell.macpilot.finder-sync(1.1.469)\tOLD\t\(stale)
                    + com.misswell.macpilot.finder-sync(1.1.501)\tNEW\t\(current)
                    """
                }
                if $0.contains("ignore") { elected = false }
                if $0.contains("use") { elected = true }
                return ""
            })
            #expect(recovered)
            #expect(commands == [
                FinderSyncRegistration.queryArguments(),
                FinderSyncRegistration.queryArguments(includeAllVersions: true),
                ["-e", "ignore", "-i", FinderSyncRegistration.extensionBundleIdentifier],
                ["-r", stale], ["-r", current], ["-a", current],
                ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier],
                FinderSyncRegistration.queryArguments()
            ])
        }
    }

    @Test func refreshRemovesTheExistingExtensionBeforeAddingTheReplacement() {
        let appURL = URL(fileURLWithPath: "/Applications/MacPilot.app")
        let extensionPath = "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"

        #expect(
            FinderSyncRegistration.registrationArguments(
                for: appURL,
                registeredExtensionPaths: [extensionPath],
                restoreEnabledElection: true
            ) == [
                ["-r", extensionPath],
                ["-a", extensionPath],
                ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier]
            ]
        )
    }

    @Test func enabledExtensionRestoresUseElectionAfterReplacement() {
        let appURL = URL(fileURLWithPath: "/Applications/MacPilot.app")
        let extensionPath = "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"

        #expect(
            FinderSyncRegistration.registrationArguments(
                for: appURL,
                registeredExtensionPaths: [extensionPath],
                restoreEnabledElection: true
            ) == [
                ["-r", extensionPath],
                ["-a", extensionPath],
                ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier]
            ]
        )
    }

    @Test func disabledExtensionIsNotSilentlyReenabled() {
        let appURL = URL(fileURLWithPath: "/Applications/MacPilot.app")
        let extensionPath = "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"

        #expect(
            FinderSyncRegistration.registrationArguments(
                for: appURL,
                restoreEnabledElection: false
            ) == [
                ["-a", extensionPath]
            ]
        )
    }

    @Test func unregisteredExtensionIsAddedWithoutTryingToRemoveIt() {
        let appURL = URL(fileURLWithPath: "/Applications/MacPilot.app")
        let extensionPath = "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"

        #expect(
            FinderSyncRegistration.registrationArguments(
                for: appURL,
                registeredExtensionPaths: [],
                restoreEnabledElection: false
            ) == [["-a", extensionPath]]
        )
    }

    @Test func onlyEnabledMatchingExtensionIsRestored() {
        #expect(
            FinderSyncRegistration.isElectedForUse(
                in: "     com.apple.FinderSync(1.0)\n+    com.misswell.macpilot.finder-sync(1.1.263)"
            )
        )
        #expect(
            !FinderSyncRegistration.isElectedForUse(
                in: "     com.misswell.macpilot.finder-sync(1.1.263)"
            )
        )
    }

    @Test func registeredPathsExtractAllDuplicateExtensionRecords() {
        let output = """
        +    com.misswell.macpilot.finder-sync(1.1.278)\tOLD-UUID\t/Applications/OctoPilot.app/Contents/PlugIns/FinderSync.appex
             com.misswell.macpilot.finder-sync(1.1.279)\tNEW-UUID\t/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex
        """

        #expect(
            FinderSyncRegistration.registeredExtensionPaths(in: output) == [
                "/Applications/OctoPilot.app/Contents/PlugIns/FinderSync.appex",
                "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"
            ]
        )
    }

    @Test func explicitEnableRegistersTheCurrentBundleAndConfirmsItsElection() throws {
        try withTemporaryJournal { journal in
            let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
            let stale = URL(fileURLWithPath: "/tmp/old/MacPilot.app")
            var elected = false
            var registered = stale
            var commands: [[String]] = []
            let result = try FinderSyncRegistration.setEnabledByUser(true, at: app, journal: journal) { arguments in
                commands.append(arguments)
                if arguments.first == "-a" { registered = app }
                if arguments.contains("use") { elected = true }
                return finderSyncOutput(enabled: elected, at: registered)
            }
            #expect(result)
            #expect(commands.contains(["-a", app.appendingPathComponent("Contents/PlugIns/FinderSync.appex").path]))
            #expect(commands.contains(["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier]))
            let pendingIntent = try journal.withExclusiveLock { try $0.readIntent() }
            #expect(pendingIntent == nil)
        }
    }

    @Test func explicitEnableRefusesToReportSuccessForAnEnabledStaleCopy() throws {
        try withTemporaryJournal { journal in
            let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
            let stale = URL(fileURLWithPath: "/tmp/old/MacPilot.app")
            #expect(throws: FinderSyncRegistrationError.restorationNotConfirmed) {
                try FinderSyncRegistration.setEnabledByUser(true, at: app, journal: journal) { _ in
                    finderSyncOutput(enabled: true, at: stale)
                }
            }
            let pendingIntent = try journal.withExclusiveLock { try $0.readIntent() }
            #expect(pendingIntent != nil)
        }
    }

    @Test func explicitDisableCancelsMatchingPendingRecoveryAfterConfirmation() throws {
        try withTemporaryJournal { journal in
            let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
            try journal.withExclusiveLock { try $0.writeIntent(for: app) }
            var elected = true
            let result = try FinderSyncRegistration.setEnabledByUser(false, at: app, journal: journal) { arguments in
                if arguments.contains("ignore") { elected = false }
                return finderSyncOutput(enabled: elected, at: app)
            }
            #expect(!result)
            let pendingIntent = try journal.withExclusiveLock { try $0.readIntent() }
            #expect(pendingIntent == nil)
        }
    }

    @Test func explicitDisableRequiresAFreshDisabledQuery() throws {
        try withTemporaryJournal { journal in
            let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
            try journal.withExclusiveLock { try $0.writeIntent(for: app) }
            #expect(throws: FinderSyncRegistrationError.disableNotConfirmed) {
                try FinderSyncRegistration.setEnabledByUser(false, at: app, journal: journal) { _ in
                    finderSyncOutput(enabled: true, at: app)
                }
            }
            let pendingIntent = try journal.withExclusiveLock { try $0.readIntent() }
            #expect(pendingIntent != nil)
        }
    }

    @Test func explicitChangeRefusesAnotherApplicationsPendingRecovery() throws {
        try withTemporaryJournal { journal in
            let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
            try journal.withExclusiveLock { try $0.writeIntent(for:
                URL(fileURLWithPath: "/tmp/other/MacPilot.app")) }
            #expect(throws: FinderSyncRegistrationError.journalTargetMismatch) {
                try FinderSyncRegistration.setEnabledByUser(true, at: app, journal: journal) { _ in
                    Issue.record("A conflicting recovery must not mutate registration")
                    return ""
                }
            }
        }
    }

    @Test func explicitEnableResumesAMatchingPendingIntentWithoutOverwritingIt() throws {
        try withTemporaryJournal { journal in
            let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
            try journal.withExclusiveLock { try $0.writeIntent(for: app) }
            var elected = false
            let enabled = try FinderSyncRegistration.setEnabledByUser(true, at: app, journal: journal) { arguments in
                if arguments.contains("use") { elected = true }
                return finderSyncOutput(enabled: elected, at: app)
            }
            #expect(enabled)
            let pending = try journal.withExclusiveLock { try $0.readIntent() }
            #expect(pending == nil)
        }
    }

    private func withTemporaryJournal<T>(_ body: (FinderSyncRecoveryJournal) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderSyncRegistrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(FinderSyncRecoveryJournal(fileURL: directory.appendingPathComponent("journal.json")))
    }
}

private func finderSyncOutput(enabled: Bool, at applicationURL: URL) -> String {
    let status = enabled ? "+" : "-"
    let extensionPath = applicationURL
        .appendingPathComponent("Contents/PlugIns/FinderSync.appex")
        .path
    return "\(status)\tcom.misswell.macpilot.finder-sync(1.1.501)\tTEST-UUID\t\(extensionPath)"
}

private struct RemovalRecoveryAttempt {
    let result: Result<Bool, any Error>
    let commands: [[String]]
    let journalHasIntent: Bool
}

private func attemptRemovalRecovery(
    journal: FinderSyncRecoveryJournal,
    applicationURL: URL,
    removalError: Error,
    targetDisappearsAfterRemoval: Bool,
    addError: Error? = nil,
    useError: Error? = nil
) throws -> RemovalRecoveryAttempt {
    var commands: [[String]] = []
    var targetRegistered = true
    var elected = true

    let result: Result<Bool, any Error>
    do {
        result = .success(try FinderSyncRegistration.recoverIfEnabled(at: applicationURL, journal: journal) { arguments in
            commands.append(arguments)
            if arguments == FinderSyncRegistration.queryArguments() {
                return targetRegistered ? finderSyncOutput(enabled: elected, at: applicationURL) : ""
            }
            if arguments == FinderSyncRegistration.queryArguments(includeAllVersions: true) {
                return targetRegistered ? finderSyncOutput(enabled: elected, at: applicationURL) : ""
            }
            if arguments == ["-e", "ignore", "-i", FinderSyncRegistration.extensionBundleIdentifier] {
                elected = false
                return ""
            }
            if arguments.first == "-r" {
                targetRegistered = !targetDisappearsAfterRemoval
                throw removalError
            }
            if arguments.first == "-a" {
                if let addError { throw addError }
                targetRegistered = true
                return ""
            }
            if arguments == ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier] {
                if let useError { throw useError }
                elected = true
                return ""
            }
            return ""
        })
    } catch {
        result = .failure(error)
    }

    let journalHasIntent = try journal.withExclusiveLock { try $0.readIntent() != nil }
    return RemovalRecoveryAttempt(result: result, commands: commands, journalHasIntent: journalHasIntent)
}

private func missingPluginError(at applicationURL: URL) -> NSError {
    let path = applicationURL.appendingPathComponent("Contents/PlugIns/FinderSync.appex").path
    return NSError(
        domain: "PlugInKit",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "remove: no plugin at \(path)"]
    )
}

private func assertRemovalRecoveryFailure(
    removalMessage: String,
    removalDomain: String,
    targetDisappearsAfterRemoval: Bool
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FinderSyncRemovalRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = FinderSyncRecoveryJournal(fileURL: directory.appendingPathComponent("journal.json"))
    let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
    let attempt = try attemptRemovalRecovery(
        journal: journal,
        applicationURL: app,
        removalError: NSError(
            domain: removalDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: removalMessage]
        ),
        targetDisappearsAfterRemoval: targetDisappearsAfterRemoval
    )

    expectFailure(attempt.result, domain: removalDomain, message: removalMessage)
    #expect(attempt.journalHasIntent == targetDisappearsAfterRemoval)
}

private func expectFailure(
    _ result: Result<Bool, any Error>,
    domain: String,
    message: String
) {
    guard case .failure(let error) = result else {
        Issue.record("Expected registration failure: \(message)")
        return
    }
    let cocoaError = error as NSError
    #expect(cocoaError.domain == domain)
    #expect(cocoaError.localizedDescription == message)
}
