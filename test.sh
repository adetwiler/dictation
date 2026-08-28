#!/bin/bash
# The corrector regression test. THIS IS THE TEST THAT MATTERS.
#
# The reason it exists: a fuzzy-matching corrector in another dictation tool typed
# a seeded surname over the spoken word "also", in the middle of a real sentence,
# and the recognizer had heard it perfectly. A corrector that damages correct text
# is worse than no corrector, so the second block below is a FENCE: those strings
# must come back byte for byte unchanged, forever.
#
# It splices a harness onto the END of the SHIPPING main.swift and compiles that,
# so it can never pass against a drifted copy of the corrector.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)

# everything above the top-level NSApplication block, then the harness
awk '/^let app = NSApplication.shared/{exit} {print}' main.swift > "$OUT/main.swift"
cat >> "$OUT/main.swift" <<'SWIFT'
// ---- test harness, spliced on by test.sh, never shipped ----
let corrector = GlossaryCorrector.loadMerged()

// (input, expected), against the example glossary.json in this repo. If you
// replace those terms with your own, replace these cases too.
let cases: [(String, String)] = [
    // multi-word garble collapsing to one term
    ("Let's deploy to cooper netties with engine x in front.",
     "Let's deploy to Kubernetes with nginx in front."),
    ("push it to get hub and add a web hook",
     "push it to GitHub and add a webhook"),
    ("cube cuddle get pods", "kubectl get pods"),
    ("we use oh auth for login", "we use OAuth for login"),
    ("post gres", "Postgres"),
    ("all sop", "Alsop"),
    ("I said \"get hub\", twice.", "I said \"GitHub\", twice."),

    // THE FENCE. Ordinary English that a fuzzy matcher would damage.
    // These must come back byte for byte unchanged.
    ("I want to also test that nothing gets eaten.",
     "I want to also test that nothing gets eaten."),
    ("Alsop said she would also go.", "Alsop said she would also go."),
    ("Hook the web up to the engine.", "Hook the web up to the engine."),
    // "Arc" is listed with no garbles, so it is never registered as a key and
    // the ordinary English word survives. This is the homograph rule.
    ("The arc of the story bends.", "The arc of the story bends."),
    ("", ""),
]

var failures = 0
for (input, expected) in cases {
    let got = corrector.correct(input)
    if got == expected {
        print("PASS | \(input)")
    } else {
        failures += 1
        print("FAIL | \(input)")
        print("   want: \(expected)")
        print("   got : \(got)")
    }
}
print("")
// ---- the stutter cleaner. First block: real stutters from recorded
// speech, MUST clean. Second block: legitimate English that LOOKS like a
// stutter, MUST come back byte for byte unchanged - this is the fence that
// keeps rule 4 narrow.
UserDefaults.standard.removeObject(forKey: Disfluency.offKey)
let stutterCases: [(String, String)] = [
    // fillers
    ("So, um, We'll we'll put a ticket at the end,",
     "So, We'll put a ticket at the end,"),
    ("Um, let me look.", "Let me look."),
    ("So, um, let me just, um, tell, tell, uh, you what I think.",
     "So, let me just, tell, tell, you what I think."),
    // doubled words (safe list + contractions)
    ("and it it should work", "and it should work"),
    ("let's let's go", "let's go"),
    ("We're we're done", "We're done"),
    ("the the ticket", "the ticket"),
    // doubled bigrams
    ("maybe that maybe that is fine", "maybe that is fine"),
    ("you should you should check", "you should check"),
    ("Well, here's here's the thing", "Well, here's the thing"),
    // sentence restarts
    ("So it's still not. So it's still not letting me talk.",
     "So it's still not letting me talk."),
    ("Can you give me a new, Can you give me a new mock so I can see it.",
     "Can you give me a new mock so I can see it."),

    // THE FENCE: legitimate English, never touched.
    ("I know that that is true.", "I know that that is true."),
    ("He had had enough.", "He had had enough."),
    ("What it is is a problem.", "What it is is a problem."),
    ("It was very very loud.", "It was very very loud."),
    ("No, no, keep it.", "No, no, keep it."),
    ("I said tell, tell me now.", "I said tell, tell me now."),
    ("Give him the benefit of the doubt.", "Give him the benefit of the doubt."),
    ("", ""),
]
for (input, expected) in stutterCases {
    let got = Disfluency.clean(input)
    if got == expected {
        print("PASS | \(input)")
    } else {
        failures += 1
        print("FAIL | \(input)")
        print("   want: \(expected)")
        print("   got : \(got)")
    }
}

// The off switch is real: with disfluencyOff set, nothing changes.
UserDefaults.standard.set(true, forKey: Disfluency.offKey)
let offIn = "So, um, the the thing"
if Disfluency.clean(offIn) == offIn {
    print("PASS | off-switch leaves text alone")
} else {
    failures += 1
    print("FAIL | off-switch did not disable the cleaner")
}
UserDefaults.standard.removeObject(forKey: Disfluency.offKey)

print("")
print(failures == 0 ? "ALL PASS (\(cases.count + stutterCases.count + 1) cases)" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
SWIFT

swiftc -O -target arm64-apple-macos26.0 -o "$OUT/ct" "$OUT/main.swift" \
  -framework Cocoa -framework AVFoundation -framework Speech -framework ServiceManagement
"$OUT/ct"
