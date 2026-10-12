import Foundation
import Testing
@testable import MacPilotUpdaterSupport

struct FinderSyncRecoveryJournalTests {
    @Test func anotherInstallationPendingRecoveryDoesNotBlockTheCurrentUpdate() throws {
        try withTemporaryJournal { legacy, markerURL in
            let current = URL(fileURLWithPath: "/Users/developer/Code/MacPilot.app")
            let other = URL(fileURLWithPath: "/Applications/MacPilot.app")
            try legacy.withExclusiveLock { try $0.writeIntent(for: other) }
            let originalMarker = try Data(contentsOf: markerURL)
            let currentJournal = try legacy.scoped(to: current)
            var replaced = false

            try FinderSyncRegistration.withSuspendedElection(
                applicationURL: current,
                journal: currentJournal,
                execute: { _ in Issue.record("An unmarked disabled extension must not be enabled") },
                query: { _ in plugInOutput(enabled: false, at: current) },
                operation: { replaced = true }
            )

            #expect(replaced, "A valid recovery for another installed copy must not abort bundle replacement")
            let ownerJournal = try legacy.scoped(to: other)
            let pending = try ownerJournal.withExclusiveLock { try $0.readIntent() }
            #expect(pending?.matches(applicationURL: other) == true)
            let migratedMarker = try Data(contentsOf: ownerJournal.fileURL)
            #expect(migratedMarker == originalMarker)
            #expect(!FileManager.default.fileExists(atPath: markerURL.path), "Older helpers must no longer see another installation's marker")
        }
    }

    @Test func scopedJournalsArePathBoundAndKeepTheLegacyCrossProcessLock() throws {
        try withTemporaryJournal { legacy, _ in
            let installed = try legacy.scoped(to: applicationURL)
            let normalized = try legacy.scoped(to: URL(fileURLWithPath: "/Applications/../Applications/MacPilot.app"))
            let workingCopy = try legacy.scoped(to: URL(fileURLWithPath: "/tmp/WorkingCopy/MacPilot.app"))
            #expect(installed.fileURL == normalized.fileURL)
            #expect(installed.fileURL != workingCopy.fileURL)
            try legacy.withExclusiveLock { _ in
                #expect(throws: FinderSyncRecoveryJournalError.lockBusy) {
                    try workingCopy.withExclusiveLock { _ in }
                }
            }
            try installed.withExclusiveLock { _ in
                #expect(throws: FinderSyncRecoveryJournalError.lockBusy) {
                    try workingCopy.withExclusiveLock { _ in }
                }
            }
        }
    }

    @Test func matchingLegacyIntentRemainsRecoverableAfterMigration() throws {
        try withTemporaryJournal { legacy, markerURL in
            try legacy.withExclusiveLock { try $0.writeIntent(for: applicationURL) }
            let scoped = try legacy.scoped(to: applicationURL)
            var elected = false
            let recovered = try FinderSyncRegistration.recoverIfEnabled(
                at: applicationURL, journal: scoped,
                execute: { arguments in
                    if arguments.contains("use") { elected = true }
                    return plugInOutput(enabled: elected, at: applicationURL)
                }
            )
            #expect(recovered)
            #expect(elected)
            let pending = try scoped.withExclusiveLock { try $0.readIntent() }
            #expect(pending == nil)
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func invalidLegacyMarkerIsNeverMovedOrUsedToAuthorizeRecovery() throws {
        try withTemporaryJournal { legacy, markerURL in
            let invalid = Data("{\"schemaVersion\":999}".utf8)
            try invalid.write(to: markerURL)
            let scoped = try legacy.scoped(to: applicationURL)
            #expect(throws: FinderSyncRecoveryJournalError.invalidMarker) {
                try scoped.withExclusiveLock { _ in }
            }
            let preserved = try Data(contentsOf: markerURL)
            #expect(preserved == invalid)
            #expect(!FileManager.default.fileExists(atPath: scoped.fileURL.path))
        }
    }

    @Test func migrationNeverOverwritesAnExistingPendingIntent() throws {
        try withTemporaryJournal { legacy, markerURL in
            let scoped = try legacy.scoped(to: applicationURL)
            try scoped.withExclusiveLock { try $0.writeIntent(for: applicationURL) }
            try legacy.withExclusiveLock { try $0.writeIntent(for: applicationURL) }
            let legacyBytes = try Data(contentsOf: markerURL)
            let scopedBytes = try Data(contentsOf: scoped.fileURL)
            #expect(throws: FinderSyncRecoveryJournalError.invalidMarker) {
                try scoped.withExclusiveLock { _ in }
            }
            let retainedLegacy = try Data(contentsOf: markerURL)
            let retainedScoped = try Data(contentsOf: scoped.fileURL)
            #expect(retainedLegacy == legacyBytes)
            #expect(retainedScoped == scopedBytes)
        }
    }

    private let applicationURL = URL(fileURLWithPath: "/Applications/MacPilot.app")
    private let extensionIdentifier = "com.misswell.macpilot.finder-sync"

    @Test func disabledWithoutJournalDoesNotRegisterOrEnable() throws {
        try withTemporaryJournal { journal, _ in
            var commands: [[String]] = []
            let recovered = try FinderSyncRegistration.recoverIfEnabled(
                at: applicationURL,
                journal: journal,
                execute: { arguments in
                    commands.append(arguments)
                    return "-    \(extensionIdentifier)(1.1.501)"
                }
            )

            #expect(!recovered)
            #expect(commands == [FinderSyncRegistration.queryArguments()])
        }
    }

    @Test func emptyPlugInKitQueryDoesNotCauseUnconditionalRegistration() throws {
        try withTemporaryJournal { journal, _ in
            var commands: [[String]] = []
            let recovered = try FinderSyncRegistration.recoverIfEnabled(
                at: applicationURL,
                journal: journal,
                execute: { arguments in
                    commands.append(arguments)
                    return ""
                }
            )

            #expect(!recovered)
            #expect(commands == [FinderSyncRegistration.queryArguments()])
        }
    }

    @Test func queryFailureDoesNotWriteJournalOrRunRegistrationCommands() throws {
        enum Failure: Error { case query }

        try withTemporaryJournal { journal, markerURL in
            var executionCount = 0
            #expect(throws: Failure.self) {
                try FinderSyncRegistration.withSuspendedElection(
                    applicationURL: applicationURL,
                    journal: journal,
                    execute: { _ in executionCount += 1 },
                    query: { _ in throw Failure.query },
                    operation: {}
                )
            }

            #expect(executionCount == 0)
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func markerIsWrittenBeforeIgnoreAndClearedOnlyAfterEnabledQuery() throws {
        try withTemporaryJournal { journal, markerURL in
            var elected = true
            var events: [String] = []
            try FinderSyncRegistration.withSuspendedElection(
                applicationURL: applicationURL,
                journal: journal,
                execute: { arguments in
                    events.append(arguments.joined(separator: " "))
                    if arguments.contains("ignore") {
                        #expect(FileManager.default.fileExists(atPath: markerURL.path))
                        elected = false
                    }
                    if arguments.contains("use") { elected = true }
                },
                query: { _ in
                    if events.contains("-e use -i \(extensionIdentifier)") {
                        #expect(FileManager.default.fileExists(atPath: markerURL.path))
                    }
                    events.append("query \(elected ? "+" : "-")")
                    return plugInOutput(enabled: elected, at: applicationURL)
                },
                operation: {
                    #expect(FileManager.default.fileExists(atPath: markerURL.path))
                    events.append("replace bundle")
                }
            )

            #expect(events == [
                "query +",
                "-e ignore -i \(extensionIdentifier)",
                "replace bundle",
                "-e use -i \(extensionIdentifier)",
                "query +"
            ])
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func cancelledOperationStillRunsUncancelledRestoration() throws {
        try withTemporaryJournal { journal, markerURL in
            var elected = true
            var commands: [[String]] = []

            #expect(throws: CancellationError.self) {
                try FinderSyncRegistration.withSuspendedElection(
                    applicationURL: applicationURL,
                    journal: journal,
                    execute: { arguments in
                        commands.append(arguments)
                        if arguments.contains("ignore") { elected = false }
                        if arguments.contains("use") { elected = true }
                    },
                    query: { _ in plugInOutput(enabled: elected, at: applicationURL) },
                    operation: { throw CancellationError() }
                )
            }

            #expect(commands.last == ["-e", "use", "-i", extensionIdentifier])
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func successfulUseCommandWithoutEnabledReadbackRetainsMarker() throws {
        try withTemporaryJournal { journal, markerURL in
            var events: [String] = []
            var queryCount = 0
            #expect(throws: FinderSyncRegistrationError.restorationNotConfirmed) {
                try FinderSyncRegistration.withSuspendedElection(
                    applicationURL: applicationURL,
                    journal: journal,
                    execute: { events.append($0.joined(separator: " ")) },
                    query: { _ in
                        queryCount += 1
                        let election = queryCount == 1 ? "+" : "-"
                        events.append("query \(election)")
                        return plugInOutput(enabled: election == "+", at: applicationURL)
                    },
                    operation: {}
                )
            }

            #expect(events == [
                "query +",
                "-e ignore -i \(extensionIdentifier)",
                "-e use -i \(extensionIdentifier)",
                "query -"
            ])
            #expect(FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func crashedSuspensionCanBeRecoveredByAnotherJournalInstance() throws {
        enum Failure: Error { case simulatedCrash }

        try withTemporaryJournal { journal, markerURL in
            var elected = true
            #expect(throws: Failure.self) {
                try FinderSyncRegistration.withSuspendedElection(
                    applicationURL: applicationURL,
                    journal: journal,
                    execute: { arguments in
                        if arguments.contains("ignore") { elected = false }
                        if arguments.contains("use") { throw FinderSyncRegistrationError.restorationNotConfirmed }
                    },
                    query: { _ in plugInOutput(enabled: elected, at: applicationURL) },
                    operation: { throw Failure.simulatedCrash }
                )
            }
            #expect(FileManager.default.fileExists(atPath: markerURL.path))

            let restartedJournal = FinderSyncRecoveryJournal(fileURL: markerURL)
            var commands: [[String]] = []
            let recovered = try FinderSyncRegistration.recoverIfEnabled(
                at: applicationURL,
                journal: restartedJournal,
                execute: { arguments in
                    commands.append(arguments)
                    if arguments.contains("use") { elected = true }
                    if arguments == FinderSyncRegistration.queryArguments() {
                        return plugInOutput(enabled: elected, at: applicationURL)
                    }
                    if arguments == FinderSyncRegistration.queryArguments(includeAllVersions: true) {
                        return "+    \(extensionIdentifier)(1.1.501)\tAPP\t/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"
                    }
                    return ""
                }
            )

            #expect(recovered)
            #expect(commands.contains(["-e", "use", "-i", extensionIdentifier]))
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func enabledStalePathDoesNotClearMarkerWhenUseReadbackStillNamesOldBundle() throws {
        try withTemporaryJournal { journal, markerURL in
            try journal.withExclusiveLock { access in
                try access.writeIntent(for: applicationURL)
            }
            let oldApplication = URL(fileURLWithPath: "/Applications/OldMacPilot.app")
            var elected = true
            var commands: [[String]] = []

            #expect(throws: FinderSyncRegistrationError.restorationNotConfirmed) {
                _ = try FinderSyncRegistration.recoverIfEnabled(
                    at: applicationURL,
                    journal: journal,
                    execute: { arguments in
                        commands.append(arguments)
                        if arguments.contains("ignore") { elected = false }
                        if arguments.contains("use") { elected = true }
                        if arguments == FinderSyncRegistration.queryArguments() {
                            return plugInOutput(enabled: elected, at: oldApplication)
                        }
                        if arguments == FinderSyncRegistration.queryArguments(includeAllVersions: true) {
                            return plugInOutput(enabled: true, at: oldApplication)
                        }
                        return ""
                    }
                )
            }

            #expect(FileManager.default.fileExists(atPath: markerURL.path))
            #expect(commands.contains(["-e", "use", "-i", extensionIdentifier]))
        }
    }

    @Test func corruptedMarkerNeverAuthorizesAutomaticReenable() throws {
        try withTemporaryJournal { journal, markerURL in
            try Data(#"{"schemaVersion":999,"bundleIdentifier":"com.misswell.macpilot.finder-sync"}"#.utf8)
                .write(to: markerURL, options: .atomic)
            var commands: [[String]] = []

            #expect(throws: FinderSyncRecoveryJournalError.invalidMarker) {
                _ = try FinderSyncRegistration.recoverIfEnabled(
                    at: applicationURL,
                    journal: journal,
                    execute: { arguments in
                        commands.append(arguments)
                        return "-    \(extensionIdentifier)(1.1.501)"
                    }
                )
            }

            #expect(commands == [FinderSyncRegistration.queryArguments()])
            #expect(try Data(contentsOf: markerURL) == Data(#"{"schemaVersion":999,"bundleIdentifier":"com.misswell.macpilot.finder-sync"}"#.utf8))
        }
    }

    @Test func validMarkerForAnotherApplicationCannotAuthorizeRecovery() throws {
        try withTemporaryJournal { journal, markerURL in
            let otherApplication = URL(fileURLWithPath: "/Applications/Other.app")
            try journal.withExclusiveLock { access in
                try access.writeIntent(for: otherApplication)
            }
            var commands: [[String]] = []

            #expect(throws: FinderSyncRegistrationError.journalTargetMismatch) {
                _ = try FinderSyncRegistration.recoverIfEnabled(
                    at: applicationURL,
                    journal: journal,
                    execute: { arguments in
                        commands.append(arguments)
                        return "-    \(extensionIdentifier)(1.1.501)"
                    }
                )
            }

            #expect(commands == [FinderSyncRegistration.queryArguments()])
            #expect(FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func lockContentionFailsPromptlyInsteadOfWaitingIndefinitely() throws {
        try withTemporaryJournal { journal, _ in
            try journal.withExclusiveLock { _ in
                #expect(throws: FinderSyncRecoveryJournalError.lockBusy) {
                    try journal.withExclusiveLock { _ in }
                }
            }
        }
    }

    @Test func lookalikeBundleIdentifierDoesNotCountAsEnabled() {
        #expect(
            !FinderSyncRegistration.isElectedForUse(
                in: "+ com.misswell.macpilot.finder-sync-copy(1.1.501)"
            )
        )
    }

    private func withTemporaryJournal<T>(
        _ body: (FinderSyncRecoveryJournal, URL) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderSyncRecoveryJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let markerURL = directory.appendingPathComponent("finder-sync-recovery.json")
        return try body(FinderSyncRecoveryJournal(fileURL: markerURL), markerURL)
    }

    private func plugInOutput(enabled: Bool, at applicationURL: URL) -> String {
        let status = enabled ? "+" : "-"
        let extensionPath = applicationURL
            .appendingPathComponent("Contents/PlugIns/FinderSync.appex")
            .path
        return "\(status)\t\(extensionIdentifier)(1.1.501)\tTEST-UUID\t\(extensionPath)"
    }
}
