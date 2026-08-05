import AppKit
import XCTest

/// Asset catalogs fail *silently*: a typo in a colorset's name, or malformed
/// JSON inside its Contents.json, resolves to a nil `NSColor` rather than a
/// build error — the app would just render with the system's default blue
/// tint, with nothing in `bb build` or `bb test` to say why. This is the one
/// thing standing between a broken `AccentColor` colorset and nobody noticing
/// until they actually look at the running app.
///
/// `NSColor(named:)` resolves against `Bundle.main`. AgentsTests is a
/// *hosted* bundle — `TEST_HOST`/`BUNDLE_LOADER` in project.yml point it at
/// Agents.app — so the test process IS the app, and `Bundle.main` here is
/// the real built Agents.app bundle rather than the test bundle. That's what
/// makes it possible to exercise the actual shipped asset catalog from here.
final class ThemeTests: XCTestCase {
    func testAccentColorResolves() {
        XCTAssertNotNil(
            NSColor(named: "AccentColor"),
            "AccentColor asset failed to resolve — check Assets.xcassets/AccentColor.colorset/Contents.json for a typo in the name or malformed JSON"
        )
    }

    func testAccentColorLightAppearanceMatchesBrandHex() {
        assertAccentColor(matchesHexRed: 0x00, green: 0x77, blue: 0x8C, in: .aqua)
    }

    func testAccentColorDarkAppearanceMatchesBrandHex() {
        assertAccentColor(matchesHexRed: 0x0D, green: 0x8A, blue: 0xA1, in: .darkAqua)
    }

    /// Resolves `AccentColor` under a forced appearance and compares its
    /// sRGB components against an expected 0–255 triple.
    ///
    /// `NSColor(named:)` vends a *dynamic* colour: its actual RGB isn't
    /// fixed until something resolves it against a specific appearance, and
    /// a bare XCTestCase has no window or view to inherit an
    /// `effectiveAppearance` from. `performAsCurrentDrawingAppearance` is
    /// what lets a test control that resolution directly, by making the
    /// given appearance the one in effect for the duration of the closure —
    /// the component accessors below (`redComponent` etc.) are what actually
    /// trigger the dynamic provider to resolve against it.
    ///
    /// Tolerance is one 8-bit step (1/255) plus a small epsilon for
    /// floating-point round-trip error through the sRGB conversion — tight
    /// enough to catch a wrong hex digit, loose enough not to be fragile
    /// against harmless float rounding.
    private func assertAccentColor(
        matchesHexRed red: Int,
        green: Int,
        blue: Int,
        in appearanceName: NSAppearance.Name,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let appearance = NSAppearance(named: appearanceName) else {
            XCTFail("NSAppearance(named: \(appearanceName.rawValue)) is unavailable", file: file, line: line)
            return
        }

        appearance.performAsCurrentDrawingAppearance {
            guard let color = NSColor(named: "AccentColor")?.usingColorSpace(.sRGB) else {
                XCTFail("AccentColor failed to resolve, or could not convert to sRGB", file: file, line: line)
                return
            }

            let tolerance = 1.0 / 255.0 + 0.001
            XCTAssertEqual(Double(color.redComponent), Double(red) / 255.0, accuracy: tolerance, "red component", file: file, line: line)
            XCTAssertEqual(Double(color.greenComponent), Double(green) / 255.0, accuracy: tolerance, "green component", file: file, line: line)
            XCTAssertEqual(Double(color.blueComponent), Double(blue) / 255.0, accuracy: tolerance, "blue component", file: file, line: line)
        }
    }
}
