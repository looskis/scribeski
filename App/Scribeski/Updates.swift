import Foundation
import ScribeskiUI
import Sparkle

/// Updates (BUILD_PLAN P4.4): Sparkle 2 with an EdDSA-signed appcast. Nothing starts until the
/// release build carries both the feed URL and the public key (build settings
/// `SCRIBESKI_UPDATE_FEED` and `SCRIBESKI_UPDATE_PUBLIC_KEY`, see SHIPPING.md), so a dev build
/// never contacts anything. The check sends the app and OS version to the update host; no
/// system profile (`SUEnableSystemProfiling` is off) and nothing about sessions. An agency can
/// turn automatic checks off with a profile (`SUEnableAutomaticChecks` = false).
@MainActor final class Updates {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    static var configured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        return feed.hasPrefix("https://") && !key.isEmpty
    }

    func start() {
        guard Self.configured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        AppHooks.checkForUpdates = { [weak self] in self?.controller?.checkForUpdates(nil) }
    }
}
