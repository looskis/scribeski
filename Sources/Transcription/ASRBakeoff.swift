import Capture
import Foundation
import ScribeskiCore

/// The ASR bake-off harness (BUILD_PLAN P2.8). For each recorded session and each engine, it
/// runs the *streaming* path the app uses (segmenter → bounded queue → transcriber, fed from
/// the files as fast as the engine keeps up) and scores it against a hand-corrected
/// reference: WER per track, entity error rate (numbers, dates, names, acronyms: the words
/// a note depends on), real-time factor, and gaps.
///
/// A session is a folder holding `client.<wav|m4a|…>`, optionally `worker.<…>`, and
/// `reference.json` (`[{speaker, start, end, text}]`, the format `synth-audio.swift` writes).
/// Zoom's "record a separate audio file for each participant" gives the two tracks.
///
/// Field accuracy, the decisive metric, is a second step: each engine's transcript is written
/// out so `scribeski extract` + `scribeski score` can run on it against the gold transcript.
public enum ASRBakeoff {
    public struct Session: Sendable {
        public var name: String
        public var client: URL
        public var worker: URL?
        public var reference: [TranscriptionProbe.ReferenceLine]
    }

    public struct Row: Codable, Sendable {
        public var session: String
        public var engine: String
        public var audioSeconds: Double
        public var wer: [String: Double]
        public var entityErrorRate: [String: Double]
        public var entities: [String: Int]
        public var realTimeFactor: Double
        public var gaps: Int
        public var errors: Int
    }

    static let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aiff", "aif", "caf", "flac"]

    /// Every session folder under `directory` (or `directory` itself, if it is one).
    public static func sessions(in directory: URL) throws -> [Session] {
        let fm = FileManager.default
        func session(_ dir: URL) throws -> Session? {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            func track(_ name: String) -> URL? {
                files.first { $0.deletingPathExtension().lastPathComponent == name && audioExtensions.contains($0.pathExtension.lowercased()) }
            }
            let ref = dir.appendingPathComponent("reference.json")
            guard let client = track("client"), fm.fileExists(atPath: ref.path) else { return nil }
            let lines = try JSONDecoder().decode([TranscriptionProbe.ReferenceLine].self, from: Data(contentsOf: ref))
            return Session(name: dir.lastPathComponent, client: client, worker: track("worker"), reference: lines)
        }
        if let one = try session(directory) { return [one] }
        let dirs = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try dirs.compactMap(session)
    }

    /// Transcribes one session with one (prepared) engine and scores it.
    public static func run(_ session: Session, transcriber: any Transcriber) async throws -> (Row, Transcript) {
        // Unbounded queue: files arrive faster than real time, and the bake-off measures
        // accuracy and speed, not the live backlog policy (the probe covers that).
        let live = LiveTranscription(retention: .none, transcriber: transcriber, queueCapacitySeconds: 1e9)
        let clock = ContinuousClock()
        let started = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (speaker, url) in [(Speaker.client, session.client), (.worker, session.worker)] {
                guard let url else { continue }
                live.noteTrack(speaker, source: "file:\(url.lastPathComponent)")
                group.addTask {
                    try await FileTrack.run(url, speaker: speaker, settled: { live.settle(speaker, through: $0) }) { live.submit($0) }
                }
            }
            try await group.waitForAll()
        }
        let transcript = await live.stop()
        let elapsed = clock.now - started
        let audio = session.reference.map(\.end).max() ?? 0

        var wer: [String: Double] = [:], eer: [String: Double] = [:], counts: [String: Int] = [:]
        for speaker in Speaker.allCases {
            let ref = session.reference.filter { $0.speaker == speaker }.map(\.text).joined(separator: " ")
            guard !ref.isEmpty else { continue }
            let hyp = transcript.segments.filter { $0.speaker == speaker }.map(\.text).joined(separator: " ")
            wer[speaker.rawValue] = WordErrorRate.compute(reference: ref, hypothesis: hyp)
            let ents = entities(ref)
            counts[speaker.rawValue] = ents.count
            eer[speaker.rawValue] = entityErrorRate(reference: ents, hypothesis: hyp)
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let row = Row(session: session.name, engine: transcriber.engine, audioSeconds: audio, wer: wer,
                      entityErrorRate: eer, entities: counts,
                      realTimeFactor: audio > 0 ? seconds / audio : 0, gaps: transcript.gaps.count, errors: live.errors.count)
        return (row, transcript)
    }

    // MARK: - Entities

    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
        "first": "1", "second": "2", "third": "3",
    ]
    static let calendarWords: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]
    static let notNames: Set<String> = ["i", "i'm", "i've", "i'll", "i'd", "okay", "ok", "yeah", "um", "uh", "mm", "oh",
                                        "dr", "mr", "mrs", "ms", "st", "jr", "sr"]

    /// The words a note depends on: anything with a digit (numbers, dates, phones, doses),
    /// spelled numbers, months and weekdays, capitalized words mid-sentence (names, places,
    /// medications), and acronyms. Normalized for matching.
    public static func entities(_ text: String) -> [String] {
        var out: [String] = []
        // Titles end in a period that doesn't end the sentence ("Dr. Okafor").
        var text = text
        for title in ["Dr.", "Mr.", "Mrs.", "Ms.", "St.", "Jr.", "Sr."] {
            text = text.replacingOccurrences(of: title, with: String(title.dropLast()))
        }
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".?!"))
        for sentence in sentences {
            let raw = sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for (i, token) in raw.enumerated() {
                let word = token.trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-/:")).inverted)
                guard !word.isEmpty else { continue }
                let lower = normalize(word), plain = word.lowercased()
                if word.contains(where: \.isNumber) || numberWords[plain] != nil || calendarWords.contains(plain) {
                    out.append(lower)
                } else if word.count >= 2, word == word.uppercased(), word.contains(where: \.isLetter) {
                    out.append(lower) // acronym
                } else if i > 0, word.first?.isUppercase == true, !notNames.contains(lower) {
                    out.append(lower) // a name mid-sentence
                }
            }
        }
        return out
    }

    static func normalize(_ word: String) -> String {
        let w = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if let n = numberWords[w] { return n }
        return w.filter { !"-/:,".contains($0) }
    }

    /// Share of reference entities missing from the hypothesis (as a multiset: saying a date
    /// twice needs it twice).
    public static func entityErrorRate(reference: [String], hypothesis: String) -> Double {
        guard !reference.isEmpty else { return 0 }
        var available: [String: Int] = [:]
        let hypWords = hypothesis.split(whereSeparator: { $0.isWhitespace }).map {
            normalize($0.trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-/:")).inverted))
        }
        for w in hypWords where !w.isEmpty { available[w, default: 0] += 1 }
        var missing = 0
        for e in reference {
            if let n = available[e], n > 0 { available[e] = n - 1 } else { missing += 1 }
        }
        return Double(missing) / Double(reference.count)
    }

    // MARK: - Report

    public static func markdown(_ rows: [Row], date: Date = .now) -> String {
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }
        var md = "# ASR bake-off — \(date.formatted(.iso8601.year().month().day()))\n\n"
        md += "Streaming path (segmenter → queue → engine), fed from files. WER and entity error rate per track; "
        md += "RTF = processing time / audio time (below 1 keeps up). Field accuracy: run `scribeski extract` + "
        md += "`scribeski score` on the transcripts saved beside this report.\n\n"
        md += "| Session | Engine | Client WER | Worker WER | Client entity err | Worker entity err | RTF | Gaps | Errors |\n"
        md += "|---|---|---|---|---|---|---|---|---|\n"
        for r in rows {
            md += "| \(r.session) | \(r.engine) | \(pct(r.wer["client"])) | \(pct(r.wer["worker"])) | "
            md += "\(pct(r.entityErrorRate["client"])) (\(r.entities["client"] ?? 0)) | \(pct(r.entityErrorRate["worker"])) (\(r.entities["worker"] ?? 0)) | "
            md += String(format: "%.2f", r.realTimeFactor) + " | \(r.gaps) | \(r.errors) |\n"
        }
        let engines = Array(Set(rows.map(\.engine))).sorted()
        if engines.count > 1 || rows.count > 1 {
            md += "\n**Averages**\n\n| Engine | Client WER | Worker WER | Client entity err | Worker entity err | RTF |\n|---|---|---|---|---|---|\n"
            for e in engines {
                let rs = rows.filter { $0.engine == e }
                func avg(_ f: (Row) -> Double?) -> Double? {
                    let v = rs.compactMap(f)
                    return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
                }
                md += "| \(e) | \(pct(avg { $0.wer["client"] })) | \(pct(avg { $0.wer["worker"] })) | "
                md += "\(pct(avg { $0.entityErrorRate["client"] })) | \(pct(avg { $0.entityErrorRate["worker"] })) | "
                md += String(format: "%.2f", avg { $0.realTimeFactor } ?? 0) + " |\n"
            }
        }
        return md
    }
}
