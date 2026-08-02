import Foundation
@testable import Agents

/// Shared test helpers. Every test gets its own unique temp-file stateURL so
/// tests are hermetic and parallel-safe, and never touch the real app's
/// state.json.
@MainActor
enum TestSupport {
    static func freshStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.json")
    }

    /// Builds a fresh store backed by a fresh spy and a fresh temp state
    /// file. No projects/sessions exist yet.
    static func makeStore() -> (store: AppStore, spy: SpyTerminals, stateURL: URL) {
        let spy = SpyTerminals()
        let url = freshStateURL()
        let store = AppStore(terminals: spy, stateURL: url)
        return (store, spy, url)
    }
}
