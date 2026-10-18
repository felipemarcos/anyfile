import Foundation

/// Turns word-level timings from speech recognition into readable subtitle cues and writes SRT, WebVTT or text.
enum Subtitles {
    struct Word: Equatable, Sendable {
        /// May carry leading/trailing spaces as the recognizer produced them.
        var text: String
        var start: Double
        var end: Double
    }

    struct Cue: Equatable {
        var start: Double
        var end: Double
        /// One or two lines.
        var lines: [String]
    }

    /// Broadcast-style limits: ≤ 42 characters per line, ≤ 2 lines, ≤ 6 seconds per cue.
    static let maxLineLength = 42
    static let maxDuration = 6.0

    /// Groups words into cues, breaking at sentence ends, pauses, and the length/duration limits.
    static func cues(from words: [Word]) -> [Cue] {
        var cues: [Cue] = []
        var current: [Word] = []

        func text(_ words: [Word]) -> String {
            words.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        func flush() {
            let joined = text(current)
            if let first = current.first, let last = current.last, !joined.isEmpty {
                cues.append(Cue(start: first.start, end: max(last.end, first.start + 0.5), lines: split(joined)))
            }
            current.removeAll()
        }

        for word in words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let first = current.first, let last = current.last {
                let pause = word.start - last.end
                let tooLong = text(current + [word]).count > maxLineLength * 2
                let tooSlow = word.end - first.start > maxDuration
                let sentenceEnded = last.text.trimmingCharacters(in: .whitespaces).last.map { ".?!…".contains($0) } ?? false
                if pause > 1.0 || tooLong || tooSlow || (sentenceEnded && text(current).count >= 15) {
                    flush()
                }
            }
            current.append(word)
        }
        flush()

        // Never let a cue run into the next one.
        for i in cues.indices.dropLast() where cues[i].end > cues[i + 1].start {
            cues[i].end = cues[i + 1].start
        }
        return cues
    }

    /// Splits text longer than one line at the space closest to the middle.
    static func split(_ text: String) -> [String] {
        guard text.count > maxLineLength else { return [text] }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let spaces = text.indices.filter { text[$0] == " " }
        guard let best = spaces.min(by: {
            abs(text.distance(from: middle, to: $0)) < abs(text.distance(from: middle, to: $1))
        }) else { return [text] }
        return [String(text[..<best]), String(text[text.index(after: best)...])]
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, cue in
            "\(i + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    /// Plain text: one paragraph per run of speech, split at pauses longer than 2 seconds.
    static func plainText(_ words: [Word]) -> String {
        var paragraphs: [[String]] = [[]]
        var previousEnd: Double?
        for word in words {
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let end = previousEnd, word.start - end > 2, !(paragraphs.last?.isEmpty ?? true) { paragraphs.append([]) }
            paragraphs[paragraphs.count - 1].append(trimmed)
            previousEnd = word.end
        }
        return paragraphs.filter { !$0.isEmpty }.map { $0.joined(separator: " ") }.joined(separator: "\n\n") + "\n"
    }

    /// "01:02:03,456" (SRT) or "01:02:03.456" (WebVTT).
    static func timestamp(_ seconds: Double, separator: String) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }
}
