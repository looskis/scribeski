import Foundation

/// Talks to the page bundle (`page/`) in the current tab: installs it when missing or older,
/// runs commands through the job protocol, and re-injects after navigation.
public final class PageSession: @unchecked Sendable {
    public enum Error: Swift.Error, CustomStringConvertible {
        case transport(TransportError)
        case bundleMissing
        case badResponse(String)
        case job(String)
        case timeout(job: String)

        public var description: String {
            switch self {
            case .transport(let t): t.description
            case .bundleMissing: "page bundle not found (run `npm run build` in page/)"
            case .badResponse(let s): "bad response from page: \(s)"
            case .job(let s): "page error: \(s)"
            case .timeout(let job): "page job \(job) timed out"
            }
        }
    }

    public let transport: any JSTransport
    public let bundleSource: String
    public let bundleVersion: String
    public var pollInterval: Duration = .milliseconds(50)

    public init(transport: any JSTransport, bundleSource: String) throws(Error) {
        guard let version = Self.version(of: bundleSource) else { throw .bundleMissing }
        self.transport = transport
        self.bundleSource = bundleSource
        self.bundleVersion = version
    }

    /// Loads the copy built into this module (Debug builds: `SCRIBESKI_PAGE_BUNDLE` overrides,
    /// for page development). Never in Release: an environment variable anyone can set with
    /// `launchctl setenv` would run their script in EHR tabs under our Automation permission.
    public static func loadBundle() throws(Error) -> String {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SCRIBESKI_PAGE_BUNDLE"],
           let s = try? String(contentsOfFile: path, encoding: .utf8) {
            return s
        }
        #endif
        guard let url = Bundle.module.url(forResource: "scribeski-page", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8)
        else { throw .bundleMissing }
        return s
    }

    /// Evaluates a JS expression and returns its value as JSON-decoded `Any`.
    /// Exceptions in the page come back as `.job` errors, not as Apple Event failures.
    public func evaluate(_ expression: String) throws(Error) -> Any? {
        let wrapped = """
        (function(){try{return JSON.stringify({ok:true,v:(\(expression))});}\
        catch(e){return JSON.stringify({ok:false,e:String(e&&e.message||e)});}})()
        """
        let raw: String
        do { raw = try transport.evaluate(wrapped) } catch { throw .transport(error) }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) as? [String: Any]
        else { throw .badResponse(raw) }
        if obj["ok"] as? Bool == true { return obj["v"] is NSNull ? nil : obj["v"] }
        throw .job(obj["e"] as? String ?? raw)
    }

    /// Installs the bundle unless the page already has this version or newer.
    /// Returns true if it injected.
    @discardableResult
    public func ensureInstalled() throws(Error) -> Bool {
        let installed = try evaluate("window.__scribeski ? window.__scribeski.version : null") as? String
        if let installed, !Self.isNewer(bundleVersion, than: installed) { return false }
        do { _ = try transport.evaluate(bundleSource + "\n;'installed'") } catch { throw .transport(error) }
        return true
    }

    /// Runs one command through the job protocol and returns its `result`.
    /// If the page navigates mid-job (bundle gone), the job is lost and this throws.
    public func run(_ command: [String: Any], timeout: Duration = .seconds(30)) async throws(Error) -> Any? {
        try ensureInstalled()
        guard let json = try? JSONSerialization.data(withJSONObject: command),
              let cmd = String(data: json, encoding: .utf8)
        else { throw .badResponse("unencodable command") }

        let started = try evaluate("JSON.parse(window.__scribeski.start(\(Self.jsString(cmd))))") as? [String: Any]
        guard let job = started?["job"] as? String else {
            throw .job(started?["error"] as? String ?? "start failed")
        }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let state = try evaluate(
                "window.__scribeski ? JSON.parse(window.__scribeski.poll(\(Self.jsString(job)))) : {done:true,ok:false,error:'navigated'}"
            ) as? [String: Any]
            if state?["done"] as? Bool == true {
                if state?["ok"] as? Bool == true { return state?["result"] }
                throw .job(state?["error"] as? String ?? "unknown")
            }
            try? await Task.sleep(for: pollInterval)
        }
        throw .timeout(job: job)
    }

    /// A JS string literal. JSON string encoding is valid JS for any content.
    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Reads the version from the build's banner: `/* scribeski-page 1.2.3 */`.
    static func version(of bundle: String) -> String? {
        let prefix = "/* scribeski-page "
        guard bundle.hasPrefix(prefix), let end = bundle.range(of: " */") else { return nil }
        return String(bundle[bundle.index(bundle.startIndex, offsetBy: prefix.count)..<end.lowerBound])
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let d = (i < pa.count ? pa[i] : 0) - (i < pb.count ? pb[i] : 0)
            if d != 0 { return d > 0 }
        }
        return false
    }
}
