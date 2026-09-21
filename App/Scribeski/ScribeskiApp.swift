import Darwin
import Foundation
import ScribeskiUI
import SwiftUI
import UserNotifications

/// The app target stays thin: all logic lives in the package (ScribeskiUI and below).
/// Developer probes and demos live in `DevModes.swift`, compiled into Debug builds only.
@main
struct ScribeskiApp: App {
    @State private var model: SessionModel
    @State private var learn = LearnModel()
    @State private var models: ModelsModel
    @State private var onboarding: OnboardingModel
    @MainActor static var callWatcher: CallWatcher?

    init() {
        // A core dump would hold live audio and transcript buffers (DESIGN §3a).
        var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &noCore)

        #if DEBUG
        DevModes.runExclusiveModes()
        let model = SessionModel(driver: DevModes.simulated ? SimulatedDriver() : LiveDriver())
        let watchCalls = !DevModes.suppressesCallWatcher
        #else
        let model = SessionModel(driver: LiveDriver())
        let watchCalls = true
        #endif
        if watchCalls {
            let watcher = CallWatcher(model: model)
            watcher.start()
            Self.callWatcher = watcher
            NotificationClicks.shared.model = model
            UNUserNotificationCenter.current().delegate = NotificationClicks.shared
        }
        #if DEBUG
        var learn = LearnModel()
        DevModes.configure(model: model, learn: &learn)
        _learn = State(initialValue: learn)
        #endif
        _model = State(initialValue: model)
        let models = ModelsModel()
        _models = State(initialValue: models)
        _onboarding = State(initialValue: OnboardingModel(session: model, models: models))
        Updates.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
                .hiddenFromScreenSharing()
        } label: {
            Image(systemName: model.menuBarSymbol)
                .background(AppEvents(model: model))
        }
        .menuBarExtraStyle(.window)

        // The review panel floats beside Safari (P3.3), so it stays visible while you check the form.
        Window("Review", id: ReviewView.windowID) {
            ReviewView(model: model)
                .hiddenFromScreenSharing()
        }
        .defaultSize(width: 520, height: 680)
        .windowLevel(.floating)
        .defaultWindowPlacement { _, context in
            let screen = context.defaultDisplay.visibleRect
            return WindowPlacement(CGPoint(x: screen.maxX - 540, y: screen.minY + 40))
        }

        Window("Learn a form", id: LearnView.windowID) {
            LearnView(model: learn)
                .hiddenFromScreenSharing()
        }
        .defaultSize(width: 620, height: 640)

        // Opened from a "call started" notification: the same controls as the menu.
        Window("Start transcribing", id: "start") {
            MenuView(model: model)
                .hiddenFromScreenSharing()
        }
        .windowResizability(.contentSize)
        .windowLevel(.floating)

        Window("Sessions", id: SessionsView.windowID) {
            SessionsView(model: model)
                .hiddenFromScreenSharing()
        }
        .defaultSize(width: 560, height: 380)

        Settings {
            SettingsView(models: models)
        }

        // First run (P4.3): opens at launch until setup is finished.
        Window("Set up Scribeski", id: OnboardingView.windowID) {
            OnboardingView(model: onboarding)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Self.showsOnboardingAtLaunch ? .presented : .suppressed)

        Window("Transcript", id: TranscriptView.windowID) {
            TranscriptView(model: model)
                .hiddenFromScreenSharing()
        }
        .defaultSize(width: 640, height: 520)
        .defaultLaunchBehavior(Self.demoTranscript ? .presented : .suppressed)
    }

    @MainActor static var showsOnboardingAtLaunch: Bool {
        #if DEBUG
        !AppSettings.shared.onboarded && !DevModes.suppressesCallWatcher && !DevModes.demoTranscript
        #else
        !AppSettings.shared.onboarded
        #endif
    }

    static var demoTranscript: Bool {
        #if DEBUG
        DevModes.demoTranscript
        #else
        false
        #endif
    }
}

/// Opens windows the model asks for (the start panel from a notification, review when notes
/// are filled).
private struct AppEvents: View {
    let model: SessionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: model.wantsStartPanel) { _, wants in
                guard wants else { return }
                model.wantsStartPanel = false
                openWindow(id: "start")
                NSApplication.shared.activate()
            }
            #if DEBUG
            .background(DevWindowOpener(model: model))
            #endif
    }
}

/// Routes a click on the "call started" notification to the start panel.
final class NotificationClicks: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationClicks()
    @MainActor weak var model: SessionModel?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { model?.wantsStartPanel = true }
    }

    // Show it even though the app is technically active (it's a menu-bar app).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
