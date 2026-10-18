import Foundation

/// A MIDI 1.0 message the engine wants sent; the app turns these into CoreMIDI packets.
public enum MIDIMessage: Equatable {
    case noteOn(UInt8, velocity: UInt8)
    case noteOff(UInt8)
    case clock, start, stop
    /// CC 123 on the channel: anything still sounding stops.
    case allNotesOff

    /// The message as a MIDI 1.0 Universal MIDI Packet word (group 0) on `channel` (0…15).
    public func umpWord(channel: UInt8) -> UInt32 {
        let ch = UInt32(channel & 0x0F)
        func voice(_ status: UInt32, _ d1: UInt8, _ d2: UInt8) -> UInt32 {
            0x2000_0000 | (status | ch) << 16 | UInt32(d1 & 0x7F) << 8 | UInt32(d2 & 0x7F)
        }
        func system(_ status: UInt32) -> UInt32 { 0x1000_0000 | status << 16 }
        switch self {
        case .noteOn(let n, let v): return voice(0x90, n, v)
        case .noteOff(let n): return voice(0x80, n, 0)
        case .allNotesOff: return voice(0xB0, 123, 0)
        case .clock: return system(0xF8)
        case .start: return system(0xFA)
        case .stop: return system(0xFC)
        }
    }
}

/// A message stamped with the sample frame (within the current render buffer) it belongs to.
public struct MIDIEvent: Equatable {
    public var frame: Int
    public var message: MIDIMessage
}

/// Mirrors the engine's notes as MIDI. Live and sequencer layers share one channel, so notes are counted per
/// layer: a pitch sounding on both layers only gets its note-off when the last one stops. Preallocated, so it
/// runs on the audio thread.
public struct MIDITap {
    public static let layers = 4, capacity = 1024, clocksPerBeat = 24.0
    public static let velocity: UInt8 = 100

    public var enabled = false
    public private(set) var events: [MIDIEvent] = []
    private var counts = [Int](repeating: 0, count: layers * 128)
    private var total = [Int](repeating: 0, count: 128)
    /// Next beat to send a clock pulse on; nil before the first pulse.
    var nextClockBeat: Double?

    public init() { events.reserveCapacity(Self.capacity) }

    public mutating func clear() { events.removeAll(keepingCapacity: true) }

    /// Back to nothing sounding and no clock phase, in place (no allocation).
    mutating func reset() {
        clear()
        for i in counts.indices { counts[i] = 0 }
        for n in 0..<128 { total[n] = 0 }
        nextClockBeat = nil
    }

    mutating func emit(_ m: MIDIMessage, at frame: Int) {
        guard enabled, events.count < Self.capacity else { return }
        events.append(MIDIEvent(frame: frame, message: m))
    }

    mutating func noteOn(_ n: Int, layer: Int, at frame: Int) {
        guard enabled, (0..<128).contains(n), (0..<Self.layers).contains(layer) else { return }
        counts[layer * 128 + n] += 1
        total[n] += 1
        emit(.noteOn(UInt8(n), velocity: Self.velocity), at: frame)
    }

    mutating func noteOff(_ n: Int, layer: Int, at frame: Int) {
        guard enabled, (0..<128).contains(n), (0..<Self.layers).contains(layer), counts[layer * 128 + n] > 0 else { return }
        counts[layer * 128 + n] -= 1
        total[n] -= 1
        if total[n] == 0 { emit(.noteOff(UInt8(n)), at: frame) }
    }

    mutating func releaseLayer(_ layer: Int, at frame: Int) {
        guard (0..<Self.layers).contains(layer) else { return }
        for n in 0..<128 { while counts[layer * 128 + n] > 0 { noteOff(n, layer: layer, at: frame) } }
    }

    /// Note-offs for everything sounding, then CC 123 for good measure; counts reset.
    mutating func allNotesOff(at frame: Int) {
        for n in 0..<128 where total[n] > 0 { emit(.noteOff(UInt8(n)), at: frame) }
        for i in counts.indices { counts[i] = 0 }
        for n in 0..<128 { total[n] = 0 }
        emit(.allNotesOff, at: frame)
    }

    /// Called every sample with the beat clock: sends 24 pulses per beat.
    mutating func tickClock(beats: Double, at frame: Int) {
        guard enabled else { return }
        let next = nextClockBeat ?? (beats * Self.clocksPerBeat).rounded(.up) / Self.clocksPerBeat
        if beats >= next {
            emit(.clock, at: frame)
            nextClockBeat = next + 1 / Self.clocksPerBeat
        } else {
            nextClockBeat = next
        }
    }

    /// MIDI Start, with the clock re-anchored so the first pulse after it lands on the same sample.
    mutating func start(beats: Double, at frame: Int) {
        emit(.start, at: frame)
        nextClockBeat = beats
    }
}
