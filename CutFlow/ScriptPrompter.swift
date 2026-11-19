import SwiftUI
import Foundation

// MARK: - Script

/// One person's turn in the script (consecutive lines by the same person are one turn).
struct ScriptTurn: Identifiable, Equatable {
    let id: Int
    let speaker: Int      // 0-based (person 1 = 0)
    let text: String

    var wordCount: Int { text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }
    /// A rough guess at how long it takes to say, for takes with nothing to listen to yet.
    var estimatedSeconds: Double { max(1.2, Double(wordCount) / 2.6) }
}

enum Script {
    static let sample = """
    1: Wait, you cut all your silences by hand?
    2: [shocked face] Every. Single. One.
    1: Bro, CutFlow does that in one tap.
    2: [looks at camera] ...I need this.
    """

    /// Lines look like "1: Hello" (also "P1:", "Person 1 -", "2)"). A line with no number
    /// continues the person before. Text in [brackets] is a reaction direction.
    static func parse(_ text: String, people: Int) -> [ScriptTurn] {
        var turns: [(speaker: Int, text: String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var speaker = turns.last?.speaker ?? 0
            var body = line
            if let match = line.range(of: #"^(?:p(?:erson)?\s*)?([1-9])\s*[:.)\-]\s*"#, options: [.regularExpression, .caseInsensitive]) {
                let prefix = String(line[match])
                if let digit = prefix.first(where: { $0.isNumber }), let n = Int(String(digit)) {
                    speaker = min(max(n - 1, 0), max(people - 1, 0))
                }
                body = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            guard !body.isEmpty else { continue }
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1] = (speaker, last.text + " " + body)
            } else {
                turns.append((speaker, body))
            }
        }
        return turns.enumerated().map { ScriptTurn(id: $0.offset, speaker: $0.element.speaker, text: $0.element.text) }
    }
}

// MARK: - Prompter

struct PrompterState: Equatable {
    enum Mode: Equatable {
        case ready      // not recording yet
        case yourLine   // they're quiet: say your line
        case react      // they're talking: listen & react
        case wait       // pause for someone not filmed yet
        case done
    }
    var mode: Mode
    var line: String
    var next: String?
    var countdown: Double?
}

enum Prompter {
    /// - Parameters:
    ///   - me: the person being filmed (0-based)
    ///   - time: seconds since recording started, nil if not recording
    ///   - otherVoice: when earlier takes are talking (merged), nil if nothing filmed yet
    ///   - filmed: people whose takes already exist
    static func state(turns: [ScriptTurn], me: Int, time: Double?, otherVoice: [ClosedRange<Double>]?, filmed: Set<Int>) -> PrompterState? {
        guard !turns.isEmpty else { return nil }
        let mine = turns.filter { $0.speaker == me }

        guard let t = time else {
            let first = mine.first?.text ?? turns[0].text
            return PrompterState(mode: .ready, line: first, next: mine.dropFirst().first?.text, countdown: nil)
        }

        if let voice = otherVoice, !voice.isEmpty {
            return listening(turns: turns, me: me, t: t, voice: voice, filmed: filmed)
        }
        return estimated(turns: turns, me: me, t: t)
    }

    /// Driven by the real audio of the earlier take(s).
    private static func listening(turns: [ScriptTurn], me: Int, t: Double, voice: [ClosedRange<Double>], filmed: Set<Int>) -> PrompterState {
        // Only turns we can hear (filmed people) or say (me) take part.
        let relevant = turns.filter { $0.speaker == me || filmed.contains($0.speaker) }
        let talkingNow = voice.contains { $0.contains(t) }
        let finished = voice.filter { $0.upperBound <= t }.count

        var othersSeen = 0
        for (i, turn) in relevant.enumerated() {
            let later = relevant[(i + 1)...]
            if turn.speaker != me {
                if othersSeen == finished {
                    if talkingNow {
                        let nextMine = later.first { $0.speaker == me }?.text
                        return PrompterState(mode: .react, line: turn.text, next: nextMine, countdown: nil)
                    }
                    // Quiet, but the script says they speak next
                    if let gap = voice.first(where: { $0.lowerBound > t }) {
                        return PrompterState(mode: .react, line: turn.text, next: later.first { $0.speaker == me }?.text,
                                             countdown: gap.lowerBound - t)
                    }
                }
                othersSeen += 1
            } else if othersSeen == finished && !talkingNow {
                let nextMine = later.first { $0.speaker == me }?.text
                return PrompterState(mode: .yourLine, line: turn.text, next: nextMine, countdown: nil)
            }
        }
        if talkingNow {
            return PrompterState(mode: .react, line: "Keep reacting", next: nil, countdown: nil)
        }
        return PrompterState(mode: .done, line: "That's the script, tap stop", next: nil, countdown: nil)
    }

    /// No earlier take yet: time each turn from its length so you leave room for the others.
    private static func estimated(turns: [ScriptTurn], me: Int, t: Double) -> PrompterState {
        var cursor = 0.4
        for (i, turn) in turns.enumerated() {
            let end = cursor + turn.estimatedSeconds + 0.3
            if t < end {
                let nextMine = turns[(i + 1)...].first { $0.speaker == me }?.text
                if turn.speaker == me {
                    return PrompterState(mode: .yourLine, line: turn.text, next: nextMine, countdown: nil)
                }
                return PrompterState(mode: .wait, line: turn.text, next: nextMine, countdown: end - t)
            }
            cursor = end
        }
        return PrompterState(mode: .done, line: "That's the script, tap stop", next: nil, countdown: nil)
    }
}

// MARK: - Teleprompter card (shown on the camera)

struct PrompterCard: View {
    let state: PrompterState
    let me: Int

    private var chip: (text: String, icon: String, color: Color) {
        switch state.mode {
        case .ready: return ("Press record · your first line", "text.alignleft", RC.blue)
        case .yourLine: return ("Your line", "mic.fill", .green)
        case .react: return ("Listen & react", "ear.fill", RC.blueBright)
        case .wait: return ("Pause, they talk here", "pause.fill", .orange)
        case .done: return ("Done", "checkmark", .green)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: chip.icon)
                Text(chip.text)
                if let c = state.countdown, c > 0.2 {
                    Spacer(minLength: 4)
                    Text(String(format: "%.0fs", c.rounded(.up))).monospacedDigit()
                }
            }
            .font(.caption.weight(.bold))
            .foregroundColor(chip.color)

            Text(state.line)
                .font(.system(size: state.mode == .yourLine || state.mode == .ready ? 20 : 16,
                              weight: state.mode == .yourLine || state.mode == .ready ? .bold : .medium))
                .italic(state.mode == .react || state.mode == .wait)
                .foregroundColor(state.mode == .react || state.mode == .wait ? .white.opacity(0.75) : .white)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)

            if let next = state.next {
                Text("Next: \(next)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(chip.color.opacity(0.7), lineWidth: 1.5))
        .animation(.easeInOut(duration: 0.2), value: state.mode)
    }
}

// MARK: - Script editor

struct ScriptEditorView: View {
    @ObservedObject var split: SplitModel
    @Environment(\.dismiss) private var dismiss

    private let personColors: [Color] = [RC.blueBright, .orange, .green]

    var body: some View {
        ZStack {
            RC.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("Done") { dismiss() }
                        .font(.headline).foregroundColor(RC.blueBright).frame(minHeight: 44)
                    Spacer()
                    Text("Script").font(.title3.bold()).foregroundColor(.white)
                    Spacer()
                    Button("Clear") { split.script = "" }
                        .font(.subheadline).foregroundColor(RC.dim).frame(minHeight: 44)
                }

                Text("Start each line with 1:, 2: or 3: for who says it. Put reactions in [brackets].")
                    .font(.caption).foregroundColor(RC.dim)

                TextEditor(text: $split.script)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 180)
                    .rcCard(radius: 16)

                Text("Preview").font(.headline).foregroundColor(.white)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(split.turns) { turn in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(turn.speaker + 1)")
                                    .font(.caption.weight(.black)).foregroundColor(.black)
                                    .frame(width: 22, height: 22)
                                    .background(personColors[turn.speaker % personColors.count])
                                    .clipShape(Circle())
                                Text(turn.text).font(.subheadline).foregroundColor(.white)
                            }
                        }
                        if split.turns.isEmpty {
                            Text("No lines yet.").font(.subheadline).foregroundColor(RC.dim)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
    }
}
