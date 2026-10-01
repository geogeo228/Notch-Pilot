import Foundation

/// Georgi fork: update checks and self-update are removed entirely —
/// no GitHub polling, no DMG download, no quarantine stripping.
/// Same interface as upstream so the UI compiles unchanged; it simply
/// never reports an update.
@MainActor
final class UpdateChecker: ObservableObject {
    enum UpdateState: Equatable {
        case idle
        case updating
        case failed(String)
    }

    @Published private(set) var latestVersion: String?
    @Published private(set) var updateAvailable = false
    @Published private(set) var state: UpdateState = .idle

    var currentVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return (v?.isEmpty == false) ? v! : "0.0.0"
    }

    func startPeriodicChecks() {}
    func performUpdate() {}
}
