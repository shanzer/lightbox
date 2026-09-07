import Foundation
import LightboxCore

/// What the app is allowed to touch at launch, decided from the environment it
/// was launched with.
///
/// The App test target is hosted in the real app — `TEST_HOST` in
/// `project.pbxproj` points the test bundle at `Lightbox.app` — so
/// `xcodebuild -scheme Lightbox test` runs `LightboxApp.main()` before a single
/// test executes. Without a guard that launch is indistinguishable from a real
/// one: `BrowserView` built a `BrowserModel` on `IndexStore.defaultURL` and so
/// created, migrated and switched to WAL the *user's*
/// `~/Library/Application Support/Lightbox/index.sqlite` as a side effect of
/// running the suite. Phase 2 makes that worse, not better: the launch-time
/// journal reconcile and the schema migration would both run against the real
/// library every time anyone ran the tests.
///
/// The guard lives here, in the one place the app picks the index URL, rather
/// than in the test target — a test can only prove the real behaviour if it
/// asks the same question the app asks. `BrowserModel.init(at:)` deliberately
/// has *no* default argument for the same reason: `IndexStore.defaultURL` is
/// unreachable except through `launchIndexURL(in:)`.
enum LaunchEnvironment {
    /// True when this process was launched to host a test bundle.
    ///
    /// Three XCTest variables rather than one because which of them is set is
    /// not part of any contract: `XCTestConfigurationFilePath` is the classic
    /// one, `XCTestBundlePath` and `XCTestSessionIdentifier` are what recent
    /// Xcodes set. Recognising any of them means a toolchain that drops one
    /// does not silently re-open the user's index.
    ///
    /// **`!= nil` and not a non-empty check.** Under Xcode 26 the test host is
    /// launched with `XCTestConfigurationFilePath` set to the *empty string* —
    /// present, carrying no path. `environment["…"] != nil` sees that;
    /// `environment["…"]?.isEmpty == false`, or any truthiness test, would
    /// not, and the guard would silently stop working on the toolchain this
    /// was written for. `eachXCTestVariableIsRecognisedOnItsOwn` pins it. `LIGHTBOX_TEST_HOST=1` is
    /// the explicit opt-in for a harness that sets none of them — a UI-test
    /// runner, or a CI smoke launch — and needs no scheme or project edit to
    /// use, which matters because `project.pbxproj` here is hand-written.
    static func isTestHost(in environment: [String: String] =
                           ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["LIGHTBOX_TEST_HOST"] == "1"
    }

    /// The index to open at launch, or `nil` when this launch must not open
    /// one at all.
    ///
    /// Nil rather than a throwaway temp path on purpose: a temp index would
    /// still exercise `IndexStore`'s migration and integrity check under the
    /// test host, once per run, for nobody's benefit — and every test that
    /// wants a store already makes its own. Nothing to open is also the only
    /// answer that keeps the thumbnail cache directory, and whatever phase 2
    /// adds to launch, out of a test run.
    static func launchIndexURL(in environment: [String: String] =
                               ProcessInfo.processInfo.environment) -> URL? {
        isTestHost(in: environment) ? nil : IndexStore.defaultURL
    }
}
