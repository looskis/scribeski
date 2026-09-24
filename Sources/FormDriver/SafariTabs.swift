import AppKit
import Foundation
import ScriptingBridge

/// One Safari tab, as found by listing windows. Reading this runs no JavaScript in any page.
public struct SafariTab: Hashable, Sendable, Codable {
    /// Safari's window id: stable while the window is open.
    public var windowID: Int
    /// 1-based position within the window. Can shift if tabs are moved or closed.
    public var tabIndex: Int
    /// 1 = frontmost window.
    public var windowOrder: Int
    public var isCurrentTab: Bool
    public var url: String
    public var title: String

    public init(windowID: Int, tabIndex: Int, windowOrder: Int, isCurrentTab: Bool, url: String, title: String) {
        self.windowID = windowID
        self.tabIndex = tabIndex
        self.windowOrder = windowOrder
        self.isCurrentTab = isCurrentTab
        self.url = url
        self.title = title
    }

    /// The tab the worker is looking at.
    public var isFront: Bool { windowOrder == 1 && isCurrentTab }
}

/// Safari's windows and tabs, through Apple Events (BUILD_PLAN P3.1). Listing reads only URLs
/// and titles, so it can scan every tab without touching any page.
///
/// ScriptingBridge, not NSAppleScript: the pipeline calls this from async code, off the main
/// thread, where NSAppleScript can hang (it did: a fill waited forever on bring-to-front).
public enum SafariTabs {
    private static let lock = NSLock()

    private static func safari() throws(TransportError) -> SBApplication {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty,
              let app = SBApplication(bundleIdentifier: "com.apple.Safari") else { throw .safariNotRunning }
        return app
    }

    public static func list() throws(TransportError) -> [SafariTab] {
        lock.lock()
        defer { lock.unlock() }
        let app = try safari()
        guard let windows = app.value(forKey: "windows") as? SBElementArray else { return [] }
        var out: [SafariTab] = []
        for w in 0..<windows.count {
            guard let window = windows.object(at: w) as? SBObject, let wid = window.value(forKey: "id") as? Int,
                  let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            let current = (window.value(forKey: "currentTab") as? SBObject)?.value(forKey: "index") as? Int
            for t in 0..<tabs.count {
                guard let tab = tabs.object(at: t) as? SBObject else { continue }
                out.append(SafariTab(windowID: wid, tabIndex: t + 1, windowOrder: w + 1, isCurrentTab: current == t + 1,
                                     url: tab.value(forKey: "URL") as? String ?? "",
                                     title: tab.value(forKey: "name") as? String ?? ""))
            }
        }
        return out
    }

    /// Opens `url` in Safari the way clicking a link would (Safari decides tab or window, per
    /// the user's settings), then waits for a tab that actually shows it. No window scripting:
    /// scripting "a new window" can land in the user's own window when Safari opens pages in
    /// tabs, and closing it then closes theirs (it did, 2026-09-23).
    public static func open(_ url: URL, timeout: Duration = .seconds(10)) async throws -> SafariTab {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw TransportError.scriptError("only web addresses can be opened")
        }
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            throw TransportError.safariNotRunning
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: config)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(300))
            if let tab = (try? list())?.first(where: { $0.url == url.absoluteString || sameAddress($0.url, url) }) {
                return tab
            }
        }
        throw TransportError.noWindow
    }

    /// Same scheme, host, port, and path (the page may add a fragment or trailing slash).
    static func sameAddress(_ tabURL: String, _ url: URL) -> Bool {
        guard let t = URL(string: tabURL) else { return false }
        func norm(_ p: String) -> String { p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
        return t.scheme?.lowercased() == url.scheme?.lowercased() && t.host()?.lowercased() == url.host()?.lowercased()
            && t.port == url.port && norm(t.path()) == norm(url.path())
    }

    /// Whether Safari runs JavaScript sent by Apple Events (Develop → "Allow JavaScript from
    /// Apple Events"), tried in `tab` with an expression that reads nothing and changes
    /// nothing. Nil when it does. Only on the worker's say-so (onboarding's Check button).
    public static func javaScriptBlocked(in tab: SafariTab) -> TransportError? {
        do {
            _ = try ScriptingBridgeSafari(tab: tab).evaluate("'ok'")
            return nil
        } catch {
            return error
        }
    }

    /// Makes `tab` the current tab of its window, that window frontmost, and Safari active.
    public static func bringToFront(_ tab: SafariTab) throws(TransportError) {
        lock.lock()
        defer { lock.unlock() }
        let app = try safari()
        guard let windows = app.value(forKey: "windows") as? SBElementArray,
              let window = (0..<windows.count).lazy.compactMap({ windows.object(at: $0) as? SBObject })
                .first(where: { ($0.value(forKey: "id") as? Int) == tab.windowID }),
              let tabs = window.value(forKey: "tabs") as? SBElementArray,
              tab.tabIndex >= 1, tab.tabIndex <= tabs.count,
              let target = tabs.object(at: tab.tabIndex - 1) as? SBObject else { throw .noWindow }
        window.setValue(target, forKey: "currentTab")
        window.setValue(1, forKey: "index")
        app.activate()
    }
}
