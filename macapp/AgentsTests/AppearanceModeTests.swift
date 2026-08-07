import AppKit
import XCTest
@testable import Agents

final class AppearanceModeTests: XCTestCase {
    /// Guards the UserDefaults persistence contract documented on
    /// `AppearanceMode`: these strings are what's already saved in existing
    /// users' defaults, so a rename here would silently reset their
    /// preference back to .system.
    func testRawValuesAreStable() {
        XCTAssertEqual(AppearanceMode.system.rawValue, "system")
        XCTAssertEqual(AppearanceMode.light.rawValue, "light")
        XCTAssertEqual(AppearanceMode.dark.rawValue, "dark")
    }

    /// Guards against `.light`/`.dark` getting swapped, or `.system` gaining
    /// a non-nil appearance and thereby losing its "follow the system"
    /// meaning.
    func testNSAppearanceMapping() {
        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
    }

    /// Guards `apply()` actually reaching `NSApp.appearance`, in both
    /// directions: setting a forced appearance and clearing back to nil for
    /// "follow system". Saves and restores the prior appearance so mutating
    /// this shared, process-wide app state doesn't leak into other tests
    /// hosted in the same run.
    @MainActor
    func testApplySetsAndClearsNSAppAppearance() {
        let original = NSApp.appearance
        defer { NSApp.appearance = original }

        AppearanceMode.dark.apply()
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)

        AppearanceMode.light.apply()
        XCTAssertEqual(NSApp.appearance?.name, .aqua)

        AppearanceMode.system.apply()
        XCTAssertNil(NSApp.appearance)
    }
}
