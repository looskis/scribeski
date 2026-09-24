import Testing
@testable import Capture

@Suite struct CallSourceGrouping {
    func proc(_ pid: Int32, _ bundle: String, owner: String, name: String? = nil,
              playing: Bool = false) -> AudioProcess {
        AudioProcess(objectID: UInt32(pid), pid: pid, bundleID: bundle, responsibleBundleID: owner,
                     responsibleName: name, isRunningOutput: playing)
    }

    /// The finding that shaped P2.1: Safari's audio comes from a launchd-parented
    /// `com.apple.WebKit.GPU`, so it must group under Safari by responsible app.
    @Test func safariGPUProcessGroupsUnderSafari() {
        let sources = CallSources.group([
            proc(1882, "com.apple.WebKit.GPU", owner: "com.apple.Safari", playing: true),
            proc(1869, "com.apple.Safari", owner: "com.apple.Safari"),
        ])
        #expect(sources.count == 1)
        #expect(sources[0].name == "Safari")
        #expect(sources[0].kind == .browser)
        #expect(sources[0].isPlaying)
        #expect(sources[0].processes.map(\.pid) == [1869, 1882])
        #expect(sources[0].isolationWarning?.contains("every Safari tab") == true)
    }

    @Test func webAppIsNotTheWholeBrowser() {
        let sources = CallSources.group([
            proc(10, "com.apple.WebKit.GPU", owner: "com.apple.Safari.WebApp.1234", name: "Google Meet"),
            proc(11, "com.apple.WebKit.GPU", owner: "com.apple.Safari"),
        ])
        #expect(sources.map(\.name) == ["Google Meet", "Safari"])
        #expect(sources[0].kind == .webApp)
    }

    @Test func callAppsFirstThenPlayingThenName() {
        let sources = CallSources.group([
            proc(1, "com.google.Chrome.helper", owner: "com.google.Chrome", playing: true),
            proc(2, "com.apple.Safari", owner: "com.apple.Safari"),
            proc(3, "us.zoom.xos", owner: "us.zoom.xos"),
            proc(4, "com.spotify.client", owner: "com.spotify.client", name: "Spotify", playing: true),
        ])
        #expect(sources.map(\.name) == ["Zoom", "Google Chrome", "Spotify", "Safari"])
    }

    @Test func appUsingTheMicIsInACallAndRanksFirst() {
        func p(_ pid: Int32, _ owner: String, mic: Bool = false, out: Bool = false) -> AudioProcess {
            AudioProcess(objectID: UInt32(pid), pid: pid, bundleID: owner, responsibleBundleID: owner,
                         isRunningOutput: out, isRunningInput: mic)
        }
        let sources = CallSources.group([
            p(1, "us.zoom.xos", out: true),                 // Zoom open, playing a chime, not in a call
            p(2, "com.apple.Safari", mic: true, out: true), // a Meet tab using the mic
            p(3, "com.tinyspeck.slackmacgap"),
        ])
        #expect(sources.map(\.name) == ["Safari", "Zoom", "Slack"])
        #expect(sources[0].isInCall)
        #expect(!sources[1].isInCall)
        // A dictation app using the mic isn't a call.
        #expect(!CallSources.group([p(4, "com.example.dictate", mic: true, out: true)])[0].isInCall)
    }

    @Test func onlyNativeCallAppsAreFollowedByBundleID() {
        let zoom = CallSource(bundleID: "us.zoom.xos", name: "Zoom", kind: .callApp, processes: [
            AudioProcess(objectID: 1, pid: 1, bundleID: "us.zoom.CptHost", responsibleBundleID: "us.zoom.xos")])
        #expect(zoom.restorableBundleIDs == ["us.zoom.CptHost", "us.zoom.xos"])
        let safari = CallSource(bundleID: "com.apple.Safari", name: "Safari", kind: .browser, processes: [])
        #expect(safari.restorableBundleIDs.isEmpty)
    }

    @Test func unknownSilentAppsAreHiddenAndSelfIsExcluded() {
        let sources = CallSources.group([
            proc(1, "com.example.quiet", owner: "com.example.quiet"),
            proc(2, "app.scribeski", owner: "app.scribeski", playing: true),
        ], excluding: ["app.scribeski"])
        #expect(sources.isEmpty)
    }

    @Test func specificPrefixBeatsShorterOne() {
        #expect(CallSources.classify("com.apple.Safari.WebApp.ABC")?.kind == .webApp)
        #expect(CallSources.classify("com.apple.Safari")?.kind == .browser)
        #expect(CallSources.classify("com.microsoft.teams2")?.kind == .callApp)
        #expect(CallSources.classify("com.example") == nil)
    }
}
