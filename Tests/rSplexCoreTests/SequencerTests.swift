import Testing
@testable import rSplexCore

let c = SeqStep(degree: 0), f = SeqStep(degree: 3), g = SeqStep(degree: 4)

@Test func recordFillsTheCellAfterTheCursor() {
    var s = Sequencer()
    s.record(c); s.record(g)
    s.moveCursor(-1)                          // between C and G
    #expect(s.record(f) == 1)
    #expect(s.steps[0] == c && s.steps[1] == f && s.steps[2] == nil && s.cursor == 2)   // G replaced, nothing shifts
}

@Test func recordStopsAtTheEnd() {
    var s = Sequencer()
    s.moveCursor(Sequencer.cellCount)
    #expect(s.record(c) == nil && s.playLength == 0)
}

@Test func deleteEmptiesTheCellBeforeTheCursor() {
    var s = Sequencer()
    s.record(c); s.record(f); s.record(g)
    s.moveCursor(-1)                          // between F and G
    s.deleteBeforeCursor()
    #expect(s.steps[0] == c && s.steps[1] == nil && s.steps[2] == g && s.cursor == 1)
    s.deleteBeforeCursor(); s.deleteBeforeCursor()
    #expect(s.steps[0] == nil && s.cursor == 0)   // nothing before the cursor: no-op
}

@Test func playbackLoopsToTheLastFilledCell() {
    var s = Sequencer()
    s.moveCursor(2); s.record(g)
    #expect(s.playLength == 3)                // two rests, then G
}

@Test func cursorStaysWithinTheGaps() {
    var s = Sequencer()
    s.moveCursor(20)
    #expect(s.cursor == Sequencer.cellCount)
    s.moveCursor(-20)
    #expect(s.cursor == 0)
}

@Test func rewriteReplacesWithoutMovingTheCursor() {
    var s = Sequencer()
    let i = s.record(g)!
    s.rewrite(at: i, SeqStep(degree: 0, slash: 4))
    #expect(s.steps[0] == SeqStep(degree: 0, slash: 4) && s.cursor == 1)
}

@Test func stepLengthStopsAtTheEnds() {
    var s = Sequencer()
    s.changeStepLength(-5)
    #expect(s.stepLengthIdx == 0)
    s.changeStepLength(9)
    #expect(s.stepLengthIdx == stepLengths.count - 1)
}

@Test func stepRendersWithLiveSettings() {
    var live = RSplexState(), v = RSplexState()
    live.shiftKey(2)                           // D major
    v.takeSettings(from: live)
    #expect(v.render(step: SeqStep(degree: 0))?.name == "D")
    #expect(v.render(step: SeqStep(degree: 1, mod: 1))?.name == stepName(SeqStep(degree: 1, mod: 1), key: 2, scale: live.scale))
    #expect(v.held.isEmpty && v.mods.isEmpty)  // rendering leaves no keys held
    v.bassMode = 2
    #expect(v.render(step: SeqStep(degree: 0, slash: 4))?.name == "D/A")
}

@Test func scheduledEventsPlayOnTheirBeat() {
    var e = VoiceEngine(sampleRate: sr)       // 120 BPM: 1 beat = 0.5 s
    e.schedule(TimedEvent(1, .noteOn(60, classic, layer: sequencerLayer)))
    e.schedule(TimedEvent(0.5, .noteOn(64, classic)))
    run(&e, seconds: 0.24)
    #expect(e.activeNotes.isEmpty)
    run(&e, seconds: 0.02)
    #expect(e.activeNotes == [64])
    run(&e, seconds: 0.25)
    #expect(e.activeNotes(layer: sequencerLayer) == [60])
}

@Test func layersDontCutEachOtherOff() {
    var e = VoiceEngine(sampleRate: sr)
    e.handle(.noteOn(60, classic))
    e.handle(.noteOn(60, classic, layer: sequencerLayer))
    e.handle(.noteOff(60, layer: sequencerLayer))
    run(&e, seconds: 0.5)
    #expect(e.voice(for: 60)?.stage == .sustain)
    #expect(e.voice(for: 60, layer: sequencerLayer) == nil)
}

@Test func cancelDropsOnlyThatLayer() {
    var e = VoiceEngine(sampleRate: sr)
    e.schedule(TimedEvent(1, .noteOn(60, classic, layer: sequencerLayer)))
    e.schedule(TimedEvent(1, .noteOn(64, classic)))
    e.handle(.cancelScheduled(layer: sequencerLayer))
    #expect(e.scheduledCount == 1)
}
