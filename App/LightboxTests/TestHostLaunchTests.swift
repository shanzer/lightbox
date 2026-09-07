import Testing
import Foundation
import LightboxCore
@testable import Lightbox

/// The App test target is hosted in the real app (`TEST_HOST` in
/// `project.pbxproj`), so `xcodebuild test` launches `LightboxApp` before a
/// single test runs. Until #15 that launch reached `BrowserView.start()` →
/// `BrowserModel()` → `IndexStore(url: .defaultURL)`, which created, migrated
/// and switched to WAL the *user's* `~/Library/Application Support/Lightbox/
/// index.sqlite` as a side effect of running the suite. Phase 2's launch-time
/// journal reconcile would run against the real library the same way.
///
/// These tests read the environment this process was actually launched with,
/// so they are evidence about the real test host rather than about a fixture:
/// if `isTestHost` stops recognising a future Xcode's variables, the first
/// test goes red here rather than silently letting the app open the index
/// again. `launchIndexURL(in:)` is the single place the app picks the URL —
/// `BrowserModel.init(at:)` has no default argument, so there is no other way
/// to reach `IndexStore.defaultURL` by accident.
struct TestHostLaunchTests {
    @Test func thisProcessIsRecognisedAsATestHost() {
        #expect(LaunchEnvironment.isTestHost())
    }

    @Test func aTestHostLaunchIsGivenNoIndexToOpen() {
        #expect(LaunchEnvironment.launchIndexURL() == nil)
    }

    /// The wiring, not the policy. Testing `LaunchEnvironment` alone leaves the
    /// hole that matters open: hardcoding `BrowserView.launchIndexURL` to
    /// `IndexStore.defaultURL` keeps every other test in this file green while
    /// the test host opens the real index again — verified by making exactly
    /// that mutation, which this test and only this test catches.
    @Test @MainActor func theViewTakesItsURLFromLaunchEnvironment() {
        #expect(BrowserView().launchIndexURL == nil)
    }

    /// One expectation per variable, each on its own, so a toolchain that stops
    /// setting one of the three is caught here rather than by a test run
    /// quietly writing to the user's library.
    ///
    /// The empty string is not a typo. Under Xcode 26 the test host really is
    /// launched with `XCTestConfigurationFilePath` set to `""` — the variable
    /// is present and carries no path — which is why `isTestHost` tests for
    /// presence rather than for a non-empty value.
    @Test func eachXCTestVariableIsRecognisedOnItsOwn() {
        #expect(LaunchEnvironment.isTestHost(in: ["XCTestConfigurationFilePath": "/x.xctestconfiguration"]))
        #expect(LaunchEnvironment.isTestHost(in: ["XCTestConfigurationFilePath": ""]))
        #expect(LaunchEnvironment.isTestHost(in: ["XCTestBundlePath": "/x.xctest"]))
        #expect(LaunchEnvironment.isTestHost(in: ["XCTestSessionIdentifier": "ABC-123"]))
    }

    /// The guard must not change what a normal launch does (#15's "out of
    /// scope"): an environment with none of the XCTest variables still gets
    /// the real index.
    @Test func aNormalLaunchStillOpensTheDefaultIndex() {
        #expect(LaunchEnvironment.launchIndexURL(in: [:]) == IndexStore.defaultURL)
        #expect(LaunchEnvironment.isTestHost(in: ["HOME": "/Users/nobody"]) == false)
    }

    /// The explicit opt-in, for anything that hosts the app outside XCTest's
    /// variables (a UI-test runner, a CI smoke launch).
    @Test func theExplicitOptInIsHonoured() {
        #expect(LaunchEnvironment.isTestHost(in: ["LIGHTBOX_TEST_HOST": "1"]))
        #expect(LaunchEnvironment.launchIndexURL(in: ["LIGHTBOX_TEST_HOST": "1"]) == nil)
    }
}
