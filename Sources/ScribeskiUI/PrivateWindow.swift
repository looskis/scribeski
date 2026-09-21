import AppKit
import SwiftUI

extension View {
    /// Asks macOS to leave this window out of screen sharing and screenshots
    /// (`NSWindow.sharingType = .none`): review, transcript, and session windows show client
    /// text, often during a live Zoom call. Best effort: some capture paths may ignore it, so
    /// workers are still told not to share their screen while reviewing.
    public func hiddenFromScreenSharing() -> some View {
        background(SharingNone())
    }
}

private struct SharingNone: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.sharingType = .none
        }
    }
}
