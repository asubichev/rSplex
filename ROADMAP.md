# Roadmap

Scope rule: every feature is intentional, specified before it's built, tested where it has logic, and played before
it merges. Anything that doesn't feel right gets cut, not shipped. Each feature gets an issue (with what "done" means),
a branch, and a PR. Every merge to `main` publishes a release, so features stay on their branch until they're finished.

Current release: **v1.1** — 7 diatonic chord keys, held number-row modifiers, key/scale/octave (−2…+2), inversions,
voice leading, bass (OFF/ROOT/SLASH), hold-to-lock, per-note voice engine with envelope presets.

## v1.1 — Polish + foundation

The arpeggiator and sequencer need two things the app doesn't have yet: a tempo clock, and notes that start and stop
independently (today the whole chord shares one envelope). This release builds both, plus small fixes.

- **Octave range −2…+2** (was −1…+2).
- **Shift+Tab** cycles scales backwards.
- **Hold-to-lock** (distinct from per-button chord lock, which permanently rebinds a button). See spec below.
- **Engine rewrite:** per-note voices with ADSR. Adds envelope presets (LONG, SHORT, SWELL, PLUCK, TOUCH,
  SUSTAIN) almost for free.
- **Transport:** BPM (40–300) and tap tempo, clocked in the audio thread so timing is sample-accurate.
- Tests for the clock, note on/off scheduling, and the lock state machine.

### Hold-to-lock spec

- Holding a chord key for **4 seconds** locks the chord as currently sounding, including the active number-row
  modifier, bass, and voicing. You can then let go of every key and it keeps playing.
- **Feedback:** while held, the button shows a fill/ring progressing over the 4 s so the lock is predictable; on lock,
  a short (~200 ms) pulse and a lock badge on the button. Unlocking fades the badge.
- **Breaking the lock:** any key press breaks it — chord keys, modifiers, arrows, Tab, V, B, Z, everything.
  - Same chord key: breaks the lock and replays the chord as a normal held chord, so it stops when you release. That
    press does not start a new lock timer.
  - Any other key: breaks the lock *and* does its normal action (another chord key plays that chord, arrows shift key, etc.).
  - Key releases never break the lock.
- **Window loses focus:** the lock survives (it's meant to be hands-free); held, unlocked keys still release as today.
- Later, maybe: let sound-only settings change a locked chord without breaking it. Niche, so not now.

## v1.2 — Sequencer

- Each step stores degree, number-row modifier, and slash bass. Notes are worked out at playback, so key,
  scale, octave, voicing, and bass changes apply to the whole sequence.
- 8 fixed cells (– when empty; cells never shift). The cursor sits between cells. Shift + chord records into the
  cell after the cursor until every chord key is up, following whatever you end on (modifier changes, switching
  chords). Shift+Delete empties the cell before the cursor; Shift+←/→ move the cursor. Playback loops up to the last
  filled cell, with empty cells before it as rests.
- Space play/stop, step length 1/4 to 2 bars (Shift+↑ shorter, Shift+↓ longer), tempo `[` `]` and tap tempo `\`,
  sample-accurate timing.
- Live playing works over a running sequence without cutting its notes.
- Sits top right. No saving: the sequence lives until you quit, by design.

## v1.3 — MIDI out (priority after the sequencer)

Primary use case: driving a **TE OP-1 field over USB-C** (class-compliant USB MIDI, so CoreMIDI output).
- **M** cycles the output: OFF → `rSplex` virtual source (for DAWs) → each connected destination → OFF. An OP-1 is
  picked automatically when connected, until you choose an output yourself. Unplugging the chosen device turns MIDI off.
- Everything that sounds is sent on channel 1, velocity 100: live chords, bass, and the sequencer. Live and sequencer
  notes on the same pitch are counted, so one never cuts the other off.
- Timing: each message is stamped with the host time of its audio sample (plus output latency), so MIDI and audio
  stay aligned and sequencer steps are sample-accurate on the device.
- MIDI clock (24 ppqn) runs continuously at the app's tempo; Start goes out on the sequencer's first step, Stop on
  Space. The OP-1's tempo can follow the app.
- The built-in synth is muted while MIDI is on. Switching outputs or quitting sends note-offs and All Notes Off.
- Still to decide: channel select, velocity, whether the built-in synth can play along, and whether clock should
  only run while the sequencer plays. Verify on a real OP-1 field before merge.

## v1.4 — Sounds

- Sine, triangle, saw, and one natural-sounding instrument (piano-like).

## v1.5 — Effects

- Reverb, BPM-synced delay, and a filter with low-pass and high-pass.

## Tabled: Arpeggiator

Parked to ship the sequencer first; we'll pick it back up later. A working draft is on PR #10 (`v1.2-arp`, not
merged): R mode (ARP / CHORD+ARP), T pattern, Y rate, audio-thread clock, bass held under the arp.
Open problem before it can ship: adding a 7th or 9th changes the cycle length, which breaks the rhythm.

Original scope:
- Patterns: Up, Down, Up/Down, Down/Up, Random, Fingerpick.
- Rates: 1/1, 1/2, 1/4, 1/8 (default), 1/16, 1/16T, 1/32, Swing 8th, Swing 16th — synced to BPM.
- Gate length tied to release time, as on the device.
- Layering: Arp only, Chord + Arp, Rhythm + Arp.
- A locked chord keeps arpeggiating.
- Stretch, only if it feels right: Strum and Repeat modes (small once the clock exists).
- If it ships, the sequencer should be able to play through it.

## Later candidates (pick deliberately, not all)

- Presets: save/load a few slots.
- Chord lock (per-button permanent modifier) and the Extended / Chromatic modifier sets.
- Pentatonic and Blues scales — first decide how to derive 7 chords from 5–6-note scales.
- Stereo spread.

## Out of scope

Looper, vocoder, mic sampling, drum machine and loops, Chord Hiro, Ear Trainer, tuner, companion app, and
hardware-only features (battery, USB modes, firmware).

## Keyboard layout

Taken: `A`–`J` chords, `1`–`0` modifiers, arrows, Tab, `V` `B` `L` `E` `M`, and for the sequencer Space
`[` `]` `\`. Shift is the sequencer modifier: Shift + chord records, Shift + arrows move the cursor and change step
length, Shift+Delete deletes. Prefer Shift keychords over new single keys. The arp draft uses `R` `T` `Y`.
