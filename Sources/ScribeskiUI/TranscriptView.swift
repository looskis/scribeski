import ScribeskiCore
import SwiftUI

/// The session's transcript, both tracks merged by time, with gaps shown where they fall.
/// Text only: there's no audio to play in `none` retention (DESIGN §3a).
public struct TranscriptView: View {
    public static let windowID = "transcript"
    let model: SessionModel

    public init(model: SessionModel) {
        self.model = model
    }

    private enum Row: Identifiable {
        case segment(Transcript.Segment)
        case gap(Transcript.Gap, Int)

        var id: String {
            switch self {
            case .segment(let s): s.id
            case .gap(_, let i): "gap\(i)"
            }
        }
        var start: Double {
            switch self {
            case .segment(let s): s.start
            case .gap(let g, _): g.start
            }
        }
    }

    public var body: some View {
        Group {
            if let transcript = model.transcript {
                let rows = (transcript.segments.map(Row.segment)
                    + transcript.gaps.enumerated().map { Row.gap($1, $0) }).sorted { $0.start < $1.start }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            switch row {
                            case .segment(let s): SegmentRow(segment: s)
                            case .gap(let g, _): GapRow(gap: g)
                            }
                        }
                    }
                    .padding(16)
                }
                .navigationSubtitle("\(transcript.segments.count) lines · \(transcript.sessionId)")
            } else {
                ContentUnavailableView("No transcript", systemImage: "text.bubble",
                                       description: Text("Finish a session to see its transcript here."))
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle("Transcript")
    }
}

private func clock(_ seconds: Double) -> String {
    Duration.seconds(max(seconds, 0)).formatted(.time(pattern: .minuteSecond))
}

private struct SegmentRow: View {
    let segment: Transcript.Segment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(clock(segment.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            Text(segment.speaker == .worker ? "You" : "Client")
                .font(.caption.weight(.semibold))
                .foregroundStyle(segment.speaker == .worker ? Color.accentColor : .purple)
                .frame(width: 44, alignment: .leading)
            Text(segment.text).textSelection(.enabled)
            Spacer(minLength: 0)
            if let c = segment.confidence, c < 0.5 {
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                    .help("Low recognition confidence (\(Int(c * 100))%)")
            }
        }
    }
}

private struct GapRow: View {
    let gap: Transcript.Gap

    var body: some View {
        Label("\(gap.track == .worker ? "Your" : "Client") audio missing \(clock(gap.start))–\(clock(gap.end)) (\(reason))",
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
    }

    private var reason: String {
        switch gap.reason {
        case .deviceRebuild: "audio device changed"
        case .transcriberBacklog: "transcription fell behind"
        case .transcriberCrash: "transcriber restarted"
        case .captureOverrun: "capture fell behind"
        }
    }
}
