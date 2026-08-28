# Offline dictation on Windows 11

**This repo's app will not run on Windows.** It is Swift, AppKit and Apple's own
speech framework, so there is no model file to hand you and nothing to port. If
someone sent you here for "the offline dictation thing", this page is the real
answer.

Use **[Handy](https://github.com/cjpais/Handy)**. It is a different project by a
different author (Chris Pais). It is MIT, it runs on Windows, macOS and Linux,
and transcription happens entirely on your machine with no account and no
network call. I ran it before writing my own, and I only wrote my own because I
wanted a specific on-screen indicator, not because Handy was doing anything
wrong.

Budget about ten minutes, most of which is a model download.

---

## 1. Install it

Download the Windows installer from the
[releases page](https://github.com/cjpais/Handy/releases) and run it.

- Latest at the time of writing: **v0.9.6**, released 2026-08-24
- Most machines want **`Handy_<version>_x64-setup.exe`**
- On an Arm laptop (Snapdragon X, Surface Pro 11) take the **`arm64`** one
  instead

There is also `winget install cjpais.Handy`, but that package is community
maintained rather than official, so it can lag. The installer is the safer path.

Windows SmartScreen may warn on first run. That is the usual unsigned-installer
warning, not a verdict about the software.

---

## 2. Pick the model

Open Handy, go to the model settings, and download **Parakeet V3**.

| | |
|---|---|
| Download | about 478 MB, once |
| Runs on | **CPU only**, no GPU needed |
| Languages | 25 European languages, auto-detected |
| Accuracy | high, and noticeably fewer hallucinations than Whisper on short takes |

**Parakeet V3 is the right default and it is not close.** It runs on plain CPU,
so it does not care what graphics card you have, and on short dictation takes it
is both faster and cleaner than Whisper. On my Mac it streamed at roughly ten
times real time, meaning a 16-second take was already transcribed by the moment
I let go of the key.

**Two quirks nobody warns you about, both real:**

1. **Numbers come out as words.** You say "twenty three", you get "twenty
   three", not "23". There is no setting for this.
2. **Language is auto-detected and cannot be forced.** If you switch languages
   mid-sentence it will follow you, which is sometimes what you want and
   sometimes not.

If either of those is a dealbreaker, take **Whisper Turbo** instead. It is
larger and slower, but it writes digits and lets you pin a language. On Windows
it can use your GPU through Vulkan; Parakeet cannot yet.

For a machine that is genuinely short on resources, **Moonshine Small** is about
100 MB, English only, and very fast.

---

## 3. Set your hotkey

Set the push-to-talk binding in Handy's settings to whatever your hands already
expect. Two things worth knowing before you pick:

- **Avoid a key Windows already owns.** Anything with the Windows key, and
  `Ctrl+Shift+<letter>` combinations your IDE has claimed, will fight you.
- **Prefer hold-to-talk over toggle at first.** Toggle is better once you trust
  the tool, but while you are still learning whether it heard you, holding a key
  means the state is never ambiguous.

WARNING: **Do not remove whatever dictation you are using today until this one has
worked for a full day.** I rebound a key to an unproven setup once and left
myself with no working dictation at all for fifteen minutes, in the middle of a
conversation. Run them side by side for a day. Switch when you have watched the
new one fail and seen that you can live with how it fails.

---

## 4. Teach it your jargon

Handy has a **custom words** list. Put your product names, project code names
and surnames in it. A general speech model has never heard them, and this is
the single biggest accuracy win available to you.

IMPORTANT: **Read this before you add a name to that list.** Handy's corrector is a
**fuzzy** multi-token replace, not an exact match. It will rewrite ordinary
English words that merely sound close to your terms, in the middle of correct
sentences, and the recognizer will have been innocent.

Two things this actually did to me within three minutes of seeding a list:

- A seeded surname turned *"Can you **also** build a UI for it"* into
  *"Can you **Alsop** build a UI for it"*.
- A seeded product name whose spoken form was two ordinary words ate the verb
  out of a sentence, across a word boundary, and produced something
  ungrammatical rather than merely wrong.

**So screen every term before you add it, and screen it in the direction people
forget.** The obvious test is "do this term's garbles look like real English?"
That is the wrong question. The question that decides it is the reverse:

> **Does any ordinary, high-frequency English word sit inside this term's fuzzy
> or phonetic neighborhood?**

If yes, leave the term out. A term you have to correct by hand occasionally is
much cheaper than a corrector that quietly damages sentences you already said
correctly.

**Specifically, never add a term that is one small edit away from a common word.**
Say the term out loud, then say the nearest common word out loud. If you can
imagine confusing them at speed, it does not go in the list.

If you find yourself needing more control than that, `word_correction_threshold`
in Handy's settings governs how aggressive the matching is. Lower is stricter.

---

## 5. Sanity check it before you rely on it

Do this once, deliberately, before you throw away your old setup. It takes two
minutes and it is the difference between finding a problem now and finding it in
front of someone.

1. **Dictate one paragraph containing your five worst words.** Not a test
   sentence. A real paragraph you would actually send. Read the output.
2. **Dictate a trap sentence**, one that uses ordinary English words which sit
   near your custom terms. If the corrector damages it, remove the term that did
   it. This is the failure that will otherwise find you at a bad moment.
3. **Time the round trip.** Talk, release, and watch how long until text
   appears. If local transcription is slower than you can tolerate, try
   Moonshine before you conclude offline dictation is not for you.

---

## What you give up versus a cloud tool

Being honest about this, because the trade is real and you should make it with
your eyes open:

| | Local (Handy) | Cloud (Wispr Flow and similar) |
|---|---|---|
| Your audio | never leaves the machine | uploaded and decrypted server-side, always |
| Works offline | yes | no |
| Cost | free | subscription |
| Raw accuracy on hard audio | good | usually better |
| Context awareness | none | rewrites for tone, knows what app you are in |
| Setup | a model download and a hotkey | install and sign in |

**No cloud dictation tool has a true on-device mode, whatever the marketing
page implies.** A server cannot transcribe audio it never receives. If audio
never leaving your machine is the requirement, local is the only category that
satisfies it, and Handy is the best of that category right now.

---

## Links

- Handy: <https://github.com/cjpais/Handy>
- Handy releases: <https://github.com/cjpais/Handy/releases>
- Handy model reference: <https://handy.computer/docs/models>

I do not maintain Handy and I cannot support it. Its issue tracker is the right
place for problems with it.
