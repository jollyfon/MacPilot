import SwiftUI

/// Public bridge for embedding the right-click menu settings UI in MacPilot.
///
/// The individual settings views intentionally remain module-private;
/// exposing one host keeps the integration surface small while still giving
/// the main app access to the complete configuration UI.
public struct RightClickSettingsHost: View {
    @StateObject private var extensionController: FinderExtensionSettingsController

    public init(extensionOperation: @escaping @MainActor (Bool?) async throws -> Bool) {
        _extensionController = StateObject(wrappedValue:
            FinderExtensionSettingsController(operation: extensionOperation))
    }

    public var body: some View {
        RightClickSettingsView()
            .environmentObject(AppState.shared)
            .environmentObject(extensionController)
    }
}
