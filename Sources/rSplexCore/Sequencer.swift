import Foundation

/// One sequencer step: a chord as it was played (degree, held modifier, slash-bass degree). The notes are worked
/// out at playback, so changing key, scale, octave, voicing, or bass mode changes the whole sequence.
public struct SeqStep: Equatable {
    public var degree: Int
    public var mod: Int?
    /// Bass degree for a slash chord (SLASH bass with two chord keys held), else nil.
    public var slash: Int?
    public init(degree: Int, mod: Int? = nil, slash: Int? = nil) { self.degree = degree; self.mod = mod; self.slash = slash }
}

/// How long each step lasts, in beats.
public let stepLengths: [(name: String, beats: Double)] = [("1/4", 1), ("1/2", 2), ("1 BAR", 4), ("2 BARS", 8)]

/// The pattern and its editing cursor. Eight fixed cells (nil = empty); cells never shift. The cursor sits in
/// the gaps (0…8): recording fills the cell after it and moves past, delete empties the cell before it and moves back.
public struct Sequencer: Equatable {
    public static let cellCount = 8
    public private(set) var steps: [SeqStep?] = Array(repeating: nil, count: cellCount)
    /// Gap position: 0 is before the first cell, `cellCount` after the last.
    public private(set) var cursor = 0
    public var stepLengthIdx = 2

    public init() {}

    public var stepBeats: Double { stepLengths[stepLengthIdx].beats }
    /// Playback loops through the cells up to the last filled one; empty cells before it are rests.
    public var playLength: Int { (steps.lastIndex { $0 != nil } ?? -1) + 1 }

    /// Fills the cell after the cursor and moves past it. Returns the cell, or nil with the cursor at the end.
    @discardableResult
    public mutating func record(_ step: SeqStep) -> Int? {
        guard cursor < Self.cellCount else { return nil }
        steps[cursor] = step
        cursor += 1
        return cursor - 1
    }

    /// Replaces a cell without moving the cursor, e.g. as the chord being recorded changes while it's held.
    public mutating func rewrite(at i: Int, _ step: SeqStep) {
        guard steps.indices.contains(i) else { return }
        steps[i] = step
    }

    /// Empties the cell before the cursor and moves back over it, like Backspace without the shifting.
    public mutating func deleteBeforeCursor() {
        guard cursor > 0 else { return }
        cursor -= 1
        steps[cursor] = nil
    }

    public mutating func moveCursor(_ delta: Int) { cursor = min(Self.cellCount, max(0, cursor + delta)) }

    /// Moves through `stepLengths` (shorter → longer), stopping at either end.
    public mutating func changeStepLength(_ delta: Int) {
        stepLengthIdx = min(stepLengths.count - 1, max(0, stepLengthIdx + delta))
    }
}

extension RSplexState {
    /// Notes for a stored step, voiced with the current settings. Use a dedicated state for playback so voice
    /// leading follows the sequence, not live playing.
    public mutating func render(step: SeqStep) -> Output? {
        releaseAll()
        if let b = step.slash { press(degree: b) }
        press(degree: step.degree)
        if let m = step.mod { press(mod: m) }
        defer { releaseAll() }
        return renderHeld()
    }

    /// Copies the sound settings (key, scale, octave, voicing, bass) from another state, keeping this one's voicing history.
    public mutating func takeSettings(from s: RSplexState) {
        key = s.key; scaleIdx = s.scaleIdx; inversion = s.inversion; bassMode = s.bassMode; voiceLeading = s.voiceLeading
        shiftOctave(s.octave - octave)
    }
}

/// The display name for a step, e.g. "Am7" or "F/C".
public func stepName(_ step: SeqStep, key: Int, scale: [Int]) -> String {
    let name = chord(degree: step.degree, key: key, scale: scale, mod: step.mod).name
    return step.slash.map { name + "/" + noteNames[(key + scale[$0]) % 12] } ?? name
}
