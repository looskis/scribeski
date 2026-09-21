/// What the app shell provides to the package's views (it owns the pieces that only an app
/// target can link, such as the updater).
@MainActor public enum AppHooks {
    /// "Check for Updates…": nil when updates aren't configured (dev builds).
    public static var checkForUpdates: (@MainActor () -> Void)?
}
