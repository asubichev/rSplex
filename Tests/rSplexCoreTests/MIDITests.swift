import Testing
@testable import rSplexCore

func messages(_ e: VoiceEngine) -> [MIDIMessage] { e.midi.events.map(\.message).filter { $0 != .clock } }

@Test func umpWordsAreMIDI1ChannelVoiceAndSystem() {
    #expect(MIDIMessage.noteOn(60, velocity: 100).umpWord(channel: 0) == 0x2090_3C64)
    #expect(MIDIMessage.noteOff(60).umpWord(channel: 2) == 0x2082_3C00)
    #expect(MIDIMessage.allNotesOff.umpWord(channel: 0) == 0x20B0_7B00)
    #expect(MIDIMessage.clock.umpWord(channel: 5) == 0x10F8_0000)
    #expect(MIDIMessage.start.umpWord(channel: 0) == 0x10FA_0000)
}

@Test func nothingIsSentWhileMIDIIsOff() {
    var e = VoiceEngine(sampleRate: sr)
    e.handle(.noteOn(60, classic))
    run(&e, seconds: 0.1)
    #expect(e.midi.events.isEmpty)
}

@Test func notesAreMirrored() {
    var e = VoiceEngine(sampleRate: sr)
    e.handle(.setMIDI(true))
    e.handle(.noteOn(60, classic))
    e.handle(.noteOff(60))
    #expect(messages(e) == [.noteOn(60, velocity: MIDITap.velocity), .noteOff(60)])
}

@Test func samePitchOnTwoLayersOnlyStopsWhenBothDo() {
    var e = VoiceEngine(sampleRate: sr)
    e.handle(.setMIDI(true))
    e.handle(.noteOn(60, classic))
    e.handle(.noteOn(60, classic, layer: sequencerLayer))
    e.handle(.noteOff(60, layer: sequencerLayer))
    #expect(!messages(e).contains(.noteOff(60)))
    e.handle(.noteOff(60))
    #expect(messages(e).last == .noteOff(60))
}

@Test func releasingALayerAndTurningMIDIOffSendNoteOffs() {
    var e = VoiceEngine(sampleRate: sr)
    e.handle(.setMIDI(true))
    e.handle(.noteOn(60, classic, layer: sequencerLayer))
    e.handle(.noteOn(64, classic))
    e.handle(.releaseLayer(sequencerLayer))
    #expect(messages(e).last == .noteOff(60))
    e.handle(.setMIDI(false))
    #expect(Array(messages(e).suffix(2)) == [.noteOff(64), .allNotesOff])
}

@Test func scheduledNotesCarryTheirFrame() {
    var e = VoiceEngine(sampleRate: sr)       // 120 BPM: beat 0.01 = 0.005 s = 240 frames
    e.handle(.setMIDI(true))
    e.schedule(TimedEvent(0.01, .noteOn(60, classic)))
    run(&e, seconds: 0.01)
    let on = e.midi.events.first { $0.message == .noteOn(60, velocity: MIDITap.velocity) }
    #expect(on?.frame == 240)
}

@Test func clockIs24PerBeatAndStartReanchorsIt() {
    var e = VoiceEngine(sampleRate: sr)
    e.handle(.setMIDI(true))
    run(&e, seconds: 1)                       // 2 beats at 120 BPM
    let clocks = e.midi.events.filter { $0.message == .clock }
    #expect(clocks.count == 48 || clocks.count == 49)
    e.midi.clear()
    run(&e, seconds: 0.003)                   // off the clock grid
    e.handle(.midiStart)
    e.midi.clear()
    run(&e, seconds: 0.001)
    #expect(e.midi.events.first?.message == .clock && e.midi.events.first?.frame == 0)   // pulse right after Start
}

@Test func transportStartAndStop() {
    var e = VoiceEngine(sampleRate: sr)
    e.handle(.setMIDI(true))
    e.schedule(TimedEvent(0.01, .midiStart))
    run(&e, seconds: 0.01)
    e.handle(.midiStop)
    #expect(messages(e) == [.start, .stop])
}

@Test func stoppingBeforeStartCancelsIt() {
    var e = VoiceEngine(sampleRate: sr)
    e.handle(.setMIDI(true))
    e.schedule(TimedEvent(1, .midiStart))
    e.handle(.cancelScheduled(layer: sequencerLayer))
    run(&e, seconds: 1)
    #expect(messages(e).isEmpty)
}
