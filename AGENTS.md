# AGENTS.md

Notes for a coding agent (or a human) working on this repo. Read this before
editing `main.swift`.

Also applies if your tool reads `CLAUDE.md`, `.cursorrules` or similar: this is
the one file, and there is no second copy to keep in sync.

---

## What this is

A macOS menubar app: hold or tap `fn`, speak, the words get cleaned up and
pasted where you were typing. On-device recognition through Apple's
`SpeechAnalyzer`. No network calls anywhere in the codebase.

**Everything is in one file: `main.swift`, about 2,300 lines.** That is
deliberate, not neglect. There is no Xcode project, no `Package.swift` and no
module structure to navigate. `build.sh` is one `swiftc` invocation.

Do not split it into files unless you have a specific reason and are prepared to
rewrite `build.sh` and `test.sh`. `test.sh` in particular works by `awk`-ing
everything above the top-level `NSApplication` line and appending a harness, so
it depends on the single-file layout.

---

## Commands

```sh
./build.sh           # compile, bundle, sign, install to /Applications, launch
./test.sh            # corrector + disfluency suite, 33 cases. Unattended.
./test-delivery.sh   # does a take land in the caret? Opens TextEdit, takes focus.
```

```sh
bash .githooks/install.sh          # once per clone: turns the commit gates on
bash scripts/release-check.sh      # the whole-tree version, run before pushing
```

`build.sh` is idempotent and quits a running copy first.

**THE LEAK GATES ARE NOT OPTIONAL AND THEY ARE NOT DECORATION.** This repo was a
private personal tool for weeks before it was made public, so the risk is not
"someone might paste a secret one day", it is "something is already in here".
`.githooks/pre-commit` blocks a commit whose staged ADDITIONS carry an em dash
or a private tell. `scripts/release-check.sh` scans EVERY TRACKED FILE, which is
the one that catches what landed before the hook existed. It found a real
unreleased product name in `main.swift` the first time it ran.

The denylist lives at `.githooks/denylist.local` and is **gitignored on
purpose**: a list of the things that must never leak is itself a thing that must
never leak. `denylist.example` shows the shape. With no local list the release
check FAILS rather than passing silently, because a leak gate that quietly
no-ops is worse than none: you stop looking.

There is no linter, no formatter and no CI. Those two scripts are the gates and
both are real. **`test-delivery.sh` is interactive**: it opens a real window,
types into it, and reads the text back out, so it cannot run unattended or over
ssh, and it needs Accessibility for whatever terminal you run it from. Run it
after touching `TextTarget` or `Paster`. Nothing else can tell you those work.

---

## Map of `main.swift`

Follow the `// MARK: -` comments. In order:

| Section | What it owns |
|---|---|
| `Config` | Tunables. Bias terms, panel geometry, timings, key codes. **Start here.** |
| `Paths` | Every file the app writes. One directory, changeable in one line. |
| `Glyph` | Lucide icon geometry drawn with `NSBezierPath`. No emoji, no SF Symbols. |
| `Cue` | Optional start/stop sounds. |
| `AudioCapture` | `AVAudioEngine` tap, device selection, input boost, level metering. |
| `Transcribing` / `AppleTranscriber` | **The swap seam.** See below. |
| `TextTarget` | Where the caret was at release. **Has invariants.** |
| `GlossaryCorrector` | Post-recognition proper-noun repair. **Has invariants.** |
| `Paster` | Delivery: accessibility insert, then Cmd V, then the clipboard. |
| `IndicatorState` / `MeterView` / `Indicator` | The panel. |
| `RecState` / `RecordingWatch` | Optional screen-recording indicator. Deletable. |
| `Disfluency` | Filler and stutter removal. **Has invariants.** |
| `History` | Append-only JSONL of every take. |
| `Controller` | The state machine. Hotkey, take lifecycle, delivery. |
| `AppDelegate` | Menubar, menu items, permission cards, launch. |

---

## The five invariants

These are load-bearing. Breaking one produces a bug that is subtle, intermittent
and blamed on the recognizer for weeks. Each has a named reason and a test.

### 1. The corrector is EXACT-MATCH. Never make it fuzzy.

`GlossaryCorrector` matches after squashing case, spaces, hyphens and
apostrophes. No edit distance, no phonetic matching, no similarity threshold.

A fuzzy corrector rewrites ordinary English words into your jargon in the middle
of correct sentences. Measured, in another tool that does it that way: *"Can you
also build a UI for it"* became *"Can you Alsop build a UI for it"*, from a
seeded surname. The recognizer had heard the sentence perfectly.

`squash("also")` and `squash("alsop")` never collide. That is the entire
guarantee, and it is worth more than the extra recall fuzzy matching would buy.

**If someone asks you to make correction "smarter", make the glossary bigger,
not the matcher looser.**

Two rules follow, both already in code, both easy to delete by accident:

- A one-word canonical with **no garbles is never registered as a key**. This is
  how a term that is also an ordinary English word (`Arc`, `Notion`) can be
  listed without capitalizing every innocent use of it.
- The **cross-term fence**: a garble that is another term's canonical form is
  dropped from the merged list. Two glossary rows written months apart cannot
  fight.

### 2. The panel showing means the mic is open. Nothing else may show it.

The product is one promise: **panel on screen means the microphone is open.** If
the panel can appear for any other reason, or fail to appear while listening,
the app stops being proof of anything and there is no point to it.

So: no "hide the overlay" option, no delayed appearance, no animating it in
after recognition warms up. Visibility is decided in exactly one place
(`Indicator.render`), which ORs the dictation state with the optional recording
row so neither can hide the other. Keep it that way.

### 3. Never report a landing you did not verify.

`Paster.Outcome` has two cases and the panel says one of them. It must be true.

The original version of this code wrote the clipboard, posted a synthetic Cmd V
at whatever was frontmost, and returned success unconditionally. Cmd V at an app
with a focused window but no focused text field does nothing, and there is no
error to catch, so the panel said "pasted" while the words went nowhere. Leaving
an app and coming back puts you in that state constantly: the window has focus,
the field does not. That is what "sometimes it just does not land" was.

Three rules hold the fix together:

- **Capture the target at RELEASE** (`Controller.stop`, first line), not at
  delivery. Delivery is a few hundred milliseconds later and focus moves.
- **Prefer the accessibility insert.** It targets an element rather than
  "whatever is frontmost", so it cannot land in the wrong app, and it can be
  verified by reading the caret back.
- **The Cmd V fallback checks that the captured app is still frontmost**, by
  pid, before posting. If focus moved, it refuses and downgrades to the
  clipboard rather than typing into somebody's chat window.

WARNING: **The one failure worse than not inserting is inserting twice.** Two refusals
in `Paster.insert` exist only to prevent it, and they look removable if you do
not know why they are there. `AXComboBox` accepts a `kAXSelectedText` write,
returns success and does nothing, so it is refused outright. An element whose
caret cannot be READ is never written to, because an unverifiable insert cannot
be safely retried with Cmd V afterwards. And when the caret is readable before
the write but not after, that reports SUCCESS rather than falling through: the
text may already be in the field, and pasting on top of a maybe gives you the
sentence twice.

`test-delivery.sh` covers all of this against a real window, including a
no-double-insert assertion and an honesty check that compares what was reported
against what is actually in the field.

### 4. Write to history BEFORE attempting delivery.

In `Controller`, `History.append` runs before the paste is attempted. A paste
can fail (no Accessibility grant, a focus change, an app that swallows Cmd V)
and a synthetic keystroke is not reliably detectable.

Writing first makes every downstream failure recoverable instead of permanent.
Do not reorder this for tidiness.

Corollary: **the previous clipboard is deliberately not restored.** Not
restoring IS the fallback. If the keystroke could not be posted, the text is
already on the clipboard and the panel says so. Restoring throws away the only
copy of what the user just said.

### 5. The disfluency cleaner must not touch correct English.

`Disfluency` removes fillers, doubled words, doubled bigrams and sentence
restarts. Every rule is deterministic. No fuzzy matching, no model call.

*"I know that that is true"*, *"He had had enough"*, *"What it is is a problem"*
and *"It was very very loud"* are all correct English. They are all in
`test.sh` as a fence and they must come back byte for byte unchanged.

The doubled-word rule works from an explicit safe list of function words, not
from a general "if two adjacent words match" test. Widening that list is the
easy way to break this; add a fence case whenever you do.

---

## The swap seam

`protocol Transcribing` is the abstraction over speech recognition.
`AppleTranscriber` is the only implementation today.

**If you are porting this off Apple's model, this is the only thing you replace.**
Everything else in the file, the corrector, the disfluency cleaner, the panel,
the hotkey handling, the history, is platform-neutral logic that does not know
what produced the text.

Six methods: `requiredFormat`, `prepare`, `begin`, `feed`, `end`, `abort`.
`prepare` loads models at launch, never on the keypress.

---

## Things that will surprise you

- **The system-wide accessibility focus query does not work.** Every tutorial
  reaches for `AXUIElementCreateSystemWide` plus `kAXFocusedUIElementAttribute`.
  Measured here against a focused TextEdit document, with Accessibility granted
  and `AXIsProcessTrusted()` returning true, it fails with `-25204`
  (`cannotComplete`) every time and hands back no element. Building an
  `AXUIElementCreateApplication(pid)` for the frontmost app and asking IT for the
  focused element succeeds and returns a settable `AXTextArea`. `TextTarget`
  does the second and keeps the first only as a fallback. `test-delivery.sh`
  fails loudly if this regresses.

- **Ad-hoc signing silently revokes permissions.** macOS matches an app to its
  TCC grants by cdhash when it is ad-hoc signed, so every rebuild changes the
  hash and drops Microphone and Accessibility without saying anything.
  `build.sh` signs with a real Apple Development identity when it finds one and
  prints a loud warning when it does not. If someone reports "it stopped
  hearing me after a rebuild", this is why.

- **The app only reads its TCC grants at launch**, so a recheck timer runs every
  3 seconds to clear the blocked card after the user grants. Without it the card
  sits there forever and trains people to ignore it.

- **`fn` may never reach the app at all.** If
  `com.apple.HIToolbox / AppleFnUsageType` is not 0, macOS consumes the key
  first. The app detects this and says so rather than appearing broken.

- **A Space switch can carry the panel away.** Observed once with `CGWindowList`
  (the panel slid entirely off the left edge at alpha 0.01 during a three-finger
  swipe) and four attempts to reproduce it failed, including one running the
  exact shipped configuration. What ships is a watchdog that re-frames the
  panel, not a fix, because the mechanism is genuinely not understood. Do not
  "clean up" that watchdog without reproducing the original bug first.

- **`NSSound` must be held in a static.** A locally scoped one deallocates at
  the end of the call and the cue cuts off mid-play.

- **`.stationary` is wrong for this panel.** It suits an always-up bar ordered
  in once, not a panel ordered in and out on every take.

- **The panel pins `darkAqua` on purpose.** `.hudWindow` follows the effective
  appearance and blends what is behind it, so over a bright page the panel
  washes out and the white text becomes unreadable.

---

## Style

Match what is there. Specifically:

- **Comments explain WHY, with the measurement.** The comments in this file
  carry numbers, dates and the failure that motivated the code. That is the most
  valuable thing in the repo. Do not strip them to make it look tidier, and if
  you change behavior a comment describes, update the comment in the same edit.
- **Lucide geometry, never emoji and never SF Symbols.** An emoji is drawn by
  the OS, so it is a different picture on every machine and cannot take a color.
- No em dashes.
- Swift standard conventions otherwise.

---

## License

MIT. Fork it, rename it, ship it. See `LICENSE`.
