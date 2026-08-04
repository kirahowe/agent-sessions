import XCTest
@testable import Agents

/// `AppStore.stateDirectoryName(forBundleIdentifier:)` is a pure static
/// function nested in the @MainActor-isolated AppStore class, so calling it
/// requires the same actor context as any other AppStore member — hence
/// @MainActor here too, matching AppStoreTests.swift's annotation for the
/// same reason. These are not part of that file's numbered refactor-spec
/// list, so they live in their own small XCTestCase instead of being folded
/// into it.
@MainActor
final class AppStoreStateDirectoryTests: XCTestCase {

    func testDevBundleIdentifierMapsToAgentsDevDirectory() {
        XCTAssertEqual(
            AppStore.stateDirectoryName(forBundleIdentifier: "com.kirahowe.agents.dev"),
            "Agents Dev"
        )
    }

    func testReleaseBundleIdentifierMapsToAgentsDirectory() {
        XCTAssertEqual(
            AppStore.stateDirectoryName(forBundleIdentifier: "com.kirahowe.agents"),
            "Agents"
        )
    }

    func testNilBundleIdentifierMapsToAgentsDirectory() {
        XCTAssertEqual(
            AppStore.stateDirectoryName(forBundleIdentifier: nil),
            "Agents"
        )
    }
}
