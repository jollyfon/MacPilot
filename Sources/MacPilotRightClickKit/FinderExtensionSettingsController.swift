import Combine
import Foundation

/// The host owns registration; the settings UI displays only confirmed state.
@MainActor
final class FinderExtensionSettingsController: ObservableObject {
    typealias Operation = @MainActor (Bool?) async throws -> Bool

    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func refresh() async {
        await perform(nil)
    }

    func setEnabled(_ enabled: Bool) async {
        await perform(enabled)
    }

    private func perform(_ requested: Bool?) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            isEnabled = try await operation(requested)
        } catch {
            errorMessage = AppLocalization.localized(error.localizedDescription)
            // A command can partially change registration before failing.
            // Re-read it so the switch never keeps a misleading old value.
            if requested != nil, let confirmed = try? await operation(nil) {
                isEnabled = confirmed
            }
        }
    }
}
