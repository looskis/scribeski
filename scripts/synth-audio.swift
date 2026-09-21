#!/usr/bin/env swift
// Renders a transcript fixture into two single-speaker tracks with macOS voices (BUILD_PLAN P2.7).
//   swift scripts/synth-audio.swift fixtures/sample-session.txt <outdir> [--minutes 2]
//     [--second-voice FROM-TO]   client lines starting in that window (seconds) in another
//                                voice, as if someone else in the room spoke (P2.5's flag)
// Writes worker.wav, client.wav, distractor.wav (16 kHz mono Int16) and reference.json
// ([{speaker, start, end, text}] on the tracks' clock). Lines keep their turn order; a line
// starts at its fixture timestamp or when the previous line ends, whichever is later.
// TTS proves the pipeline is correct, not how accurate ASR is on real calls.
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: synth-audio.swift <session.txt> <outdir> [--minutes N]"); exit(2)
}
let fixture = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
let minutes = args.firstIndex(of: "--minutes").flatMap { Double(args[$0 + 1]) } ?? 2
let secondVoice: ClosedRange<Double>? = args.firstIndex(of: "--second-voice").flatMap { i in
    let parts = args[i + 1].split(separator: "-").compactMap { Double($0) }
    return parts.count == 2 ? parts[0]...parts[1] : nil
}
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let voices = ["WORKER": "Samantha", "CLIENT": "Daniel"]
let rate = 16_000.0
let pattern = try NSRegularExpression(pattern: #"^\[(\d+):(\d\d)\] (WORKER|CLIENT): (.+)$"#)

struct Line: Encodable { let speaker: String; let start: Double; let end: Double; let text: String; var voice: String? = nil }

func render(_ text: String, voice: String) throws -> [Int16] {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("synth-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", voice, "-o", tmp.path, "--data-format=LEI16@16000", text]
    try p.run(); p.waitUntilExit()
    let file = try AVAudioFile(forReading: tmp, commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
}

var tracks: [String: [Int16]] = ["WORKER": [], "CLIENT": []]
var reference: [Line] = []
var cursor = 0.0
for raw in try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n") {
    let line = String(raw)
    guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
    func group(_ i: Int) -> String { String(line[Range(m.range(at: i), in: line)!]) }
    let stamp = Double(group(1))! * 60 + Double(group(2))!
    guard stamp < minutes * 60 else { break }
    let speaker = group(3), text = group(4)
    let other = speaker == "CLIENT" && secondVoice?.contains(stamp) == true
    let samples = try render(text, voice: other ? "Karen" : voices[speaker]!)
    let start = max(stamp, cursor)
    let end = start + Double(samples.count) / rate
    let at = Int(start * rate)
    if tracks[speaker]!.count < at { tracks[speaker]! += [Int16](repeating: 0, count: at - tracks[speaker]!.count) }
    tracks[speaker]! += samples
    reference.append(Line(speaker: speaker.lowercased(), start: start, end: end, text: text, voice: other ? "other" : nil))
    cursor = end + 0.4
}

func write(_ samples: [Int16], _ name: String) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
    let file = try AVAudioFile(forWriting: out.appendingPathComponent(name), settings: format.settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
    samples.withUnsafeBufferPointer { buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    try file.write(from: buffer)
}
let length = max(tracks["WORKER"]!.count, tracks["CLIENT"]!.count)
for (speaker, name) in [("WORKER", "worker.wav"), ("CLIENT", "client.wav")] {
    try write(tracks[speaker]! + [Int16](repeating: 0, count: length - tracks[speaker]!.count), name)
}
// A third voice that must never appear in the client track (capture isolation).
var distractor: [Int16] = []
while distractor.count < length {
    distractor += try render("This is a distractor playing from a different app. It must not appear in the transcript.", voice: "Moira")
    distractor += [Int16](repeating: 0, count: Int(rate))
}
try write(Array(distractor.prefix(length)), "distractor.wav")

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted]
try encoder.encode(reference).write(to: out.appendingPathComponent("reference.json"))
print("wrote \(reference.count) lines, \(String(format: "%.1f", Double(length) / rate)) s to \(out.path)")
