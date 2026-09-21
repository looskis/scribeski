import Darwin
import Foundation
import SuiteModelStore
import Synchronization

/// The local LLM sidecar (BUILD_PLAN P3.2): `llama-server`, spawned only after recording
/// stops (never during the call: ~16 GB of weights would fight the call app on 32 GB), and
/// locked down:
///
/// - A unix socket in a fresh 0700 directory. No TCP port, so no other user can reach it.
/// - A random per-launch API key, passed as a file (0600, deleted once the server reads it)
///   so it never shows in `ps`.
/// - Web UI off, slot endpoints off (`/slots` can expose cached prompts, i.e. the transcript),
///   and both verified after launch.
/// - `stop()` ends the process, which is what erases its KV cache: the transcript's last copy.
///
/// stdout is discarded and stderr kept only as a short in-memory tail for error messages.
public final class LlamaServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var binary: URL
        public var model: URL
        public var modelName: String
        /// The flags DESIGN §4 depends on (see `scripts/llama-serve.sh` for why each exists).
        public var arguments = ["-c", "32768", "-np", "1", "--swa-full", "-ctk", "q8_0", "-ctv", "q8_0",
                                "-fa", "on", "-rea", "off", "--no-webui", "--no-slots", "--jinja"]
        public var startupTimeout: Duration = .seconds(180)
        /// Passed the eval gates. False: the review shows "model not validated".
        public var validated = true

        public init(binary: URL, model: URL, modelName: String) {
            self.binary = binary
            self.model = model
            self.modelName = modelName
        }

        /// The LLM this app resolves to (the worker's choice, else the catalog default), if it's
        /// been downloaded. `validated` is false for custom models and unvalidated catalog ones.
        public static func fromModelStore(appName: String = "Scribeski", appID: String = "scribeski") throws -> Configuration {
            guard let binary = findBinary() else { throw Failure.noBinary }
            let locator = try ModelLocator(appName: appName, appID: appID)
            let resolution = locator.resolution(.llm)
            guard let local = locator.localURL(.llm), let name = locator.name(.llm) else {
                throw Failure.notReady("the language model isn't downloaded yet (Settings → Models)")
            }
            // A catalog snapshot is a directory holding the .gguf; a custom model is the file.
            var model = local
            if case .catalog(let m)? = resolution.model, let gguf = m.files.first(where: { $0.path.hasSuffix(".gguf") }) {
                model = local.appendingPathComponent(gguf.path)
            }
            var config = Configuration(binary: binary, model: model, modelName: name)
            config.validated = resolution.validated
            return config
        }

        /// The bundled, signed helper (P4.1). Release builds use nothing else: a binary on the
        /// PATH is whatever anyone put there. Debug builds may fall back to a dev install.
        public static func findBinary() -> URL? {
            var candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama-server")]
            #if DEBUG
            candidates += [
                URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"),
                URL(fileURLWithPath: "/usr/local/bin/llama-server"),
            ]
            #endif
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noBinary
        case exited(Int32, String)
        case notReady(String)
        case lockdown(String)

        public var description: String {
            switch self {
            case .noBinary: "The note-writing helper is missing from Scribeski.app. Reinstall Scribeski."
            case .exited(let code, let tail): "llama-server exited (\(code)). \(tail)"
            case .notReady(let why): "llama-server didn't become ready: \(why)"
            case .lockdown(let what): "llama-server isn't locked down: \(what). Refusing to send it the transcript."
            }
        }
    }

    public let configuration: Configuration
    private var process: Process?
    private var directory: URL?
    private let stderrTail = TailBuffer(limit: 4_096)
    public private(set) var client: UnixSocketChatClient?

    public init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    deinit { stop() }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Launches, waits for the model to load, and checks the lockdown. Returns the client.
    @discardableResult
    public func start() async throws -> UnixSocketChatClient {
        if let client, isRunning { return client }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("scribeski-llm-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = dir
        let socket = dir.appendingPathComponent("llm.sock").path
        let key = try Self.randomKey()
        let keyFile = dir.appendingPathComponent("key")
        fm.createFile(atPath: keyFile.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])

        let p = Process()
        p.executableURL = configuration.binary
        p.arguments = ["-m", configuration.model.path, "--host", socket, "--api-key-file", keyFile.path]
            + configuration.arguments
        // Not the app's environment: llama.cpp takes most options from LLAMA_ARG_* variables,
        // so an inherited one could quietly re-enable what the flags turn off.
        p.environment = ["TMPDIR": fm.temporaryDirectory.path]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { [tail = stderrTail] h in tail.append(h.availableData) }
        try p.run()
        process = p
        Self.running.withLock { $0[ObjectIdentifier(self)] = Weak(self) }

        let client = UnixSocketChatClient(socketPath: socket, model: configuration.modelName, apiKey: key)
        do {
            try await waitUntilReady(client.http, apiKey: key)
            try? fm.removeItem(at: keyFile) // read at startup; no reason to leave it on disk
            try await verifyLockdown(client.http, apiKey: key)
        } catch {
            stop()
            throw error
        }
        self.client = client
        return client
    }

    /// Ends the process (erasing its KV cache) and removes the socket directory.
    public func stop() {
        Self.running.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(self)) }
        if let p = process, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning, Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        client = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func waitUntilReady(_ http: UnixSocketHTTP, apiKey: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.startupTimeout
        var quick = http
        quick.timeout = .seconds(5)
        while clock.now < deadline {
            if let p = process, !p.isRunning {
                throw Failure.exited(p.terminationStatus, stderrTail.lastLine)
            }
            // 503 while loading, 200 once the model is in. Refused until the socket exists.
            if let r = try? await quick.request("GET", "/health", headers: ["Authorization": "Bearer \(apiKey)"]),
               r.status == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure.notReady("no healthy response in \(configuration.startupTimeout)")
    }

    /// Verified against the running server, not assumed from the flags. Each probe must get an
    /// answer: a probe that fails (a timeout, a dropped connection) fails the check.
    private func verifyLockdown(_ http: UnixSocketHTTP, apiKey: String) async throws {
        var quick = http
        quick.timeout = .seconds(5)
        let auth = ["Authorization": "Bearer \(apiKey)"]
        func probe(_ method: String, _ path: String, _ headers: [String: String], _ body: Data? = nil) async throws -> (status: Int, body: Data) {
            do {
                let r = try await quick.request(method, path, headers: headers, body: body)
                return (r.status, r.body)
            } catch {
                throw Failure.lockdown("couldn't check \(path) (\(error))")
            }
        }
        if (200..<300).contains(try await probe("GET", "/slots", auth).status) {
            throw Failure.lockdown("/slots is enabled")
        }
        let root = try await probe("GET", "/", auth)
        if (200..<300).contains(root.status), String(decoding: root.body, as: UTF8.self).localizedCaseInsensitiveContains("<html") {
            throw Failure.lockdown("the web UI is enabled")
        }
        // Without the key, completions must be refused.
        let body = Data(#"{"messages":[{"role":"user","content":"ping"}],"max_tokens":1}"#.utf8)
        let anonymous = try await probe("POST", "/v1/chat/completions", ["Content-Type": "application/json"], body)
        if anonymous.status != 401 {
            throw Failure.lockdown("requests without the API key get \(anonymous.status)")
        }
    }

    static func randomKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.lockdown("no randomness for the API key")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Lifetime beyond one session

    private final class Weak: @unchecked Sendable {
        weak var server: LlamaServer?
        init(_ server: LlamaServer) { self.server = server }
    }
    private static let running = Mutex<[ObjectIdentifier: Weak]>([:])

    /// Stops every helper this process started. Call at quit: a helper outliving the app would
    /// keep the last transcript in its KV cache until reboot.
    public static func stopAll() {
        for w in running.withLock({ Array($0.values) }) { w.server?.stop() }
    }

    /// At launch: ends helpers a crashed or killed Scribeski left behind (our bundled binary,
    /// orphaned to launchd), and removes their socket directories. Returns how many it ended.
    @discardableResult
    public static func sweepOrphans(helper: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama-server")) -> Int {
        var ended = 0, alive = 0
        let want = helper.resolvingSymlinksInPath().path
        let count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(max(count, 0)) + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        for pid in pids.prefix(max(n, 0)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(cString: path) == want else { continue }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  info.pbi_uid == getuid() else { continue }
            if info.pbi_ppid == 1 {
                kill(pid, SIGKILL)
                ended += 1
            } else {
                alive += 1 // another running Scribeski's helper: leave it and its directory
            }
        }
        if alive == 0 {
            let tmp = FileManager.default.temporaryDirectory
            for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("scribeski-llm-") {
                try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
        return ended
    }
}

/// The last few KB of a stream, for error messages.
final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit { data = data.suffix(limit) }
        }
    }

    var lastLine: String {
        lock.withLock {
            String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        }
    }
}
