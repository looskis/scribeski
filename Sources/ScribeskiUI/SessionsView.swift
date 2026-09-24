import SwiftUI

/// Sessions that ended without "I've reviewed this" (BUILD_PLAN P3.5): pick one up where it
/// stopped, or discard it (its key is destroyed). The menu blocks new sessions at 2× the
/// limit, so these don't pile up unreviewed.
public struct SessionsView: View {
    public static let windowID = "sessions"
    @Bindable var model: SessionModel

    public init(model: SessionModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Waiting for review").font(.headline)
            if model.pendingSessions.isEmpty {
                ContentUnavailableView("Nothing waiting", systemImage: "checkmark.circle",
                                       description: Text("Every session has been reviewed."))
            } else {
                List(model.pendingSessions.reversed(), id: \.sessionID) { s in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.client ?? "No chart chosen").font(.body.weight(.medium))
                            Text("\(s.started.formatted(date: .abbreviated, time: .shortened)) · "
                                 + (s.hasNotes ? "notes written" : "\(s.lines) line\(s.lines == 1 ? "" : "s") transcribed"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(s.hasNotes ? "Continue to filling" : "Continue to notes") {
                            model.resume(s)
                            model.wantsStartPanel = true
                        }
                        .disabled(model.state != .idle)
                        Button("Discard", role: .destructive) { model.discardRecovery(s) }
                    }
                    .padding(.vertical, 4)
                }
            }
            Text("Discarding destroys the session's key: its transcript and notes can't be recovered. The audit log keeps a record that it existed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 320)
        .onAppear { model.findRecovery() }
    }
}
