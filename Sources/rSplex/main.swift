import Cocoa
import AVFoundation
import rSplexCore

let degreeKeys = ["a", "s", "d", "f", "g", "h", "j"]
/// Keys that only change sound, tempo, or the sequencer; pressing them leaves a lock in place.
let lockSafeChars: Set<String> = ["e", "[", "]", "\\"]
let lockSafeKeyCodes: Set<UInt16> = [49]   // Space
let shiftLockSafeKeyCodes: Set<UInt16> = [123, 124, 125, 126, 51]   // Shift + arrows, Shift+Delete
/// Number row 1…0 by key code, so Shift (which turns 1 into !) doesn't change which modifier a key is.
let modKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
let modKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

/// Hosts the VoiceEngine in the audio callback. The UI queues events; the callback drains them at the start of
/// each buffer (a few ms), and anything clocked by the engine itself lands on the exact sample.
final class Synth {
    let engine = AVAudioEngine()
    private let lock = NSLock()
    private var pending: [VoiceEvent] = []
    private var draining: [VoiceEvent] = []
    private var pendingTimed: [TimedEvent] = []
    private var drainingTimed: [TimedEvent] = []
    private var core: VoiceEngine
    private var beatsSnapshot = 0.0

    init() {
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        core = VoiceEngine(sampleRate: sr)
        pending.reserveCapacity(256); draining.reserveCapacity(256)
        pendingTimed.reserveCapacity(256); drainingTimed.reserveCapacity(256)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let src = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frameCount, abl in
            let out = UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self)
            // Swap buffers under the lock so the audio thread never allocates.
            self.lock.lock()
            swap(&self.pending, &self.draining); swap(&self.pendingTimed, &self.drainingTimed)
            self.lock.unlock()
            for e in self.draining { self.core.handle(e) }
            for t in self.drainingTimed { self.core.schedule(t) }
            self.draining.removeAll(keepingCapacity: true)
            self.drainingTimed.removeAll(keepingCapacity: true)
            self.core.render(frames: Int(frameCount), into: out)
            self.lock.lock(); self.beatsSnapshot = self.core.beats; self.lock.unlock()
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)
        do { try engine.start() } catch { print("Audio failed: \(error)") }
    }

    func send(_ events: [VoiceEvent]) {
        guard !events.isEmpty else { return }
        lock.lock(); pending.append(contentsOf: events); lock.unlock()
    }

    /// Queues events to play on exact beats of the engine's clock.
    func schedule(_ events: [TimedEvent]) {
        guard !events.isEmpty else { return }
        lock.lock(); pendingTimed.append(contentsOf: events); lock.unlock()
    }

    var beats: Double { lock.lock(); defer { lock.unlock() }; return beatsSnapshot }
}

final class ChordView: NSView {
    let synth = Synth()
    var state = RSplexState()
    var display = "—"
    var sounding: Set<Int> = []
    var envelopeIdx = 0
    var bpm = 120.0
    var tapTempo = TapTempo()
    var seq = Sequencer()
    var playing = false
    /// Voices the sequence's chords with the live settings but its own voice-leading history.
    var seqVoicer: RSplexState = { var s = RSplexState(); s.lockEnabled = false; return s }()
    var nextStepBeat = 0.0, nextStepIdx = 0
    var seqSounding: Set<Int> = []
    /// Steps scheduled but maybe not reached yet, so the playhead shows what's actually sounding.
    var playheadQueue: [(beat: Double, idx: Int)] = []
    var playhead: Int?
    /// The step being recorded (always the cursor); it follows the held chord (modifier, slash bass), and the cursor
    /// moves on only once every chord key is released.
    var recSlot: Int?
    var shiftHeld = false
    /// How far ahead steps are handed to the audio thread, which then plays them on the exact sample.
    static let lookaheadSeconds = 0.12
    /// Lock animation: when the current lock started (pulse), and the degree/time of the last unlock (badge fade).
    var lockedAt: Double?
    var unlocked: (degree: Int, at: Double)?
    var timer: Timer?
    /// The bundle carries the release version; a plain `swift build` run has none.
    let version = "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    static let pulseSeconds = 0.25, fadeSeconds = 0.3
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    var now: Double { ProcessInfo.processInfo.systemUptime }

    override func viewDidMoveToWindow() {
        guard timer == nil else { return }
        // Drives the lock timer and its animation; idle frames do nothing.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() {
        let t = now
        let animating = lockedAt.map { t - $0 < Self.pulseSeconds } == true
            || unlocked.map { t - $0.at < Self.fadeSeconds } == true
        if state.lockProgress(now: t) != nil || animating { update() }
        if playing { scheduleSteps(); needsDisplay = true }
    }

    func update() {
        let wasLocked = state.lock != nil
        followRecording()
        let out = state.render(now: now)
        display = out?.name ?? "—"
        let next = Set(out?.notes ?? [])
        let (off, on) = chordDiff(from: sounding, to: next)
        let adsr = envelopePresets[envelopeIdx].adsr
        let gain = 3 / Double(max(3, next.count))
        synth.send(off.map { .noteOff($0) } + on.map { .noteOn($0, adsr, gain: gain) })
        if playing { scheduleSteps() }
        sounding = next
        if !wasLocked, state.lock != nil { lockedAt = now }
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        let c = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = e.modifierFlags.contains(.shift)
        let repeatable = [123, 124, 125, 126, 48, 33, 30, 51].contains(e.keyCode)   // arrows, Tab, [ ], Delete
        if e.isARepeat && !repeatable { return }
        // Any key press breaks a lock, except sound, tempo, and sequencer keys; the press then does its normal job.
        let degree = degreeKeys.firstIndex(of: c)
        let lockSafe = lockSafeChars.contains(c) || lockSafeKeyCodes.contains(e.keyCode)
            || (shift && shiftLockSafeKeyCodes.contains(e.keyCode))
        if !lockSafe, let d = state.breakLock(pressingDegree: degree) { unlocked = (d, now); lockedAt = nil }
        switch e.keyCode {
        // Shift + arrows drive the sequencer: ←/→ move the cursor, ↑ shorter steps (faster), ↓ longer.
        case 123: shift ? seq.moveCursor(-1) : state.shiftKey(-1)
        case 124: shift ? seq.moveCursor(1) : state.shiftKey(1)
        case 125: shift ? seq.changeStepLength(1) : state.shiftOctave(-1)
        case 126: shift ? seq.changeStepLength(-1) : state.shiftOctave(1)
        case 48: shift ? state.previousScale() : state.nextScale()
        case 14:       // E envelope preset
            envelopeIdx = (envelopeIdx + 1) % envelopePresets.count
        case 49: playing ? stopSequence() : startSequence()     // Space
        case 51: if shift, recSlot == nil { seq.deleteBeforeCursor() }   // Shift+Delete
        default:
            if let d = degree {
                state.press(degree: d)
                // Shift + chord records; while a recorded chord is held, more chord keys join it (slash bass).
                if shift || recSlot != nil { record(degree: d) }
            }
            else if let m = modKeyCodes.firstIndex(of: e.keyCode) { state.press(mod: m) }
            else if c == "v" { state.voiceLeading.toggle() }
            else if c == "b" { state.cycleBass() }
            else if c == "l" { state.lockEnabled.toggle() }
            else if c == "[" || c == "]" { setBPM(bpm.rounded() + (c == "]" ? 1 : -1)) }
            else if c == "\\" { if let b = tapTempo.tap(at: now) { setBPM(b.rounded()) } }
            else { update(); super.keyDown(with: e); return }
        }
        update()
    }

    override func keyUp(with e: NSEvent) {
        guard let c = e.charactersIgnoringModifiers?.lowercased() else { return }
        if let d = degreeKeys.firstIndex(of: c) { state.release(degree: d); update() }
        else if let m = modKeyCodes.firstIndex(of: e.keyCode) { state.release(mod: m); update() }
    }

    func setBPM(_ b: Double) {
        bpm = min(bpmRange.upperBound, max(bpmRange.lowerBound, b))
        synth.send([.setBPM(bpm)])
    }

    /// Fills the cell after the cursor with the chord being recorded; `followRecording` keeps it up to date.
    func record(degree d: Int) {
        if recSlot == nil { recSlot = seq.record(SeqStep(degree: d, mod: state.mods.last)) }
    }

    /// Keeps the step being recorded equal to what's sounding: switching chords (hold the new one, let go of the
    /// old) or changing the modifier rewrites it, so the step stores whatever you end on, until every chord key
    /// is up. In SLASH bass, two held keys record as a slash chord.
    func followRecording() {
        guard let slot = recSlot else { return }
        guard let d = state.held.last else { recSlot = nil; return }   // released: the step is done
        let slash = state.bassMode == 2 && state.held.count >= 2 ? state.held[0] : nil
        seq.rewrite(at: slot, SeqStep(degree: d, mod: state.mods.last, slash: slash))
    }

    func startSequence() {
        playing = true
        nextStepIdx = 0
        nextStepBeat = synth.beats + 0.02 * bpm / 60
        scheduleSteps()
    }

    func stopSequence() {
        playing = false
        synth.send([.cancelScheduled(layer: sequencerLayer), .releaseLayer(sequencerLayer)])
        seqSounding = []
        playheadQueue = []
        playhead = nil
    }

    /// Hands every step starting within the lookahead window to the audio thread, timed to the beat.
    func scheduleSteps() {
        let now = synth.beats
        while nextStepBeat < now + Self.lookaheadSeconds * bpm / 60 {
            // An empty sequence keeps time in silence, so the first recorded chord lands on the beat.
            nextStepIdx = seq.playLength == 0 ? 0 : nextStepIdx % seq.playLength
            let idx = nextStepIdx
            seqVoicer.takeSettings(from: state)
            let step = seq.steps[idx]
            let notes = Set(step.flatMap { seqVoicer.render(step: $0)?.notes } ?? [])
            let adsr = envelopePresets[envelopeIdx].adsr
            let gain = 3 / Double(max(3, notes.count))
            // Every step re-strikes its chord, so repeated chords still mark the rhythm.
            let events = seqSounding.sorted().map { VoiceEvent.noteOff($0, layer: sequencerLayer) }
                + notes.sorted().map { VoiceEvent.noteOn($0, adsr, gain: gain, layer: sequencerLayer) }
            synth.schedule(events.map { TimedEvent(nextStepBeat, $0) })
            seqSounding = notes
            if seq.playLength > 0 { playheadQueue.append((nextStepBeat, idx)) }
            nextStepBeat += seq.stepBeats
            nextStepIdx = idx + 1
        }
        while playheadQueue.count > 1, playheadQueue[1].beat <= now { playheadQueue.removeFirst() }
        if let first = playheadQueue.first, first.beat <= now { playhead = first.idx }
    }

    /// Releases held keys (e.g. the window lost focus); a lock keeps playing.
    func releaseAll() { state.releaseAll(); shiftHeld = false; update() }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill(); bounds.fill()
        let big: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.white]
        let mid: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.lightGray]
        let s = state, t = now
        display.draw(at: NSPoint(x: 20, y: 12), withAttributes: big)
        if s.lock != nil {
            let x = 24 + display.size(withAttributes: big).width
            drawLockBadge(at: NSPoint(x: x, y: 26), size: 20, alpha: 1)
        }
        drawContext(s)
        let gap: CGFloat = 8
        let w = (bounds.width - 40 - 6 * gap) / 7
        for d in 0..<7 {
            let rect = NSRect(x: 20 + CGFloat(d) * (w + gap), y: 84, width: w, height: 90)
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            let sounding = s.lock?.degree == d || (s.lock == nil && s.held.last == d)
            (sounding ? NSColor.systemOrange : s.held.contains(d) ? NSColor.systemBrown : NSColor(white: 0.25, alpha: 1)).setFill()
            path.fill()
            // Lock timer: the held button fills bottom-up with a lighter tint over the hold time.
            if s.held.last == d, let p = s.lockProgress(now: t), p > 0 {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                NSColor.white.withAlphaComponent(0.28).setFill()
                NSRect(x: rect.minX, y: rect.maxY - rect.height * p, width: rect.width, height: rect.height * p).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            chord(degree: d, key: s.key, scale: s.scale, mod: nil).name
                .draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 12), withAttributes: mid)
            degreeKeys[d].uppercased().draw(at: NSPoint(x: rect.minX + 8, y: rect.maxY - 20), withAttributes: small)
            let badge = NSPoint(x: rect.maxX - 24, y: rect.maxY - 26)
            if s.lock?.degree == d {
                drawLockBadge(at: badge, size: 16, alpha: 1)
                // Lock pulse: an outline that grows and fades right after locking.
                if let at = lockedAt, t - at < Self.pulseSeconds {
                    let k = CGFloat((t - at) / Self.pulseSeconds)
                    let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -10 * k, dy: -10 * k), xRadius: 10 + 10 * k, yRadius: 10 + 10 * k)
                    NSColor.systemOrange.withAlphaComponent(1 - k).setStroke()
                    ring.lineWidth = 3
                    ring.stroke()
                }
            } else if let u = unlocked, u.degree == d, t - u.at < Self.fadeSeconds {
                drawLockBadge(at: badge, size: 16, alpha: 1 - (t - u.at) / Self.fadeSeconds)
            }
        }
        let qw = (bounds.width - 40 - 9 * 6) / 10
        for i in 0..<10 {
            let rect = NSRect(x: 20 + CGFloat(i) * (qw + 6), y: 190, width: qw, height: 50)
            // A locked chord keeps its modifier lit after the key is released.
            let active = s.lock.map { $0.mod == i } ?? (s.mods.last == i)
            (active ? NSColor.systemTeal : NSColor(white: 0.22, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            // Dark text on the lit box, light text on the idle one, so both read clearly.
            let keyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: active ? NSColor(white: 0, alpha: 0.6) : NSColor.lightGray]
            let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: active ? NSColor.black : NSColor.white]
            modKeys[i].draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + 4), withAttributes: keyAttrs)
            modLabels[i].draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + 26), withAttributes: labelAttrs)
        }
        drawSequence()
        drawFooter(s)
    }

    /// Readouts beside what they change: key, scale, and octave under the chord name (with their keys in gray),
    /// transport under the sequencer.
    func drawContext(_ s: RSplexState) {
        let value: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white]
        let keyHint: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.gray]
        let line = NSMutableAttributedString()
        for (text, isValue) in [("← ", false), (noteNames[s.key], true), (" →     ", false),
                                (scales[s.scaleIdx].name, true), (" (⇧)⇥     ", false),
                                ("↓ ", false), ("Oct \(s.octave >= 0 ? "+" : "")\(s.octave)", true), (" ↑", false)] {
            line.append(NSAttributedString(string: text, attributes: isValue ? value : keyHint))
        }
        line.draw(at: NSPoint(x: 22, y: 62))
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.lightGray]
        let rec = NSAttributedString(string: recSlot != nil ? "● REC   " : "",
                                     attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.systemRed])
        let transport = NSMutableAttributedString(attributedString: rec)
        transport.append(NSAttributedString(string: "\(playing ? "▶" : "■")  \(Int(bpm)) BPM   \(stepLengths[seq.stepLengthIdx].name) / step",
                                            attributes: small))
        transport.draw(at: NSPoint(x: bounds.width - 20 - transport.size().width, y: 64))
    }

    /// Bottom line: the toggles as lit/unlit words (underlined letter = key). Holding Shift swaps them for the
    /// sequencer's keys. The version sits at the right either way.
    func drawFooter(_ s: RSplexState) {
        let y: CGFloat = 256
        let lit: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.lightGray]
        let faint: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.gray]
        let versionWidth = version.size(withAttributes: dim).width
        version.draw(at: NSPoint(x: bounds.width - 20 - versionWidth, y: y), withAttributes: dim)
        var x: CGFloat = 20
        if shiftHeld {
            // Same rhythm as the toggles, with the keys in place of the lights.
            for (keys, label) in [("⇧ chord", "record"), ("⇧ ← →", "step"), ("⇧ ↑ ↓", "speed"), ("⇧ ⌫", "clear"),
                                  ("␣", "play"), ("[ ] \\", "tempo")] {
                let item = NSMutableAttributedString(string: keys + " ",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.systemTeal])
                item.append(NSAttributedString(string: label, attributes: lit))
                item.draw(at: NSPoint(x: x, y: y))
                x += item.size().width + 22
            }
            return
        }
        for (word, on) in [("VoiceLead", s.voiceLeading), ("Bass \(bassModes[s.bassMode])", s.bassMode != 0),
                           ("Lock", s.lockEnabled)] {
            let item = NSMutableAttributedString(string: word, attributes: on ? lit : dim)
            item.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 1))
            (on ? NSColor.systemTeal : NSColor(white: 0.3, alpha: 1)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y + 5, width: 7, height: 7)).fill()
            item.draw(at: NSPoint(x: x + 12, y: y))
            x += item.size().width + 34
        }
        // Env shows its shape instead of a light.
        drawEnvelope(envelopePresets[envelopeIdx].adsr, in: NSRect(x: x, y: y + 2, width: 26, height: 12))
        let env = NSMutableAttributedString(string: "Env \(envelopePresets[envelopeIdx].name)", attributes: lit)
        env.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 1))
        env.draw(at: NSPoint(x: x + 32, y: y))
        let hint = "hold ⇧ for sequencer keys"
        hint.draw(at: NSPoint(x: bounds.width - 20 - versionWidth - 24 - hint.size(withAttributes: faint).width, y: y),
                  withAttributes: faint)
    }

    /// The envelope as a line: attack up, decay to sustain, a held stretch, then release. Each stage gets its share
    /// of the width by time (with a fixed hold, and a minimum so even instant stages show).
    func drawEnvelope(_ a: ADSR, in r: NSRect) {
        let parts = [max(0.08, a.attack), max(0.08, a.decay), 0.5, max(0.08, a.release)]
        let total = parts.reduce(0, +)
        let xs = parts.reduce(into: [0.0]) { $0.append($0.last! + $1) }.map { r.minX + r.width * $0 / total }
        let top = r.minY, bottom = r.maxY, sus = bottom - r.height * a.sustain
        let path = NSBezierPath()
        path.move(to: NSPoint(x: xs[0], y: bottom))
        path.line(to: NSPoint(x: xs[1], y: top))
        path.line(to: NSPoint(x: xs[2], y: sus))
        path.line(to: NSPoint(x: xs[3], y: sus))
        path.line(to: NSPoint(x: xs[4], y: bottom))
        NSColor.systemTeal.setStroke()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// Shift shows the sequencer's keys in the footer while it's held.
    override func flagsChanged(with e: NSEvent) {
        let held = e.modifierFlags.contains(.shift)
        if held != shiftHeld { shiftHeld = held; needsDisplay = true }
    }

    /// Top right, above the settings: one cell per step with its chord (– when empty), orange at the playhead.
    /// The cursor is a rounded bar in the gap between cells: gray, red while Shift (sequencer keys) is held or a
    /// step is recording.
    func drawSequence() {
        let gap: CGFloat = 8, w: CGFloat = 49, top: CGFloat = 12, h: CGFloat = 46
        let n = Sequencer.cellCount
        let left = bounds.width - 20 - CGFloat(n) * (w + gap) + gap
        for i in 0..<n {
            let rect = NSRect(x: left + CGFloat(i) * (w + gap), y: top, width: w, height: h)
            let atHead = playhead == i
            (atHead ? NSColor.systemOrange : NSColor(white: 0.22, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            let ink = atHead ? NSColor.black : NSColor.white
            let name = seq.steps[i].map { stepName($0, key: state.key, scale: state.scale) } ?? "–"
            let size: CGFloat = name.count > 5 ? 10 : name.count > 3 ? 12 : 14
            name.draw(at: NSPoint(x: rect.minX + 4, y: rect.minY + 6),
                      withAttributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: ink])
            "\(i + 1)".draw(at: NSPoint(x: rect.minX + 4, y: rect.maxY - 16),
                            withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: ink.withAlphaComponent(0.6)])
        }
        let x = left + CGFloat(seq.cursor) * (w + gap) - gap / 2
        (shiftHeld || recSlot != nil ? NSColor.systemRed : NSColor(white: 0.7, alpha: 1)).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: top + 2, width: 3, height: h - 4), xRadius: 1.5, yRadius: 1.5).fill()
    }

    func drawLockBadge(at p: NSPoint, size: CGFloat, alpha: Double) {
        guard let img = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")?
            .withSymbolConfiguration(.init(pointSize: size, weight: .bold)) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(origin: p, size: img.size), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }
}

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let view = ChordView()
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 280),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "rSplex"
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidResignKey(_ n: Notification) { view.releaseAll() }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
