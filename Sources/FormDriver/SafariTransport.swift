import AppKit
import ScriptingBridge

/// Runs a JavaScript expression in a browser tab and returns its string result.
///
/// Safari's `do JavaScript` is synchronous and returns the completion value of the script.
/// A Promise is not awaited, so async page work goes through the job protocol
/// (`PageSession`) instead.
public protocol JSTransport: Sendable {
    func evaluate(_ script: String) throws(TransportError) -> String
}

public enum TransportError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Safari → Develop → "Allow JavaScript from Apple Events" is off.
    case javaScriptFromAppleEventsDisabled
    /// The user hasn't allowed this process to control Safari (TCC Automation).
    case automationNotPermitted
    /// The Apple Event timed out. On first use this is almost always the Automation
    /// permission prompt waiting for an answer.
    case timedOut
    case safariNotRunning
    case noWindow
    case scriptError(String)
    case unexpectedResult(String)

    public var description: String {
        switch self {
        case .javaScriptFromAppleEventsDisabled:
            "Safari is blocking JavaScript from Apple Events. In Safari → Settings → Advanced, turn on "
                + "“Show features for web developers”; then in Settings → Developer, turn on "
                + "“Allow JavaScript from Apple Events”."
        case .automationNotPermitted:
            "This app isn't allowed to control Safari. Allow it in System Settings → Privacy & Security → Automation."
        case .timedOut:
            "Safari didn't answer. If macOS is asking whether this app may control Safari, click Allow and try again."
        case .safariNotRunning: "Safari isn't running."
        case .noWindow: "Safari has no open window."
        case .scriptError(let m): "Safari script error: \(m)"
        case .unexpectedResult(let m): "Unexpected result from Safari: \(m)"
        }
    }

    /// Maps an Apple Event error message/number onto a specific case.
    static func classify(message: String, code: Int?) -> TransportError {
        if message.contains("Allow JavaScript from Apple Events") { return .javaScriptFromAppleEventsDisabled }
        // errAEEventNotPermitted (-1743): the TCC Automation grant is missing or denied.
        if code == -1743 || message.localizedCaseInsensitiveContains("not allowed to send Apple events") {
            return .automationNotPermitted
        }
        // errAETimeout (-1712).
        if code == -1712 || message.contains("-1712") || message.localizedCaseInsensitiveContains("timed out") {
            return .timedOut
        }
        return .scriptError(message)
    }
}

/// `do JavaScript` through ScriptingBridge: the script travels as an NSString, so there is
/// no AppleScript string escaping and no size limit from source-code quoting.
public final class ScriptingBridgeSafari: JSTransport, @unchecked Sendable {
    // ScriptingBridge objects aren't thread-safe; every call is serialized on this lock.
    private let lock = NSLock()
    /// nil: the current tab of the front window. Otherwise that exact tab, wherever it is.
    public let target: (windowID: Int, tabIndex: Int)?

    public init() { target = nil }

    /// Talks to one specific tab, so a worker switching tabs can't redirect the writes.
    public init(tab: SafariTab) { target = (tab.windowID, tab.tabIndex) }

    public func evaluate(_ script: String) throws(TransportError) -> String {
        lock.lock()
        defer { lock.unlock() }

        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else {
            throw .safariNotRunning
        }
        guard let safari = SBApplication(bundleIdentifier: "com.apple.Safari") else { throw .safariNotRunning }
        let errors = ErrorCollector()
        safari.delegate = errors

        guard let windows = safari.value(forKey: "windows") as? SBElementArray, windows.count > 0 else {
            if let e = errors.error { throw e }
            throw .noWindow
        }
        let tab: SBObject
        if let target {
            let window = (0..<windows.count).lazy.compactMap { windows.object(at: $0) as? SBObject }
                .first { ($0.value(forKey: "id") as? Int) == target.windowID }
            guard let window, let tabs = window.value(forKey: "tabs") as? SBElementArray,
                  target.tabIndex >= 1, target.tabIndex <= tabs.count,
                  let t = tabs.object(at: target.tabIndex - 1) as? SBObject else {
                if let e = errors.error { throw e }
                throw .noWindow
            }
            tab = t
        } else {
            guard let front = windows.object(at: 0) as? SBObject,
                  let t = front.value(forKey: "currentTab") as? SBObject else {
                if let e = errors.error { throw e }
                throw .noWindow
            }
            tab = t
        }

        let selector = NSSelectorFromString("doJavaScript:in:")
        let raw = safari.perform(selector, with: script, with: tab)?.takeUnretainedValue()
        if let e = errors.error { throw e }
        guard let result = raw as? String else {
            throw .unexpectedResult(raw.map { String(describing: $0) } ?? "nil")
        }
        return result
    }

    /// ScriptingBridge reports Apple Event failures through its delegate, not by throwing.
    private final class ErrorCollector: NSObject, SBApplicationDelegate {
        var error: TransportError?

        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
            let ns = error as NSError
            let message = (ns.userInfo["ErrorString"] as? String)
                ?? (ns.userInfo[NSLocalizedDescriptionKey] as? String)
                ?? ns.localizedDescription
            let code = (ns.userInfo["ErrorNumber"] as? Int) ?? ns.code
            self.error = TransportError.classify(message: message, code: code)
            return nil
        }
    }
}

/// `do JavaScript` through NSAppleScript. Fallback if ScriptingBridge misbehaves.
/// The script is embedded in AppleScript source, so it's escaped here.
public final class AppleScriptSafari: JSTransport, @unchecked Sendable {
    private let lock = NSLock()

    public init() {}

    public func evaluate(_ script: String) throws(TransportError) -> String {
        lock.lock()
        defer { lock.unlock() }

        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "com.apple.Safari"
            if (count of windows) is 0 then error "no window" number -1728
            do JavaScript "\(escaped)" in current tab of front window
        end tell
        """
        guard let apple = NSAppleScript(source: source) else { throw .scriptError("could not compile") }
        var info: NSDictionary?
        let result = apple.executeAndReturnError(&info)
        if let info {
            let message = info[NSAppleScript.errorMessage] as? String ?? "unknown error"
            let code = info[NSAppleScript.errorNumber] as? Int
            if code == -1728 && message == "no window" { throw .noWindow }
            throw TransportError.classify(message: message, code: code)
        }
        guard let value = result.stringValue else {
            throw .unexpectedResult(result.description)
        }
        return value
    }
}
