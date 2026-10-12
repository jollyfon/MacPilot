import Foundation
import Testing
@testable import MacPilot

@MainActor
struct SoftwareUpdateInstallerTests {
    @Test func upgradeSelectsTheHelperBundledWithTheVerifiedTarget() throws {
        try withUpdateApps { root, installedApp, packageApp in
            try writeInstallerApp(at: installedApp, version: "1.2.1", helperContents: "installed helper")
            try writeInstallerApp(at: packageApp, version: "1.2.2", helperContents: "verified target helper")
            let updater = SoftwareUpdater(currentVersion: "1.2.1", applicationURL: installedApp)
            let package = VerifiedUpdatePackage(applicationURL: packageApp, workingDirectory: root)

            #expect(try updater.installerHelperURL(for: package) == helperURL(in: packageApp))
        }
    }

    @Test func downgradeKeepsTheNewerInstalledUpdaterHelper() throws {
        try withUpdateApps { root, installedApp, packageApp in
            try writeInstallerApp(at: installedApp, version: "1.2.2", helperContents: "newer installed helper")
            try writeInstallerApp(at: packageApp, version: "1.2.1", helperContents: "older target helper")
            let updater = SoftwareUpdater(currentVersion: "1.2.2", applicationURL: installedApp)
            let package = VerifiedUpdatePackage(applicationURL: packageApp, workingDirectory: root)

            #expect(try updater.installerHelperURL(for: package) == helperURL(in: installedApp))
        }
    }

    @Test func upgradeFailsWhenTheVerifiedTargetDoesNotContainItsSelectedHelper() throws {
        try withUpdateApps { root, installedApp, packageApp in
            try writeInstallerApp(at: installedApp, version: "1.2.1", helperContents: "old helper")
            try writeInstallerApp(at: packageApp, version: "1.2.2", helperContents: nil)
            let updater = SoftwareUpdater(currentVersion: "1.2.1", applicationURL: installedApp)
            let package = VerifiedUpdatePackage(applicationURL: packageApp, workingDirectory: root)

            #expect(throws: SoftwareUpdateError.updaterHelperMissing) {
                try updater.installerHelperURL(for: package)
            }
        }
    }

    @Test func downgradeFailsWhenTheInstalledBundleDoesNotContainItsSelectedHelper() throws {
        try withUpdateApps { root, installedApp, packageApp in
            try writeInstallerApp(at: installedApp, version: "1.2.2", helperContents: nil)
            try writeInstallerApp(at: packageApp, version: "1.2.1", helperContents: "older package helper")
            let updater = SoftwareUpdater(currentVersion: "1.2.2", applicationURL: installedApp)
            let package = VerifiedUpdatePackage(applicationURL: packageApp, workingDirectory: root)

            #expect(throws: SoftwareUpdateError.updaterHelperMissing) {
                try updater.installerHelperURL(for: package)
            }
        }
    }
}

private func withUpdateApps(_ body: (URL, URL, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SoftwareUpdateInstallerTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try body(
        root,
        root.appendingPathComponent("Installed.app", isDirectory: true),
        root.appendingPathComponent("VerifiedTarget.app", isDirectory: true)
    )
}

private func writeInstallerApp(at applicationURL: URL, version: String, helperContents: String?) throws {
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let executablesURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: executablesURL, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "com.misswell.macpilot",
        "CFBundleExecutable": "MacPilot",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "1",
        "MacPilotVersion": version
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)

    if let helperContents {
        let helperURL = helperURL(in: applicationURL)
        try Data(helperContents.utf8).write(to: helperURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    }
}

private func helperURL(in applicationURL: URL) -> URL {
    applicationURL.appendingPathComponent("Contents/MacOS/MacPilotUpdater")
}
