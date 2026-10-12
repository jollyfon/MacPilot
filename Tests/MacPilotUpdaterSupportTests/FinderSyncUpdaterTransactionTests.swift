import Foundation
import Testing
@testable import MacPilotUpdaterSupport

struct FinderSyncUpdaterTransactionTests {
    @Test func confirmedMissingPluginRemovalKeepsTheNewBundleAndRestoresExactElection() throws {
        let result = try runUpdateTransaction(failAdds: false)

        #expect(result.errorDescription == nil)
        #expect(result.version == "1.2.2")
        #expect(!result.journalHasIntent)
        #expect(FinderSyncRegistration.isElectedForUse(in: result.finalQueryOutput, for: result.applicationURL))

        let inventoryQueries = result.queries.filter {
            $0.arguments == FinderSyncRegistration.queryArguments(includeAllVersions: true)
        }
        #expect(inventoryQueries.count == 2)
        if inventoryQueries.count == 2 {
            #expect(FinderSyncRegistration.registeredExtensionPaths(in: inventoryQueries[0].output)
                == [result.applicationURL.appendingPathComponent("Contents/PlugIns/FinderSync.appex").path])
            #expect(inventoryQueries[1].output.isEmpty)
        }
        let removalIndex = try #require(result.commands.firstIndex { $0.first == "-r" })
        let addIndex = try #require(result.commands.firstIndex { $0.first == "-a" })
        #expect(removalIndex < addIndex)
        #expect(result.queries.last?.arguments == FinderSyncRegistration.queryArguments())
    }

    @Test func failedRegistrationRollsBackBundleAndKeepsUnconfirmedRecoveryIntent() throws {
        let result = try runUpdateTransaction(failAdds: true)

        #expect(result.errorDescription == "add failed")
        #expect(result.version == "1.2.1")
        #expect(result.journalHasIntent)
        #expect(!FinderSyncRegistration.isElectedForUse(in: result.finalQueryOutput, for: result.applicationURL))
    }
}

private struct TransactionQuery {
    let arguments: [String]
    let output: String
}

private struct TransactionResult {
    let applicationURL: URL
    let version: String
    let errorDescription: String?
    let journalHasIntent: Bool
    let commands: [[String]]
    let queries: [TransactionQuery]
    let finalQueryOutput: String
}

private func runUpdateTransaction(failAdds: Bool) throws -> TransactionResult {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FinderSyncUpdaterTransaction-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let applicationURL = root.appendingPathComponent("MacPilot.app", isDirectory: true)
    try writeTemporaryAppVersion("1.2.1", to: applicationURL)
    let targetPath = applicationURL.appendingPathComponent("Contents/PlugIns/FinderSync.appex").path
    let journal = FinderSyncRecoveryJournal(fileURL: root.appendingPathComponent("journal.json"))

    var targetRegistered = true
    var elected = true
    var commands: [[String]] = []
    var queries: [TransactionQuery] = []
    var finalQueryOutput = ""
    var transactionError: Error?

    let execute: ([String]) throws -> Void = { arguments in
        commands.append(arguments)
        if arguments == ["-e", "ignore", "-i", FinderSyncRegistration.extensionBundleIdentifier] {
            elected = false
            return
        }
        if arguments.first == "-r" {
            targetRegistered = false
            throw NSError(
                domain: "MacPilotUpdater.PlugInKit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "remove: no plugin at \(arguments[1])"]
            )
        }
        if arguments.first == "-a" {
            if failAdds {
                throw NSError(domain: "MacPilotUpdater.PlugInKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "add failed"])
            }
            targetRegistered = true
            return
        }
        if arguments == ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier] {
            elected = true
        }
    }
    let query: ([String]) throws -> String = { arguments in
        let output = targetRegistered ? temporaryPlugInKitOutput(enabled: elected, path: targetPath) : ""
        queries.append(TransactionQuery(arguments: arguments, output: output))
        if arguments == FinderSyncRegistration.queryArguments() { finalQueryOutput = output }
        return output
    }

    do {
        try FinderSyncRegistration.withSuspendedElection(
            applicationURL: applicationURL,
            journal: journal,
            execute: execute,
            query: query,
            operation: {
                try writeTemporaryAppVersion("1.2.2", to: applicationURL)
                do {
                    try refreshTemporaryApplication(
                        at: applicationURL,
                        execute: execute,
                        query: query
                    )
                } catch {
                    let installationError = error
                    try writeTemporaryAppVersion("1.2.1", to: applicationURL)
                    do {
                        try refreshTemporaryApplication(
                            at: applicationURL,
                            execute: execute,
                            query: query
                        )
                    } catch {
                        // Match the updater: preserve the installation error and leave recovery pending
                        // if rollback registration cannot be confirmed.
                    }
                    throw installationError
                }
            }
        )
    } catch {
        transactionError = error
    }

    let version = try temporaryAppVersion(at: applicationURL)
    let journalHasIntent = try journal.withExclusiveLock { try $0.readIntent() != nil }
    return TransactionResult(
        applicationURL: applicationURL,
        version: version,
        errorDescription: transactionError.map { ($0 as NSError).localizedDescription },
        journalHasIntent: journalHasIntent,
        commands: commands,
        queries: queries,
        finalQueryOutput: finalQueryOutput
    )
}

private func refreshTemporaryApplication(
    at applicationURL: URL,
    execute: ([String]) throws -> Void,
    query: ([String]) throws -> String
) throws {
    let inventory = try query(FinderSyncRegistration.queryArguments(includeAllVersions: true))
    try FinderSyncRegistration.refreshRegistrations(
        at: applicationURL,
        registeredExtensionPaths: FinderSyncRegistration.registeredExtensionPaths(in: inventory),
        execute: execute,
        query: query
    )
}

private func writeTemporaryAppVersion(_ version: String, to applicationURL: URL) throws {
    let contents = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "com.misswell.macpilot",
        "CFBundleExecutable": "MacPilot",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "1",
        "MacPilotVersion": version
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
}

private func temporaryAppVersion(at applicationURL: URL) throws -> String {
    let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
    let data = try Data(contentsOf: infoURL)
    let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    return try #require(info?["MacPilotVersion"] as? String)
}

private func temporaryPlugInKitOutput(enabled: Bool, path: String) -> String {
    let status = enabled ? "+" : "-"
    return "\(status)\tcom.misswell.macpilot.finder-sync(1.2.2)\tTEST-UUID\t\(path)"
}
