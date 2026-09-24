import Capture
import FormDriver
import Foundation
import Observation
import Orchestrator
import ScribeskiCore

/// First run (BUILD_PLAN P4.3): permissions with live checks, Safari's JavaScript setting,
/// the models, the recording choice, a first form, and a mic check. Every step can be
/// skipped; the menu still shows whatever is missing, and "Set up Scribeski…" reopens this.
@MainActor @Observable public final class OnboardingModel {
    public enum Step: Int, CaseIterable, Sendable {
        case welcome, permissions, safari, models, recording, form, micCheck, done

        public var title: String {
            switch self {
            case .welcome: "Welcome"
            case .permissions: "Permissions"
            case .safari: "Safari"
            case .models: "Models"
            case .recording: "Recording"
            case .form: "Your form"
            case .micCheck: "Mic check"
            case .done: "Ready"
            }
        }
    }

    public enum SafariCheck: Equatable, Sendable {
        case unchecked, checking, allowed
        case blocked(String)
    }

    public var step: Step = .welcome
    public var safariCheck: SafariCheck = .unchecked
    public var formsLearned: [String] = []
    public let session: SessionModel
    public let models: ModelsModel
    public let settings: AppSettings
    public let mic = MicCheck()
    /// Snapshots and tests: don't touch TCC, Safari, or the model store.
    public var live = true

    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private let library: FormLibrary

    public init(session: SessionModel, models: ModelsModel, settings: AppSettings = .shared,
                library: FormLibrary = FormLibrary()) {
        self.session = session
        self.models = models
        self.settings = settings
        self.library = library
    }

    public var permissionsReady: Bool {
        [Permission.microphone, .callAudio].allSatisfy { session.permissions[$0] == .granted }
    }

    public var canGoBack: Bool { step != .welcome && step != .done }

    public func next() {
        leave(step)
        step = Step(rawValue: step.rawValue + 1) ?? .done
        enter(step)
    }

    public func back() {
        leave(step)
        step = Step(rawValue: step.rawValue - 1) ?? .welcome
        enter(step)
    }

    public func go(_ to: Step) {
        leave(step)
        step = to
        enter(to)
    }

    /// Onboarding's done: the menu stops offering it at launch.
    public func finish() {
        leave(step)
        settings.onboarded = true
    }

    public func appeared() { enter(step) }
    public func disappeared() { leave(step) }

    private func enter(_ step: Step) {
        guard live else { return }
        switch step {
        case .permissions:
            // Live: the worker flips a switch in System Settings and this ticks over.
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    self?.session.refreshPermissions()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        case .models: models.refresh()
        case .form: refreshForms()
        case .micCheck: mic.start()
        default: break
        }
    }

    private func leave(_ step: Step) {
        poller?.cancel()
        poller = nil
        if step == .micCheck { mic.stop() }
    }

    public func refreshForms() {
        formsLearned = library.forms().map(\.name).sorted()
    }

    public func request(_ permission: Permission) async {
        await session.request(permission)
    }

    /// Runs `'ok'` in the front Safari tab (reads nothing, changes nothing) to see whether
    /// Safari accepts JavaScript from Apple Events. Only when the worker presses Check.
    public func checkSafari() async {
        safariCheck = .checking
        let result: SafariCheck = await Task.detached {
            let tabs: [SafariTab]
            do throws(TransportError) {
                tabs = try SafariTabs.list()
            } catch {
                return .blocked(error.description)
            }
            guard let tab = tabs.first(where: \.isFront) else {
                return .blocked("Open any page in Safari, then check again.")
            }
            if let blocked = SafariTabs.javaScriptBlocked(in: tab) {
                return .blocked(blocked == .javaScriptFromAppleEventsDisabled
                    ? "Not yet: “Allow JavaScript from Apple Events” is still off."
                    : blocked.description)
            }
            return .allowed
        }.value
        safariCheck = result
        session.refreshPermissions()
    }
}
