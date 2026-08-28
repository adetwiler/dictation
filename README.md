# dictation

A push-to-talk dictation app for macOS that **shows you it is listening**.

Tap `fn`. A panel appears on the right edge of the screen with live level bars
and the words as they land. Tap `fn` again. The text is cleaned up and pasted
into whatever you were typing in.

Everything happens on your Mac. No account, no API key, no network call. There
is no server component and nothing to sign up for.

> **Status: this is a personal tool published as-is.** It works well for me every
> day and it has not been tested on anyone else's machine, in any other room, or
> against any other accent. Use at your own risk. See [Known limits](#known-limits).

---

## Read this first if you are on Windows or Linux

**This app is macOS only, and it cannot be ported without replacing its core.**
That is not a packaging gap. It is written in Swift against AppKit, it targets
Apple Silicon on macOS 26, and the speech recognition comes from Apple's own
`SpeechAnalyzer` framework. The transcription model ships with the operating
system, so there is no model file to download and nothing to install on another
platform.

**If you want offline dictation on Windows, go here instead:
[WINDOWS.md](WINDOWS.md).** It is a short setup guide for a different tool that
is genuinely cross-platform, genuinely offline, and also MIT. It will get you a
working hotkey in about ten minutes.

---

## Why the panel is the whole point

The failure this exists to fix is not accuracy. It is:

> "I think it missed that. Did I hit the key at the right time?"

You talk for ninety seconds, stop, and nothing appears, and now you do not know
whether the app was ever listening or whether it ate the take. A toggle plus a
visible panel makes the answer unambiguous: **panel on screen means the
microphone is open.** Nothing else means that.

That is why the panel is not an option you can turn off, why it is drawn as a
non-activating float that never steals focus, and why it renders words as you
speak rather than only at the end.

---

## Requirements

| | |
|---|---|
| macOS | **26.0 or newer** (this is a hard floor, `SpeechAnalyzer` does not exist before it) |
| Chip | **Apple Silicon** (the build targets `arm64`) |
| Xcode | Command line tools, for `swiftc`. No Xcode project, no SwiftPM. |
| Disk | Nothing. The speech model is part of the OS. |

---

## Build and install

```sh
git clone https://github.com/adetwiler/dictation.git
cd dictation
./build.sh
```

`build.sh` compiles, bundles, signs, copies to `/Applications` and launches it.
It is idempotent, so re-run it as often as you like. There is no Xcode project
and no package manifest: the whole thing is one `swiftc` line over one
`main.swift`.

```sh
./test.sh           # the corrector regression suite, 33 cases. Runs anywhere.
./test-delivery.sh  # does a take actually land in the caret? Opens TextEdit, takes
                    # focus for a few seconds. Interactive, needs Accessibility.
```

If you are going to commit to a fork, turn the gates on once:

```sh
bash .githooks/install.sh          # blocks em dashes and private tells per commit
bash scripts/release-check.sh      # the whole-tree version, before you push
```

### Grant two permissions

macOS will ask, and the app shows a card until both are given:

- **System Settings > Privacy & Security > Microphone > Dictation**
- **System Settings > Privacy & Security > Accessibility > Dictation**

Accessibility is what lets it paste. Without it the app still works, it just
puts the text on your clipboard and tells you to press Cmd V yourself.

The app re-checks every 3 seconds, so the card clears itself the moment you
grant. You do not need to relaunch.

### About signing

`build.sh` signs with a real Apple Development identity if it finds one, and
falls back to ad-hoc if it does not. **This matters more than it sounds like it
should.** macOS matches an ad-hoc signed app to its permission grants by
cdhash, so every rebuild changes the hash and silently revokes both grants. If
you see `WARNING: no stable identity found` in the build output, expect to
re-grant after every rebuild. With a stable identity, the grants survive.

---

## Using it

| Action | What happens |
|---|---|
| tap `fn` | Starts listening. Cue plays, panel appears. |
| tap `fn` again | Stops. The text is cleaned and pasted where you were typing. |
| hold `fn` | Push to talk. Release stops it. |
| double tap `fn` | Latches hands-free, so you can ramble with no finger on a key. |
| `Esc` while listening | Cancels. No paste, no clipboard write, no sound. |
| menubar > Start Listening | The fallback that works even if `fn` does not. |

### Where the words land

**The take lands wherever the caret was when you let go of the key.** If there
is no caret to land in, the words go to the clipboard and the panel says
`Copied. Press Cmd V` instead of claiming it pasted.

Two things make that true, and both are worth knowing because the obvious
implementation gets them wrong:

- **The target is captured at RELEASE, not at delivery.** Delivery happens a few
  hundred milliseconds later, once the recognizer's final pass returns. A
  synthetic Cmd V goes to whatever is focused at the moment it is posted, so
  clicking away during that gap used to send the take into a different window.
- **Delivery prefers an accessibility insert over a keystroke.** Setting
  `kAXSelectedText` on the captured element puts the words at that caret, in that
  element, regardless of what is frontmost. The synthetic Cmd V is the fallback
  for apps with no accessibility text support, which in practice means Chromium
  and Electron: Chrome, VS Code, Slack, Discord.

**The clipboard is written first on every path, including the ones that then
succeed.** It costs you your clipboard contents and it buys an absolute
guarantee: no sequence of failures can lose a take. The previous clipboard is
deliberately not restored for the same reason. Not restoring IS the fallback.

### If `fn` does nothing

macOS may be consuming the key before any app sees it. Check
**System Settings > Keyboard > Press fn key to** and set it to **Do Nothing**.
The app detects this and says so on the panel.

---

## Teaching it your words

General speech models have never heard your jargon. Two independent mechanisms
handle that, and they are deliberately different.

**1. Biasing, before recognition.** `Config.terms` at the top of `main.swift` is
a short list handed to the recognizer as context while it listens. It nudges,
it never rewrites, so it cannot damage anything. Keep it short: a shorter bias
list biases better.

**2. Correction, after recognition.** `glossary.json` maps garbles to canonical
forms. Yours goes in:

```
~/Library/Application Support/dictation/glossary.json
```

It is merged on top of the bundled defaults, so an update never clobbers your
words. Quit and relaunch to reload.

```json
{
  "terms": [
    { "correct": "Kubernetes", "garbles": ["cooper netties", "kubernets"] },
    { "correct": "nginx",      "garbles": ["engine x", "engine ex"] }
  ]
}
```

### The one design rule in here worth stealing

**The correction pass is exact-match after squashing case, spaces, hyphens and
apostrophes. It is never fuzzy and never uses edit distance.**

This is the whole safety property, and it is worth understanding before you
"improve" it. A fuzzy corrector with a distance threshold will, sooner or later,
rewrite an ordinary English word into one of your terms in the middle of a real
sentence. That is not a tuning problem. It is what fuzzy matching does.

A measured example from a tool that works the other way: with a surname seeded
in its custom words, *"Can you also build a UI for it"* came out as *"Can you
Alsop build a UI for it"*. The recognizer had heard the sentence perfectly. The
corrector broke it.

`squash("also")` is `"also"` and `squash("alsop")` is `"alsop"`. They never
collide, so that failure is structurally impossible here.

Two rules follow from it, both enforced in code:

- **A one-word term with no garbles is never registered.** That is how you list
  a term that is also an ordinary English word (`Arc`, `Notion`, `Sonnet`)
  without capitalizing every innocent use of it.
- **A garble that is also another term's canonical form is dropped**, so two
  glossary rows written months apart can never fight.

`test.sh` is where this is defended. Half its cases are a fence: ordinary
English that must come back byte for byte unchanged. If you touch the corrector,
run it.

---

## Cleaning up speech

Spoken text is not written text. A separate deterministic pass removes fillers
(`um`, `uh`), doubled words, doubled bigrams and sentence restarts before the
glossary corrector sees anything.

Measured over a real 1,797-take corpus: 196 fillers, 91 doubled words, 57
doubled bigrams, 29 sentence restarts. About one take in five had something.

It is deterministic only. No fuzzy matching, no model call, and the same fence
discipline as the corrector, because *"I know that that is true"* and *"He had
had enough"* are correct English and must survive. Toggle it from the menubar
under **Clean Stutters**; the raw string is kept in the history either way.

---

## What it writes to disk

Everything lives in one folder, so uninstalling is `rm -rf` on one path:

```
~/Library/Application Support/dictation/
  glossary.json     your correction pairs
  history.jsonl     one line per take, append only
  panel.log         panel debug log
  sounds/           optional custom_start.wav / custom_stop.wav
```

`history.jsonl` is append only and uncapped. A transcript is a few hundred bytes
and losing one is annoying, so there is no reason to forget any of them. **The
durable write happens before delivery is attempted**, so a failed paste is
recoverable rather than gone. Read it back with:

```sh
tail -5 "$HOME/Library/Application Support/dictation/history.jsonl"
```

None of it ever leaves the machine. The app makes no network calls of any kind.
Recent takes are also in the menubar under **History**.

---

## Known limits

- **macOS 26, Apple Silicon only.** Not portable. See the note at the top.
- **English (`en-US`) by default.** Change `Config.locale`, but nothing else
  here has been tested in another language.
- **Tested on exactly one machine, one microphone and one voice.** The audio
  meter floor (`-52 dBFS`) was tuned in a quiet home office. If your meter is
  pinned or dead, that constant is the first thing to move.
- **No settings window.** Configuration is `main.swift`, `glossary.json` and the
  menubar. This is a tool for people who are comfortable rebuilding it.
- **A Space-switch workaround ships in here that is not fully understood.** The
  panel was observed being carried off-screen by a three-finger swipe, and four
  attempts to reproduce it failed. There is a watchdog that re-frames the panel
  rather than a fix. It is commented honestly in the source.

---

## Contributing and forking

Fork it, strip it, rename it, ship it. It is MIT and I am not precious about it.

If you are pointing a coding agent at this, read [AGENTS.md](AGENTS.md) first:
it maps the single 2,300-line source file and lists the four invariants that are
load-bearing rather than stylistic.

I am unlikely to be a responsive maintainer. Issues are welcome and may sit.
A fork you own outright is the better outcome for both of us.

---

## License

MIT. See [LICENSE](LICENSE). Do whatever you want with it.
