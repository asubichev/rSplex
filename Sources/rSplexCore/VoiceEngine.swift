import Foundation

/// Envelope times in seconds; sustain is a level 0…1.
public struct ADSR: Equatable {
    public var attack, decay, sustain, release: Double
    public init(_ attack: Double, _ decay: Double, _ sustain: Double, _ release: Double) {
        self.attack = attack; self.decay = decay; self.sustain = sustain; self.release = release
    }
}

/// CLASSIC is the original rSplex envelope; SWELL fades in and rings out; SHORT is a tight stab.
public let envelopePresets: [(name: String, adsr: ADSR)] = [
    ("CLASSIC", ADSR(0.005, 0, 1, 0.3)),
    ("SWELL", ADSR(0.8, 0.3, 0.8, 2.0)),
    ("SHORT", ADSR(0.1, 0.1, 1.0, 0.12)),
]

public let bpmRange = 40.0...300.0

public enum VoiceEvent: Equatable {
    /// Note, envelope, and gain (1 = a note in a triad; bigger chords pass 3/n to keep the original loudness).
    /// `layer` keeps sources apart: a note only reuses or releases voices on its own layer, so the sequencer and
    /// live playing can sound the same pitch without cutting each other off.
    case noteOn(Int, ADSR, gain: Double = 1, layer: Int = 0)
    case noteOff(Int, layer: Int = 0)
    case allNotesOff
    /// Releases every note on one layer.
    case releaseLayer(Int)
    case setBPM(Double)
    /// Drops this layer's scheduled events that haven't played yet (for the sequencer, a pending MIDI Start too).
    case cancelScheduled(layer: Int)
    /// Turns MIDI mirroring on or off; turning it off sends note-offs for anything sounding.
    case setMIDI(Bool)
    /// MIDI transport, scheduled with the sequencer so Start lands on its first step.
    case midiStart, midiStop
    /// Silences the built-in synth (voices keep running, so MIDI and timing are unaffected).
    case setMuted(Bool)
}

/// Live playing is layer 0; the sequencer plays on its own layer.
public let liveLayer = 0, sequencerLayer = 1

/// An event to play when the beat clock reaches `beat`.
public struct TimedEvent: Equatable {
    public var beat: Double
    public var event: VoiceEvent
    public init(_ beat: Double, _ event: VoiceEvent) { self.beat = beat; self.event = event }
}

/// Notes to stop and start to go from one set of sounding notes to another; shared notes keep ringing.
public func chordDiff(from old: Set<Int>, to new: Set<Int>) -> (off: [Int], on: [Int]) {
    (old.subtracting(new).sorted(), new.subtracting(old).sorted())
}

public func midiToHz(_ n: Int) -> Double { 440 * pow(2, Double(n - 69) / 12) }

/// Polyphonic synth: a fixed pool of voices, each with its own envelope, plus a beat clock.
/// Single-threaded and allocation-free while rendering, so it runs inside the audio callback.
public struct VoiceEngine {
    public enum Stage { case idle, attack, decay, sustain, release }

    public struct Voice {
        public var note = 0
        public var layer = 0
        public var stage = Stage.idle
        public var level = 0.0
        var adsr = envelopePresets[0].adsr
        var gain = 1.0
        var releaseFrom = 0.0
        var phases = (0.0, 0.0)
        var freq = 0.0
        var startedAt: Int64 = 0
    }

    /// Per-voice gain: a triad sums to the original engine's loudness.
    public static let voiceGain = 0.35 / 3

    public let sampleRate: Double
    public private(set) var voices: [Voice]
    public private(set) var bpm = 120.0
    /// Beats elapsed since the engine started, integrated sample by sample so tempo changes stay in phase.
    public private(set) var beats = 0.0
    public private(set) var sampleTime: Int64 = 0
    private var lp = 0.0
    public private(set) var muted = false
    /// MIDI mirror of everything played, stamped with the frame in the current buffer. Read and clear after render.
    public var midi = MIDITap()
    /// Frame within the buffer being rendered, so events handled mid-buffer get the right MIDI timestamp.
    private var frame = 0
    /// Pending timed events, sorted by beat. Preallocated so scheduling never allocates on the audio thread.
    public static let scheduleCapacity = 1024
    private var scheduled: [TimedEvent] = []
    public var scheduledCount: Int { scheduled.count }

    public init(sampleRate: Double, voiceCount: Int = 16) {
        self.sampleRate = sampleRate
        voices = Array(repeating: Voice(), count: voiceCount)
        scheduled.reserveCapacity(Self.scheduleCapacity)
    }

    public var activeNotes: [Int] { voices.filter { $0.stage != .idle }.map(\.note).sorted() }
    public func voice(for note: Int, layer: Int = 0) -> Voice? {
        voices.first { $0.stage != .idle && $0.note == note && $0.layer == layer }
    }
    public func activeNotes(layer: Int) -> [Int] {
        voices.filter { $0.stage != .idle && $0.layer == layer }.map(\.note).sorted()
    }

    /// Queues an event for a beat; one already due plays on the next sample. Dropped when the queue is full.
    public mutating func schedule(_ t: TimedEvent) {
        guard scheduled.count < Self.scheduleCapacity else { return }
        // Insert after any event at the same beat, so events keep the order they were sent in.
        var i = scheduled.count
        while i > 0, scheduled[i - 1].beat > t.beat { i -= 1 }
        scheduled.insert(t, at: i)
    }

    public mutating func handle(_ e: VoiceEvent) {
        switch e {
        case .noteOn(let n, let adsr, let gain, let layer):
            noteOn(n, adsr, gain, layer)
            midi.noteOn(n, layer: layer, at: frame)
        case .noteOff(let n, let layer):
            midi.noteOff(n, layer: layer, at: frame)
            for i in voices.indices where voices[i].note == n && voices[i].layer == layer
                && voices[i].stage != .idle && voices[i].stage != .release {
                startRelease(i)
            }
        case .allNotesOff:
            midi.allNotesOff(at: frame)
            for i in voices.indices where voices[i].stage != .idle && voices[i].stage != .release { startRelease(i) }
        case .releaseLayer(let l):
            midi.releaseLayer(l, at: frame)
            for i in voices.indices where voices[i].layer == l && voices[i].stage != .idle && voices[i].stage != .release {
                startRelease(i)
            }
        case .setBPM(let b): bpm = min(bpmRange.upperBound, max(bpmRange.lowerBound, b))
        case .cancelScheduled(let layer):
            scheduled.removeAll { e in
                switch e.event {
                case .noteOn(_, _, _, let l), .noteOff(_, let l): l == layer
                case .midiStart: layer == sequencerLayer
                default: false
                }
            }
        case .setMIDI(let on):
            if !on, midi.enabled { midi.allNotesOff(at: frame) }
            if on, !midi.enabled { midi.reset() }
            midi.enabled = on
        case .midiStart: midi.start(beats: beats, at: frame)
        case .midiStop: midi.emit(.stop, at: frame)
        case .setMuted(let m): muted = m
        }
    }

    private mutating func startRelease(_ i: Int) {
        voices[i].releaseFrom = voices[i].level
        voices[i].stage = .release
    }

    private mutating func noteOn(_ n: Int, _ adsr: ADSR, _ gain: Double, _ layer: Int) {
        // Reuse this note's voice if it's still ringing, else a free one, else steal: quietest releasing, then oldest.
        let i = voices.firstIndex { $0.stage != .idle && $0.note == n && $0.layer == layer }
            ?? voices.firstIndex { $0.stage == .idle }
            ?? stealIndex()
        if voices[i].stage == .idle || voices[i].note != n || voices[i].layer != layer {
            voices[i].phases = (0, 0); voices[i].level = 0
        }
        voices[i].note = n
        voices[i].layer = layer
        voices[i].freq = midiToHz(n)
        voices[i].adsr = adsr
        voices[i].gain = gain
        voices[i].stage = .attack   // from the current level, so a retrigger or steal doesn't click
        voices[i].startedAt = sampleTime
    }

    private func stealIndex() -> Int {
        var quietest: Int?, oldest = 0
        for i in voices.indices {
            if voices[i].stage == .release, quietest.map({ voices[i].level < voices[$0].level }) ?? true { quietest = i }
            if voices[i].startedAt < voices[oldest].startedAt { oldest = i }
        }
        return quietest ?? oldest
    }

    private mutating func advanceEnvelope(_ i: Int) {
        let sr = sampleRate
        var v = voices[i]
        switch v.stage {
        case .idle: break
        case .attack:
            v.level = v.adsr.attack > 0 ? v.level + 1 / (v.adsr.attack * sr) : 1
            if v.level >= 1 { v.level = 1; v.stage = .decay }
        case .decay:
            v.level = v.adsr.decay > 0 ? v.level - (1 - v.adsr.sustain) / (v.adsr.decay * sr) : v.adsr.sustain
            if v.level <= v.adsr.sustain { v.level = v.adsr.sustain; v.stage = v.adsr.sustain > 0 ? .sustain : .idle }
        case .sustain:
            v.level = v.adsr.sustain
        case .release:
            v.level = v.adsr.release > 0 ? v.level - v.releaseFrom / (v.adsr.release * sr) : 0
            if v.level <= 0 { v.level = 0; v.stage = .idle }
        }
        voices[i] = v
    }

    /// Renders `frames` mono samples into `out`.
    public mutating func render(frames: Int, into out: UnsafeMutablePointer<Float>) {
        let sr = sampleRate
        for f in 0..<frames {
            frame = f
            while let first = scheduled.first, first.beat <= beats { scheduled.removeFirst(); handle(first.event) }
            var s = 0.0
            for i in voices.indices where voices[i].stage != .idle {
                advanceEnvelope(i)
                let v = voices[i]
                // Each note is a saw/sine blend plus a slightly detuned partner.
                var (p0, p1) = v.phases
                p0 += v.freq * 0.9985 / sr; if p0 >= 1 { p0 -= 1 }
                p1 += v.freq * 1.0015 / sr; if p1 >= 1 { p1 -= 1 }
                voices[i].phases = (p0, p1)
                let osc = 0.25 * (2 * p0 - 1) + 0.25 * sin(2 * .pi * p0) + 0.25 * (2 * p1 - 1) + 0.25 * sin(2 * .pi * p1)
                s += osc * v.level * v.gain * Self.voiceGain
            }
            lp += 0.2 * (s - lp)
            out[f] = muted ? 0 : Float(Self.softClip(lp))
            midi.tickClock(beats: beats, at: f)
            beats += bpm / 60 / sr
            sampleTime += 1
        }
        frame = 0   // events handled between buffers belong to the start of the next one
    }

    /// Unchanged below 0.8; above, eases toward 1 so big chords can't clip.
    public static func softClip(_ x: Double) -> Double {
        let a = abs(x)
        return a <= 0.8 ? x : (x < 0 ? -1 : 1) * (0.8 + 0.2 * tanh((a - 0.8) / 0.2))
    }
}

/// Tap tempo: three or more taps set the BPM from the average of the last few intervals.
public struct TapTempo {
    public static let resetGap = 2.0
    private var taps: [Double] = []
    public init() {}

    /// Returns the new BPM once there are enough taps.
    public mutating func tap(at t: Double) -> Double? {
        if let last = taps.last, t - last > Self.resetGap { taps.removeAll() }
        taps.append(t)
        if taps.count > 5 { taps.removeFirst() }
        guard taps.count >= 3 else { return nil }
        let interval = (taps.last! - taps.first!) / Double(taps.count - 1)
        return min(bpmRange.upperBound, max(bpmRange.lowerBound, 60 / interval))
    }
}
