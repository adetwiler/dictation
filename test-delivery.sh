#!/bin/bash
# THE DELIVERY TEST. Does a take actually land where the caret was?
#
# This is separate from test.sh because it is INTERACTIVE: it opens TextEdit,
# takes focus for a few seconds, and closes it again. It cannot run unattended
# and it cannot run over ssh. Run it after touching TextTarget or Paster.
#
# It exercises the SHIPPING code by splicing a harness onto the end of
# main.swift, exactly like test.sh, so it can never pass against a drifted copy.
#
# Needs Accessibility for the terminal you run it from:
#   System Settings > Privacy & Security > Accessibility > your terminal
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)

awk '/^let app = NSApplication.shared/{exit} {print}' main.swift > "$OUT/main.swift"
cat >> "$OUT/main.swift" <<'SWIFT'
// ---- delivery harness, spliced on by test-delivery.sh, never shipped ----

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("PASS | \(name)") }
    else { failures += 1; print("FAIL | \(name)  \(detail)") }
}

/// Pump the main run loop. The Cmd+V path posts its keystroke on a delay, so a
/// harness that returns immediately would test nothing.
func pump(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func readValue(_ el: AXUIElement) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref) == .success
    else { return nil }
    return ref as? String
}

guard AXIsProcessTrusted() else {
    print("")
    print("BLOCKED: this terminal does not have Accessibility.")
    print("Grant it in System Settings > Privacy & Security > Accessibility,")
    print("then run this again. Nothing was tested.")
    exit(2)
}

// ------------------------------------------------------------------
// 1. A NATIVE TEXT AREA. This is the accessibility-insert path.
// ------------------------------------------------------------------
let doc = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "dictation-delivery-test.txt")
try? "".write(to: doc, atomically: true, encoding: .utf8)

let cfg = NSWorkspace.OpenConfiguration()
cfg.activates = true
let sem = DispatchSemaphore(value: 0)
if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
    NSWorkspace.shared.open([doc], withApplicationAt: textEdit, configuration: cfg) { _, _ in
        sem.signal()
    }
}
_ = sem.wait(timeout: .now() + 10)
pump(2.5)   // let the window come up and the caret land in the document

let phrase = "the quick brown fox jumps"
let target = TextTarget.capture()

check("a focused element was found", target != nil,
      "nothing had the caret. Is TextEdit frontmost?")

if let t = target {
    print("       role=\(t.role) acceptsInsert=\(t.acceptsInsert) readableRange=\(t.readableRange)")
    check("the focused element is recognized as text", t.isTextish, "role=\(t.role)")

    let outcome = Paster.deliver(phrase, to: t)
    pump(1.0)   // the Cmd+V fallback posts on a delay

    check("delivery reported landed, not clipboard-only",
          outcome == .landed, "got \(outcome)")

    let got = readValue(t.element) ?? ""
    check("the words are actually in the field", got.contains(phrase),
          "field reads: \(got.isEmpty ? "<empty>" : got)")

    // THE HONESTY CHECK. This is the bug that started all of this: the old code
    // reported success unconditionally, so "it said pasted" meant nothing.
    let landed = got.contains(phrase)
    check("what it REPORTED matches what HAPPENED",
          (outcome == .landed) == landed,
          "reported \(outcome) but field contains=\(landed)")
}

// ------------------------------------------------------------------
// 2. THE Cmd+V FALLBACK, forced.
//
// Chromium and Electron apps do not accept an accessibility insert, so this
// path carries Chrome, VS Code, Slack and Discord. Rather than open a browser
// to test it, build a target that CLAIMS not to accept an insert. Same code
// path, same real window, no second app.
// ------------------------------------------------------------------
if let t = target {
    let forced = TextTarget(element: t.element, role: t.role, pid: t.pid,
                            acceptsInsert: false, readableRange: t.readableRange)
    let second = "and lands by keystroke"
    let outcome = Paster.deliver(second, to: forced)
    pump(1.5)   // the keystroke is posted on a delay
    check("the Cmd+V fallback reports landed", outcome == .landed, "got \(outcome)")
    let got = readValue(t.element) ?? ""
    check("the Cmd+V fallback actually put words in the field",
          got.contains(second), "field reads: \(got.isEmpty ? "<empty>" : got)")
    check("and it did not double-insert",
          got.components(separatedBy: second).count == 2,
          "the phrase appears more than once: \(got)")
}

// Close TextEdit's window without a save dialog.
try? FileManager.default.removeItem(at: doc)
_ = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
    .map { $0.terminate() }
pump(1.0)

// ------------------------------------------------------------------
// 3. NO TEXT TARGET. It must say clipboard-only rather than claim success.
// ------------------------------------------------------------------
let nothing = Paster.deliver("into the void", to: nil)
check("a nil target reports clipboard-only, never landed",
      nothing == .clipboardOnly, "got \(nothing)")

let pb = NSPasteboard.general.string(forType: .string) ?? ""
check("and the words are on the clipboard anyway (the floor holds)",
      pb == "into the void", "clipboard reads: \(pb)")

print("")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
SWIFT

swiftc -O -target arm64-apple-macos26.0 -o "$OUT/dt" "$OUT/main.swift" \
  -framework Cocoa -framework AVFoundation -framework Speech -framework ServiceManagement \
  -framework CoreAudio -framework AudioToolbox
"$OUT/dt"
