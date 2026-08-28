// ============================================================================
// dictation - a native macOS push-to-talk that SHOWS you it is listening.
//
// The whole product is one sentence: tap fn, a panel appears on the right edge
// with live level bars and the words as they land, tap fn again, the corrected
// text pastes where you were typing.
//
// The visible indicator is the CORE FEATURE, not a nicety. The failure this
// app exists to fix is "I think it missed the dictation because I did not hit
// the button at the right time." A toggle plus a panel means the start is
// confirmed on screen before you talk.
//
// Single file on purpose. No Xcode project, no SwiftPM, one swiftc line in
// build.sh. If you are forking this, start at MARK: - Config.
//
// MIT licensed. Do whatever you want with it. See AGENTS.md for a map of the
// file and the invariants worth not breaking.
// ============================================================================

import Cocoa
import ApplicationServices
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ServiceManagement
import Speech
import os

// ============================================================================
// MARK: - Config
// ============================================================================

enum Config {
    /// PUT YOUR OWN JARGON HERE. These are the words the recognizer gets nudged
    /// toward while it listens: product names, project code names, surnames,
    /// anything the general English model has never seen.
    ///
    /// RECOGNITION BIASING ONLY (AnalysisContext.contextualStrings). This never
    /// rewrites text; it nudges the recognizer while it listens, so it cannot
    /// produce the failure where an already-correct word gets overwritten. The
    /// post-hoc repair is GlossaryCorrector, exact-after-squash and fenced.
    /// Measured effect is small but it is free.
    ///
    /// Keep the list SHORT. A shorter bias list biases better. Weight it toward
    /// words whose garble fails SILENTLY (a mistyped command name) over words
    /// whose garble is obvious to you when you read it back.
    static let terms = ["Kubernetes", "Postgres", "OAuth", "webhook"]
    static let locale = Locale(identifier: "en-US")

    static let panelW: CGFloat = 268
    static let panelH: CGFloat = 84
    static let margin: CGFloat = 10          // gap from the screen edge
    static let radius: CGFloat = 16

    /// Sized so 3 pt bars with a 2 pt gap FILL the meter width. A waveform that
    /// stops halfway across reads as a progress bar, not as live audio. At 30 Hz
    /// this is about 1.5 seconds of visible history.
    static let meterBars = 44
    static let uiHz: TimeInterval = 1.0 / 30.0

    /// After this long with the peak under noSignalPeak, the panel names the
    /// input device and says it is hearing nothing. This is the tell for a
    /// virtual default input (BlackHole, Background Music) or a dropped TCC grant.
    static let noSignalAfter: TimeInterval = 1.5
    static let noSignalPeak: Float = 0.02

    /// The recording row grows the panel UPWARD, so no existing subview moves.
    static let recRowH: CGFloat = 24

    /// How long a release waits before it really stops. A second fn press inside
    /// this window is a DOUBLE TAP and latches hands-free instead. The cost is
    /// this much extra silence on the end of every push-to-talk take.
    static let doubleTapWindow: TimeInterval = 0.30

    static let pasteSettleMs = 25
    static let flashPasted: TimeInterval = 0.9
    static let flashCopied: TimeInterval = 1.8

    /// Virtual key codes. Spelled out rather than importing Carbon for three ints.
    static let vkV: CGKeyCode = 9
    static let vkFunction: UInt16 = 63
    static let vkEscape: UInt16 = 53
}

// ============================================================================
// MARK: - Paths
//
// EVERYTHING THIS APP WRITES LIVES UNDER ONE DIRECTORY, so a fork can move it
// by changing one line and an uninstall is `rm -rf` on one path.
//
//   ~/Library/Application Support/dictation/
//     glossary.json            your correction pairs (see GlossaryCorrector)
//     history.jsonl            one line per take, append only
//     panel.log                the panel's own debug log
//     sounds/                  custom_start.wav / custom_stop.wav, if you use them
//
// The directory is created lazily. Nothing here needs it to exist to start.
// ============================================================================

enum Paths {
    /// Bundle-id-free on purpose: this is a plain readable folder you are meant
    /// to open and edit by hand, not an opaque container.
    static let support: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/dictation")

    static var glossary: URL { support.appending(path: "glossary.json") }
    static var history: URL { support.appending(path: "history.jsonl") }
    static var panelLog: URL { support.appending(path: "panel.log") }
    static var sounds: URL { support.appending(path: "sounds") }

    /// Best effort. Every caller already handles a write that did not land.
    @discardableResult
    static func ensureSupportDir() -> Bool {
        (try? FileManager.default.createDirectory(at: support,
                                                  withIntermediateDirectories: true)) != nil
    }
}

// ============================================================================
// MARK: - Glyph
//
// Lucide geometry drawn with NSBezierPath. No system emoji (drawn by the OS, so
// a different picture on every machine, and it cannot take a color) and no SF
// Symbols (so the menubar glyph and the panel glyph are the same shapes).
//
// Coordinates below are the Lucide 24x24 grid ALREADY FLIPPED to AppKit's
// y-up space by hand. Doing the flip in the numbers instead of in an
// NSAffineTransform means there is no transform-order puzzle to get wrong.
// ============================================================================

enum Glyph {
    private static let grid: CGFloat = 24
    private static let lineWidth: CGFloat = 1.6

    private static func image(_ size: CGFloat, _ color: NSColor,
                              _ body: @escaping (CGFloat) -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let s = size / grid
            color.setStroke()
            color.setFill()
            body(s)
            return true
        }
        return img
    }

    private static func stroked(_ path: NSBezierPath, _ s: CGFloat) {
        path.lineWidth = lineWidth * s
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ s: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x1 * s, y: y1 * s))
        p.line(to: NSPoint(x: x2 * s, y: y2 * s))
        stroked(p, s)
    }

    private static func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                                _ r: CGFloat, _ s: CGFloat) {
        let p = NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: w * s, height: h * s),
                             xRadius: r * s, yRadius: r * s)
        stroked(p, s)
    }

    private static func micBody(_ s: CGFloat) {
        rounded(9, 9, 6, 13, 3, s)                              // the capsule
        let arc = NSBezierPath()
        // Lucide's "M19 10v2a7 7 0 0 1-14 0v-2" is the lower half circle once flipped.
        arc.appendArc(withCenter: NSPoint(x: 12 * s, y: 12 * s), radius: 7 * s,
                      startAngle: 0, endAngle: 180, clockwise: true)
        stroked(arc, s)
        line(12, 5, 12, 2, s)                                   // the stem
    }

    static func mic(_ size: CGFloat, _ color: NSColor) -> NSImage {
        image(size, color) { s in micBody(s) }
    }

    static func micOff(_ size: CGFloat, _ color: NSColor) -> NSImage {
        image(size, color) { s in
            micBody(s)
            line(2, 22, 22, 2, s)                               // the slash
        }
    }

    static func check(_ size: CGFloat, _ color: NSColor) -> NSImage {
        image(size, color) { s in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 20 * s, y: 18 * s))
            p.line(to: NSPoint(x: 9 * s, y: 7 * s))
            p.line(to: NSPoint(x: 4 * s, y: 12 * s))
            stroked(p, s)
        }
    }

    static func clipboard(_ size: CGFloat, _ color: NSColor) -> NSImage {
        image(size, color) { s in
            rounded(4, 2, 16, 18, 2, s)                         // the board
            rounded(8, 18, 8, 4, 1, s)                          // the tab
        }
    }

    static func alert(_ size: CGFloat, _ color: NSColor) -> NSImage {
        image(size, color) { s in
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: 12 * s, y: 21 * s))
            tri.line(to: NSPoint(x: 2 * s, y: 3 * s))
            tri.line(to: NSPoint(x: 22 * s, y: 3 * s))
            tri.close()
            stroked(tri, s)
            line(12, 15, 12, 11, s)                             // the bar
            let dot = NSBezierPath(ovalIn: NSRect(x: 11.2 * s, y: 6.2 * s,
                                                  width: 1.6 * s, height: 1.6 * s))
            dot.fill()
        }
    }

    /// The menubar glyph is a template so it follows light and dark menubars.
    static func template(_ img: NSImage) -> NSImage {
        img.isTemplate = true
        return img
    }
}

// ============================================================================
// MARK: - Cue
//
// The start/stop cue sounds. OPTIONAL: with no wavs present, nothing plays and
// the panel is the only feedback. See build.sh for the size/shape that works.
//
// The NSSound instances are held in statics on purpose: a locally scoped
// NSSound deallocs at the end of the call and the cue cuts off mid-play.
// ============================================================================

enum Cue {
    private static var start: NSSound?
    private static var stop: NSSound?

    static func load() {
        start = resolve("custom_start")
        stop = resolve("custom_stop")
    }

    private static func resolve(_ name: String) -> NSSound? {
        if let url = Bundle.main.url(forResource: name, withExtension: "wav"),
           let s = NSSound(contentsOf: url, byReference: false) { return s }
        // Not bundled: look for a drop-in override you can swap without rebuilding.
        let fallback = Paths.sounds.appending(path: "\(name).wav")
        return NSSound(contentsOf: fallback, byReference: false)
    }

    static func playStart() { play(start) }
    static func playStop() { play(stop) }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.currentTime = 0
        sound.play()
    }
}

// ============================================================================
// MARK: - AudioCapture
//
// Lifted from the research pass, which compiled clean and ran end to end.
// Added here: the configuration-change observer and rebuildTap, because
// AVAudioEngine does NOT follow a device change. When AirPods connect mid
// flight the hardware sample rate and channel count change, the converter
// built at start() is now wrong, and audio either stops or arrives garbled.
// On a plane with AirPods that is the expected case, not a corner case.
// ============================================================================

final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var hardwareFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?

    // Input preferences. Persisted by name, not device ID: IDs change across
    // reboots and unplugs; the name is what you picked. Boost exists because the
    // RODE Wireless Pro delivers USB audio ~20 dB low BY DESIGN (RX gain is
    // bypassed over USB), which reads as "dictation cannot hear me."
    static let deviceKey = "inputDeviceName"
    static let boostKey = "inputBoostDB"
    private var boostLinear: Float = 1

    struct InputDevice { let id: AudioDeviceID; let name: String }

    /// Every device with at least one input stream, by CoreAudio's book.
    static func inputDevices() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var result: [InputDevice] = []
        for id in ids {
            var streamsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var ssize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &ssize) == noErr, ssize > 0 else { continue }
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var cfName: CFString?
            var nsize = UInt32(MemoryLayout<CFString?>.size)
            let err = withUnsafeMutablePointer(to: &cfName) { p in
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nsize, p)
            }
            guard err == noErr, let name = cfName as String? else { continue }
            result.append(InputDevice(id: id, name: name))
        }
        return result
    }

    /// Point the engine's input at the picked device (if it is present) and
    /// cache the boost. Runs before the tap is (re)installed so the hardware
    /// format read afterwards belongs to the RIGHT device. A missing picked
    /// device falls back to the system default silently: dictation must work.
    private func applyPreferences() {
        let db = UserDefaults.standard.double(forKey: Self.boostKey)
        boostLinear = db > 0 ? powf(10, Float(db) / 20) : 1
        guard let wanted = UserDefaults.standard.string(forKey: Self.deviceKey), !wanted.isEmpty,
              let dev = Self.inputDevices().first(where: { $0.name == wanted }),
              let au = engine.inputNode.audioUnit else { return }
        var devID = dev.id
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &devID,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// 0...1, already smoothed and floor-corrected. Called on the audio thread, roughly every 23 ms.
    var onLevel: ((Float) -> Void)?
    /// Converted buffer in the analyzer's format. Called on the audio thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// The hardware format changed under us. Called on main.
    var onConfigChange: (() -> Void)?

    // Measured in a quiet home office: the ambient floor sits near -50 dBFS RMS.
    // Retune these two if the meter is pinned or dead in your room.
    private let floorDB: Float = -52
    private let ceilDB: Float = -12
    private var smoothed: Float = 0

    var isRunning: Bool { engine.isRunning }

    /// The name of the input actually in use. Shown on the panel because a
    /// silent meter is only diagnosable if you can see WHICH device is silent.
    var deviceName: String {
        if let wanted = UserDefaults.standard.string(forKey: Self.deviceKey), !wanted.isEmpty {
            if Self.inputDevices().contains(where: { $0.name == wanted }) { return wanted }
            return "\(wanted) (unplugged, using default)"
        }
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown input"
    }

    /// Mic permission must already be granted before this is called. Touching
    /// `inputNode` without it yields a zero-channel format and installTap throws.
    func start(targetFormat: AVAudioFormat) throws {
        self.targetFormat = targetFormat
        applyPreferences()
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.channelCount > 0 else { throw AudioError.noInputDevice }
        hardwareFormat = hw
        converter = AVAudioConverter(from: hw, to: targetFormat)
        converter?.primeMethod = .none

        input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buffer, _ in
            self?.handle(buffer, hardware: hw)
        }
        engine.prepare()
        try engine.start()

        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                self?.onConfigChange?()
            }
        }
    }

    /// Rebuild the tap and converter in place against the NEW hardware format.
    /// Deliberately does not stop the engine: the session keeps its identity so
    /// the transcript in progress survives an AirPods connect.
    func rebuildTap(targetFormat: AVAudioFormat) throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        applyPreferences()
        let hw = input.outputFormat(forBus: 0)
        guard hw.channelCount > 0 else { throw AudioError.noInputDevice }
        hardwareFormat = hw
        self.targetFormat = targetFormat
        converter = AVAudioConverter(from: hw, to: targetFormat)
        converter?.primeMethod = .none
        input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buffer, _ in
            self?.handle(buffer, hardware: hw)
        }
        if !engine.isRunning { try engine.start() }
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
        smoothed = 0
        onLevel?(0)
    }

    private func handle(_ buffer: AVAudioPCMBuffer, hardware hw: AVAudioFormat) {
        // Boost first, in place, so the meter AND the recognizer both see the
        // corrected signal. Clamped: a hot mic plus a big boost must clip, not wrap.
        if boostLinear != 1, let channels = buffer.floatChannelData {
            let n = Int(buffer.frameLength)
            for c in 0..<Int(buffer.format.channelCount) {
                let p = channels[c]
                for i in 0..<n { p[i] = max(-1, min(1, p[i] * boostLinear)) }
            }
        }
        if let channels = buffer.floatChannelData {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            let samples = channels[0]
            for i in 0..<n { let v = samples[i]; sum += v * v }
            let rms = sqrt(sum / Float(max(n, 1)))
            let db = 20 * log10(max(rms, 1e-7))
            let norm = min(max((db - floorDB) / (ceilDB - floorDB), 0), 1)
            // Fast attack so the bars jump the instant you speak, slow release
            // so they do not flicker between syllables.
            let alpha: Float = norm > smoothed ? 0.5 : 0.12
            smoothed += (norm - smoothed) * alpha
            onLevel?(smoothed)
        }
        guard let converter, let target = targetFormat else { return }
        let ratio = target.sampleRate / hw.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var error: NSError?
        var delivered = false
        converter.convert(to: out, error: &error) { _, status in
            if delivered { status.pointee = .noDataNow; return nil }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        onBuffer?(out)
    }

    enum AudioError: Error { case noInputDevice }
}

// ============================================================================
// MARK: - Transcriber
// ============================================================================

/// One dictation's recognized text.
/// `finalized` only grows; `volatile` is the unstable tail and is replaced wholesale.
/// Render `full` in the indicator: exactly what you would get if you let go now.
struct TranscriptState: Sendable {
    var finalized: String = ""
    var volatile: String = ""
    var full: String { finalized + volatile }
}

/// THE SWAP SEAM, and the most useful thing in this file if you are forking.
///
/// Apple's Speech.framework conforms today. A local Whisper or Parakeet runtime
/// can conform instead without touching the hotkey, the indicator, the corrector
/// or the paste path. That is the whole point of the protocol existing at all:
/// six methods is a cheap price for not being married to one recognizer.
///
/// If you are trying to run this on a machine without Apple's on-device model,
/// this protocol is where you start and AppleTranscriber below is what you
/// replace. Everything else in the file is platform-neutral logic.
protocol Transcribing: AnyObject, Sendable {
    /// Audio format the capture layer must convert to before calling `feed`.
    var requiredFormat: AVAudioFormat? { get }
    /// Load models. Call once at launch, never on the keypress.
    func prepare() async throws
    /// Open a session. `onUpdate` fires on an arbitrary thread; hop to main yourself.
    func begin(onUpdate: @escaping @Sendable (TranscriptState) -> Void) async throws
    /// Feed one converted buffer. Safe from the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer)
    /// Close the session and return the complete text.
    func end() async throws -> String
    /// Throw the session away without a final pass.
    func abort() async
}

/// On-device recognition via SpeechAnalyzer.
///
/// Measured on an M4 Max, macOS 26.5.2 / Xcode 26.2, 2026-08-03:
///   - SpeechTranscriber.isAvailable == true, en-US already in installedLocales
///   - asset install request completes in 0.44 s (models already on disk)
///   - analyzer format is 1 ch / 16000 Hz / Int16
///   - finalizeAndFinishThroughEndOfInput returns 0.03 to 0.07 s after audio stops
///   - NO SFSpeechRecognizer authorization needed: transcription worked with
///     authorizationStatus == .notDetermined. Microphone permission is the only gate.
@available(macOS 26.0, *)
final class AppleTranscriber: Transcribing, @unchecked Sendable {
    private let locale: Locale
    private let contextualStrings: [String]

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let state = OSAllocatedUnfairLock(initialState: TranscriptState())

    private(set) var requiredFormat: AVAudioFormat?

    init(locale: Locale = Locale(identifier: "en-US"), contextualStrings: [String] = []) {
        self.locale = locale
        self.contextualStrings = contextualStrings
    }

    private func makeModule() -> SpeechTranscriber {
        // .volatileResults is what makes the indicator show words as you speak.
        // .fastResults exists as a knob if the partials ever feel laggy.
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults],
                          attributeOptions: [])
    }

    func prepare() async throws {
        let module = makeModule()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        requiredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    }

    func begin(onUpdate: @escaping @Sendable (TranscriptState) -> Void) async throws {
        let module = makeModule()
        transcriber = module
        if requiredFormat == nil {
            requiredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        }

        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            // Measured small: it moved "Globi Grounds" to "Globu Grounds" and
            // changed nothing else. Keep it, but it is not the correction layer.
            context.contextualStrings = [.general: contextualStrings]
        }

        resetState()

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        let analyzer = SpeechAnalyzer(modules: [module], options: nil)
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [state] in
            do {
                for try await result in module.results {
                    let text = String(result.text.characters)
                    let snapshot = state.withLock { current -> TranscriptState in
                        if result.isFinal {
                            // The text already carries its own leading space.
                            // Never insert one or every sentence gains a gap.
                            current.finalized += text
                            current.volatile = ""
                        } else {
                            current.volatile = text
                        }
                        return current
                    }
                    onUpdate(snapshot)
                }
            } catch {
                // A cancelled or finished session ends the sequence. Not an error.
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    func end() async throws -> String {
        continuation?.finish()
        continuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        teardown()
        return readState().full.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func abort() async {
        continuation?.finish()
        continuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        teardown()
    }

    private func teardown() {
        resultsTask = nil
        analyzer = nil
        transcriber = nil
    }

    // OSAllocatedUnfairLock may not be locked from an async context, so every
    // touch goes through a synchronous helper.
    private func resetState() { state.withLock { $0 = TranscriptState() } }
    private func readState() -> TranscriptState { state.withLock { $0 } }
}

// ============================================================================
// MARK: - GlossaryCorrector
//
// The offline repair pass that runs after the recognizer and before the paste.
// ============================================================================

/// Offline proper-noun repair. EXACT match after squashing case, spaces, hyphens
/// and apostrophes; never fuzzy, never edit distance.
///
/// WARNING: THE EXACT-MATCH RULE IS THE WHOLE SAFETY PROPERTY, and it is worth
/// understanding before you "improve" it. A fuzzy corrector with a distance
/// threshold will, sooner or later, rewrite an ordinary English word into one of
/// your jargon terms in the middle of a real sentence. That is not a tuning
/// problem, it is what fuzzy matching does. Measured example from a tool that
/// does it this way: "Can you also build a UI for it" came out as
/// "Can you Alyssa build a UI for it", because a seeded surname sat inside the
/// fuzzy neighbourhood of "also". The recognizer had heard it perfectly.
///
/// squash("also") is "also" and squash("alyssa") is "alyssa". They never collide,
/// so that failure is structurally impossible here.
///
/// Sources, merged in this order (later wins on conflicts):
///   1. the bundled `glossary.json` shipped in the app
///   2. `~/Library/Application Support/dictation/glossary.json`, yours to edit
struct GlossaryCorrector {
    private let byLength: [Int: [String: String]]   // n-gram size -> squashed key -> canonical
    private let maxSpan: Int

    static func squash(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    init(terms: [(correct: String, garbles: [String])]) {
        var map: [Int: [String: String]] = [:]
        var longest = 1
        // A garble is stored under the number of TOKENS it can span. "web hook"
        // is two tokens; the same squashed key also matches the one-token
        // "webhook", so every key is registered at 1...its own word count.
        for term in terms {
            var forms = term.garbles
            // A SINGLE-word canonical is registered as its own key only when a
            // garble already proves the term is really spoken. Registering every
            // one-word term unconditionally is the homograph trap: a term that is
            // also an ordinary English word ("Arc", "Notion", "Swift") silently
            // capitalizes every innocent use of it.
            let isMultiWord = term.correct.contains(" ") || term.correct.contains("-")
            if isMultiWord { forms.append(term.correct) }
            for form in forms {
                let key = Self.squash(form)
                guard !key.isEmpty else { continue }
                let words = max(form.split(separator: " ").count, 1)
                for n in 1...words {
                    map[n, default: [:]][key] = term.correct
                    longest = max(longest, n)
                }
            }
        }
        byLength = map
        maxSpan = longest
    }

    /// Load the bundled defaults, merge your own file over them, then fence.
    /// Returns an empty corrector on any problem: losing a proper noun is always
    /// better than losing the dictation.
    static func loadMerged() -> GlossaryCorrector {
        var terms = loadBundledTerms()
        for extra in loadUserTerms() {
            let key = squash(extra.correct)
            if let idx = terms.firstIndex(where: { squash($0.correct) == key }) {
                var merged = terms[idx].garbles
                for g in extra.garbles where !merged.contains(where: { squash($0) == squash(g) }) {
                    merged.append(g)
                }
                terms[idx] = (terms[idx].correct, merged)
            } else {
                terms.append(extra)
            }
        }
        return GlossaryCorrector(terms: fence(terms))
    }

    /// The defaults that ship inside the app. Bundle first so an installed copy is
    /// self-contained; the working directory second so `./test.sh` and a
    /// not-yet-installed build both still correct.
    private static func loadBundledTerms() -> [(correct: String, garbles: [String])] {
        if let url = Bundle.main.url(forResource: "glossary", withExtension: "json"),
           let terms = parseTermsJSON(at: url), !terms.isEmpty { return terms }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return parseTermsJSON(at: cwd.appending(path: "glossary.json")) ?? []
    }

    /// YOURS. Edit this file, quit and relaunch. It is merged OVER the bundled
    /// defaults, so an app update never clobbers your words.
    private static func loadUserTerms() -> [(correct: String, garbles: [String])] {
        parseTermsJSON(at: Paths.glossary) ?? []
    }

    private static func parseTermsJSON(at url: URL) -> [(correct: String, garbles: [String])]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["terms"] as? [[String: Any]] else { return nil }
        return raw.compactMap { entry -> (String, [String])? in
            guard let correct = entry["correct"] as? String, !correct.isEmpty else { return nil }
            return (correct, entry["garbles"] as? [String] ?? [])
        }
    }

    /// THE CROSS-TERM FENCE: a real term may never survive as another term's
    /// garble. Without it, adding a term to your glossary can silently start
    /// rewriting a DIFFERENT term you also care about, and the two rows may have
    /// been written months apart by people who never saw each other's list.
    /// Applied to the MERGED list for exactly that reason.
    private static func fence(_ terms: [(correct: String, garbles: [String])])
        -> [(correct: String, garbles: [String])] {
        let canonical = Set(terms.map { squash($0.correct) })
        return terms.map { term in
            (term.correct, term.garbles.filter { g in
                let k = squash(g)
                return k == squash(term.correct) || !canonical.contains(k)
            })
        }
    }

    /// Longest-span-first greedy scan over whitespace tokens. Trailing punctuation
    /// on the last token of a span is preserved, so "Web Hook," becomes "webhook,".
    func correct(_ text: String) -> String {
        guard maxSpan > 0, !byLength.isEmpty else { return text }
        var tokens: [Substring] = []
        var ranges: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            tokens.append(text[i..<j]); ranges.append(i..<j)
            i = j
        }
        guard !tokens.isEmpty else { return text }

        var replacements: [(Range<String.Index>, String)] = []
        var t = 0
        while t < tokens.count {
            var matched = false
            var n = min(maxSpan, tokens.count - t)
            while n >= 1 {
                let span = tokens[t..<(t + n)]
                let core = span.map(Self.stripEdges).joined()
                let key = Self.squash(core)
                if !key.isEmpty, let canonical = byLength[n]?[key] {
                    let tail = String(span.last!)
                    let suffix = String(tail.reversed().prefix(while: { !$0.isLetter && !$0.isNumber }).reversed())
                    let prefixChar = String(String(span.first!).prefix(while: { !$0.isLetter && !$0.isNumber }))
                    let range = ranges[t].lowerBound..<ranges[t + n - 1].upperBound
                    let rebuilt = prefixChar + canonical + suffix
                    // Compare against the SOURCE TEXT of the span, never against
                    // the space-stripped core. Comparing to the core silently
                    // skips any garble that differs from its canonical only by
                    // spacing, so a lowercase "ultra code" stayed broken while
                    // "Ultra Code" got repaired. Any all-lowercase canonical whose
                    // garble differs only by a space hits this exact case.
                    if rebuilt != text[range] {
                        replacements.append((range, rebuilt))
                    }
                    t += n
                    matched = true
                    break
                }
                n -= 1
            }
            if !matched { t += 1 }
        }
        guard !replacements.isEmpty else { return text }
        var out = text
        for (range, value) in replacements.reversed() { out.replaceSubrange(range, with: value) }
        return out
    }

    /// Drop leading and trailing punctuation so "Loop," compares as "Loop".
    private static func stripEdges(_ s: Substring) -> String {
        var t = Substring(s)
        while let f = t.first, !f.isLetter, !f.isNumber { t = t.dropFirst() }
        while let l = t.last, !l.isLetter, !l.isNumber { t = t.dropLast() }
        return String(t)
    }
}

// ============================================================================
// MARK: - TextTarget
//
// WHERE THE WORDS LAND. This is the part that used to be wrong, so it is worth
// reading before you change it.
//
// THE RULE: the take lands wherever the caret was WHEN YOU LET GO OF THE KEY.
// If there is no caret to land in, the words go to the clipboard and the panel
// says so. Never a silent failure, never a landing somewhere you did not aim.
//
// The old version could not honor that, because it did one thing: write the
// clipboard, then post a synthetic Cmd+V into whatever happened to be frontmost
// a moment later, and report success unconditionally. That has three holes, and
// all three were reachable in normal use:
//
//   1. A KEYSTROKE IS NOT A DELIVERY RECEIPT. Cmd+V posted at an app with a
//      focused window but no focused text field does nothing at all, and there
//      is no error to catch. The panel still said "pasted". The words were on
//      the clipboard the whole time, but nothing said so, which is the exact
//      shape of "I think it ate my dictation". Leaving an app and coming back
//      lands you in that state constantly: the window is focused, the field is
//      not.
//   2. IT RESOLVED THE TARGET TOO LATE. Delivery happens a few hundred
//      milliseconds after release (the double-tap window, then the recognizer's
//      final pass). A keystroke goes to whatever is focused AT THE MOMENT IT IS
//      POSTED, so clicking away during that gap sent your words into a
//      different app.
//   3. IT COULD NOT AIM. Cmd+V has no target. It goes wherever focus is.
//
// So: capture the FOCUSED ELEMENT at release, keep the reference, and deliver
// to that element. Two delivery paths, in order of preference.
//
// A. ACCESSIBILITY INSERT (preferred). Set kAXSelectedText on the captured
//    element. This inserts at the caret, or replaces the selection, in the
//    element itself. It does not care what is frontmost, it cannot land in the
//    wrong app, and it does not depend on the target app's keyboard handling.
//
// B. SYNTHETIC Cmd+V (fallback). For apps that do not implement the text part
//    of the accessibility API. Chromium and Electron apps are the big ones,
//    which means Chrome, VS Code, Slack, Discord and most of the browser. This
//    path DOES require the target app to still be frontmost, so it is checked
//    by pid rather than assumed, and it downgrades to the clipboard when focus
//    has moved on.
//
// THE CLIPBOARD IS WRITTEN FIRST, ALWAYS, on every path including the ones that
// then succeed at inserting. It costs you your clipboard contents and it buys
// an absolute guarantee: there is no sequence of failures that loses a take.
// The previous clipboard is deliberately NOT restored, for the same reason.
// ============================================================================

/// The element the caret was in when the key came up. Captured at release,
/// delivered to later. Holding an AXUIElement across that gap is fine: it is a
/// live reference, and if the element dies the delivery simply fails and falls
/// through to the clipboard.
struct TextTarget {
    let element: AXUIElement
    let role: String
    let pid: pid_t
    /// Can we set kAXSelectedText on it? True means path A is available.
    let acceptsInsert: Bool
    /// Can we read kAXSelectedTextRange? Path A is only attempted when this is
    /// true, because it is the only way to VERIFY an insert actually happened.
    let readableRange: Bool

    /// Roles that can hold text. An element with a role outside this set and no
    /// settable selected-text attribute is not somewhere words can land, and
    /// saying so is the whole point.
    ///
    /// AXComboBox is in here but is excluded from path A below on purpose: it
    /// accepts a kAXSelectedText write, reports success, and does nothing.
    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea",
    ]

    var isTextish: Bool { acceptsInsert || Self.textRoles.contains(role) }

    /// Read the focused element. Call this AT RELEASE.
    ///
    /// Returns nil when there is nothing to aim at, which is a real and common
    /// answer: a Finder window, a focused app with no field, a desktop click.
    /// nil means "clipboard, and say so", not "something went wrong".
    ///
    /// WARNING: ASK THE APP, NOT THE SYSTEM. Every tutorial reaches for
    /// AXUIElementCreateSystemWide and kAXFocusedUIElementAttribute, and that is
    /// the fragile way to do it. Measured here against a focused TextEdit
    /// document, with Accessibility granted and AXIsProcessTrusted() true:
    ///
    ///   system-wide  -> err -25204 (cannotComplete), no element, every time
    ///   per-app      -> success, AXTextArea, settable, range readable
    ///
    /// So: find the frontmost app, build an AXUIElement FOR THAT PROCESS, and
    /// ask it what has focus. The system-wide call is kept only as a fallback,
    /// because there is no reason to refuse an answer if it ever gives one.
    /// Re-check with test-delivery.sh, which fails loudly if this regresses.
    static func capture() -> TextTarget? {
        guard AXIsProcessTrusted() else { return nil }
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }

        let pid = front.processIdentifier
        // OUR OWN MENUBAR IS NOT A DESTINATION. Stopping a take from the menu
        // makes this app frontmost, and without this check the target would be
        // our own menu item. Answer nil so it goes to the clipboard and the
        // panel says so, rather than posting Cmd+V at ourselves.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        guard let element = focusedElement(ofPID: pid) ?? focusedElementSystemWide() else {
            return nil
        }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        var settable: DarwinBoolean = false
        let settableOK = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable) == .success

        var rangeRef: CFTypeRef?
        let rangeOK = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success

        return TextTarget(element: element,
                          role: role,
                          pid: pid,
                          acceptsInsert: settableOK && settable.boolValue,
                          readableRange: rangeOK)
    }

    /// The reliable path: ask one process what has keyboard focus inside it.
    private static func focusedElement(ofPID pid: pid_t) -> AXUIElement? {
        unwrap(AXUIElementCreateApplication(pid))
    }

    /// The tutorial path, kept only as a fallback. See the note on capture().
    private static func focusedElementSystemWide() -> AXUIElement? {
        unwrap(AXUIElementCreateSystemWide())
    }

    private static func unwrap(_ container: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(container,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &raw) == .success,
              let value = raw,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// The caret position and selection length, or nil if this element does not
    /// report one.
    fileprivate func selection() -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextRangeAttribute as CFString,
                                            &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}

// ============================================================================
// MARK: - Paster
// ============================================================================

enum Paster {
    /// What actually happened to the words. The panel says one of these, and it
    /// must be true: a panel that claims "pasted" when nothing landed is worse
    /// than no panel, because it trains you to stop believing the one indicator
    /// this whole app exists to provide.
    enum Outcome {
        /// It went into the caret, by insert or by keystroke.
        case landed
        /// It is on the clipboard and nowhere else. Press Cmd V yourself.
        case clipboardOnly
    }

    @discardableResult
    static func deliver(_ text: String, to target: TextTarget?) -> Outcome {
        guard !text.isEmpty else { return .clipboardOnly }

        // THE FLOOR, WRITTEN FIRST AND ON EVERY PATH. Nothing below this line
        // can lose the take, whatever else fails.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // No caret to land in. This is an honest answer, not a failure.
        guard let target, target.isTextish else { return .clipboardOnly }

        if insert(text, into: target) { return .landed }
        if pressCommandV(target) { return .landed }
        return .clipboardOnly
    }

    // ------------------------------------------------------------------
    // Path A: accessibility insert
    // ------------------------------------------------------------------

    /// Set kAXSelectedText on the captured element, then PROVE it happened by
    /// reading the caret back.
    ///
    /// Two refusals here exist to prevent a DOUBLE INSERT, which is the one
    /// failure worse than not inserting at all:
    ///
    ///  - AXComboBox is refused outright. It accepts the write, returns success
    ///    and does nothing. Search fields in several apps are combo boxes.
    ///  - An element whose caret cannot be READ is never written to, because an
    ///    unverifiable insert cannot be safely retried with Cmd+V afterwards.
    ///
    /// And when the caret was readable before the write but not after, this
    /// reports SUCCESS rather than falling through. An ambiguous result means
    /// the text may already be in the field, and pasting on top of a maybe is
    /// how you get the sentence twice.
    private static func insert(_ text: String, into target: TextTarget) -> Bool {
        guard target.acceptsInsert, target.readableRange, target.role != "AXComboBox" else {
            return false
        }
        guard let before = target.selection() else { return false }

        let err = AXUIElementSetAttributeValue(target.element,
                                               kAXSelectedTextAttribute as CFString,
                                               text as CFString)
        guard err == .success else { return false }

        // Unreadable after a write that claimed success: assume it landed. See above.
        guard let after = target.selection() else { return true }
        // The caret moved, or the selection it replaced is gone. Either way the
        // element changed, which is the only evidence available that the write
        // was real rather than politely swallowed.
        return after.location != before.location || after.length != before.length
    }

    // ------------------------------------------------------------------
    // Path B: synthetic Cmd+V
    // ------------------------------------------------------------------

    /// For apps with no accessibility text support. Chromium and Electron are
    /// the reason this path exists and it is not a small set: Chrome, VS Code,
    /// Slack, Discord, and anything else shipping a browser.
    ///
    /// A keystroke has no target, so this is only safe while the app that owned
    /// the caret is still frontmost. Checked, not assumed: if you clicked away
    /// during the recognizer's final pass, this refuses and the words stay on
    /// the clipboard rather than appearing in somebody's chat window.
    private static func pressCommandV(_ target: TextTarget) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            return false
        }

        // A PRIVATE EVENT SOURCE, not nil. A nil source inherits the live
        // hardware modifier state, so a modifier still physically held (very
        // possible: this app is driven by a key you just released) rides along
        // and the target app sees a chord it does not recognize as paste.
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: Config.vkV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: Config.vkV, keyDown: false)
        else { return false }

        // Assigned, not OR-ed into what is already there. Command and nothing else.
        down.flags = .maskCommand
        up.flags = .maskCommand

        // A short settle before the keystroke. The pasteboard write above and
        // the target app's read of it are not ordered by anything else.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Config.pasteSettleMs)) {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        // Optimistic by necessity: a posted keystroke returns no receipt. This
        // is exactly why path A is preferred and why path B is the fallback.
        return true
    }
}

// ============================================================================
// MARK: - IndicatorState
// ============================================================================

enum IndicatorState {
    case hidden
    case listening(device: String)
    case noSignal(device: String)
    case thinking
    case pasted(preview: String)
    case copied(preview: String)
    case cancelled
    case blocked(reason: String)
}

// ============================================================================
// MARK: - MeterView
//
// A SCROLLING waveform, not a static level bar. It moves even at constant
// volume, which is the entire difference between "it is listening" and "it is
// frozen". This is the most load-bearing view in the app.
// ============================================================================

final class MeterView: NSView {
    private var ring = [Float](repeating: 0, count: Config.meterBars)
    private var frozen = false
    var tint: NSColor = NSColor.systemRed { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    func push(_ level: Float) {
        guard !frozen else { return }
        ring.removeFirst()
        ring.append(min(max(level, 0), 1))
        needsDisplay = true
    }

    func freeze() { frozen = true }

    func clear() {
        frozen = false
        ring = [Float](repeating: 0, count: Config.meterBars)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = ring.count
        guard count > 0 else { return }
        let gap: CGFloat = 2
        let barW: CGFloat = 3
        let totalW = CGFloat(count) * barW + CGFloat(count - 1) * gap
        var x = (bounds.width - totalW) / 2
        let midY = bounds.height / 2
        for i in 0..<count {
            // Older bars fade toward the left so the movement reads as travel.
            let age = CGFloat(i) / CGFloat(max(count - 1, 1))
            let alpha = 0.35 + 0.65 * age
            let h = max(2, CGFloat(ring[i]) * bounds.height)
            let rect = NSRect(x: x, y: midY - h / 2, width: barW, height: h)
            let p = NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2)
            tint.withAlphaComponent(alpha).setFill()
            p.fill()
            x += barW + gap
        }
    }
}

// ============================================================================
// MARK: - Indicator
//
// One NSPanel, built once at launch, ordered in and out. Idle means completely
// hidden: the mapping "panel on screen == microphone is open" has to be
// unambiguous or it stops being proof of anything.
//
// The panel sets sharingType = .none, so it never lands in a screen recording.
// ============================================================================

/// OPTIONAL SCREEN-RECORDING INDICATOR. Delete this and RecordingWatch below if
/// you do not want it: nothing else depends on either.
///
/// This app never records anything itself. It only DISPLAYS the state of some
/// other screen-recorder you already run, so that one always-on-top panel can be
/// the single place you look. The contract is two files in your home directory,
/// which any recorder script can write in a line of shell:
///
///   ~/.recording.lock    exists while a recording is running
///   ~/.recording.state   "" | "paused" | "stopped:<AppName>"
///
/// With neither file present the row never appears and the panel behaves exactly
/// as if this feature did not exist.
enum RecState: Equatable {
    case idle
    case live(since: Date)
    case paused
    /// Something hard-stopped the recording, and the app that caused it is named.
    /// This is the case that must be impossible to miss: the whole point of an
    /// on-screen indicator is a clear signal that you are NOT recording any more.
    case killed(app: String)
}

/// Polls the two files above. Polling, not FSEvents, because a 1 s tick is
/// invisible next to a recording session and there is nothing to get wrong.
final class RecordingWatch {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var timer: Timer?
    private(set) var state: RecState = .idle
    var onChange: ((RecState) -> Void)?

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let next = read()
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    private func read() -> RecState {
        let lock = home.appending(path: ".recording.lock")
        let stateFile = home.appending(path: ".recording.state")
        let raw = (try? String(contentsOf: stateFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // The guard writes "stopped:<app>" and CLEARS the lock, so check this
        // first or a hard-stop reads as plain idle and the alarm never fires.
        if raw.hasPrefix("stopped:") {
            return .killed(app: String(raw.dropFirst("stopped:".count)))
        }
        guard FileManager.default.fileExists(atPath: lock.path) else { return .idle }
        if raw == "paused" { return .paused }
        // `epoch` is written by rec at start; it drives the elapsed clock.
        if let d = try? Data(contentsOf: lock),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let e = o["epoch"] as? Double {
            return .live(since: Date(timeIntervalSince1970: e))
        }
        return .live(since: Date())
    }
}

final class Indicator {
    private let panel: NSPanel
    private let blur = NSVisualEffectView()
    private let tint = NSView()
    private let dot = NSView()
    private let meter = MeterView()
    private let primary = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private let flash = NSImageView()
    private var pulseTimer: Timer?
    private var pulseUp = true
    // The recording row. Lives ABOVE the dictation content in a taller panel,
    // so turning it on moves nothing that was already on screen.
    private let recDot = NSView()
    private let recLabel = NSTextField(labelWithString: "")
    private var recState: RecState = .idle
    private var recBlinkTimer: Timer?
    private var recBlinkOn = false
    private var dictationVisible = false
    private var spaceWatchdog: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Config.panelW, height: Config.panelH),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        // NO .stationary. An always-up bar that is ordered in ONCE can use it;
        // a panel ordered in and out on every take, like this one, uses
        // only these two. Copying the bar's flags onto the flash's lifecycle is the
        // mismatch this panel shipped with.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Pin dark. .hudWindow follows the effective appearance and blends what is
        // BEHIND the window, so over a bright page the panel washes out to near
        // white and the 0.92-alpha white text goes unreadable. The bug it fixes
        // reads as "it looks lighter, not darker" over a bright backdrop.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Never in a screen recording. The indicator is for you, not the capture.
        panel.sharingType = .none
        // It sits on the right edge where you click. It must never eat a click.
        panel.ignoresMouseEvents = true

        blur.frame = NSRect(x: 0, y: 0, width: Config.panelW, height: Config.panelH)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Config.radius
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        panel.contentView = blur

        // A dark scrim under the blur. The blur
        // alone is translucent, so a bright backdrop reads straight through it.
        // Added FIRST so every control below sits on top of it.
        tint.frame = NSRect(x: 0, y: 0, width: Config.panelW, height: Config.panelH)
        tint.wantsLayer = true
        tint.layer?.cornerRadius = Config.radius
        tint.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.42).cgColor
        blur.addSubview(tint)

        dot.frame = NSRect(x: 14, y: 55, width: 10, height: 10)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        blur.addSubview(dot)

        meter.frame = NSRect(x: 34, y: 47, width: 220, height: 26)
        blur.addSubview(meter)

        flash.frame = NSRect(x: 34, y: 49, width: 22, height: 22)
        flash.imageScaling = .scaleProportionallyUpOrDown
        flash.isHidden = true
        blur.addSubview(flash)

        primary.frame = NSRect(x: 14, y: 24, width: Config.panelW - 28, height: 18)
        primary.font = .systemFont(ofSize: 12)
        primary.textColor = NSColor.white.withAlphaComponent(0.92)
        primary.lineBreakMode = .byTruncatingHead
        primary.maximumNumberOfLines = 1
        blur.addSubview(primary)

        secondary.frame = NSRect(x: 14, y: 8, width: Config.panelW - 28, height: 14)
        secondary.font = .systemFont(ofSize: 9)
        secondary.textColor = NSColor.white.withAlphaComponent(0.45)
        secondary.lineBreakMode = .byTruncatingTail
        secondary.maximumNumberOfLines = 1
        blur.addSubview(secondary)

        // Positioned in the band that only exists when the panel is tall.
        recDot.frame = NSRect(x: 14, y: Config.panelH + 7, width: 10, height: 10)
        recDot.wantsLayer = true
        recDot.layer?.cornerRadius = 5
        recDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        recDot.isHidden = true
        blur.addSubview(recDot)

        recLabel.frame = NSRect(x: 34, y: Config.panelH + 5, width: Config.panelW - 48, height: 14)
        recLabel.font = .systemFont(ofSize: 10, weight: .medium)
        recLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        recLabel.lineBreakMode = .byTruncatingTail
        recLabel.maximumNumberOfLines = 1
        recLabel.isHidden = true
        blur.addSubview(recLabel)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reframe() }

        // A three-finger swipe between Spaces is the case this panel got wrong for
        // longest, and reframe() alone does NOT fix it. See reassertAfterSpaceChange.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reassertAfterSpaceChange() }

        reframe()
    }

    /// Right screen edge, vertically centerd. Recomputed on every show because a
    /// laptop that woke on a different display keeps a stale frame otherwise.
    /// The screen is the one holding the mouse, not NSScreen.main: for a
    /// background app main falls back to the primary display, which pinned the
    /// panel to one monitor while you worked on another.
    func reframe() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let f = screen.visibleFrame
        let h = recVisible ? Config.panelH + Config.recRowH : Config.panelH
        let x = f.maxX - Config.panelW - Config.margin
        let y = f.midY - h / 2
        panel.setFrame(NSRect(x: x, y: y, width: Config.panelW, height: h), display: true)
        blur.frame = NSRect(x: 0, y: 0, width: Config.panelW, height: h)
        tint.frame = blur.frame
    }

    /// A Space switch CARRIES this panel away with the outgoing desktop.
    ///
    /// Measured 2026-08-04 with CGWindowList against the live app: on a 2056pt
    /// screen the panel slid from x=1778 to x=-339 (entirely off the left edge) at
    /// alpha 0.01 during a three-finger swipe, and afterwards reported "not on the
    /// active space" while the foreground app was a full-screen terminal, mid-dictation.
    ///
    /// `.canJoinAllSpaces` gets it ONTO a new Space but does not survive the
    /// transition, because the panel is ordered in ONCE per dictation and never
    /// re-asserts. A probe whose panels re-ordered every 4s could not reproduce
    /// this, which is exactly why the earlier NSScreen.main fix changed nothing.
    ///
    /// So re-order it front AFTER the swipe. Twice, because the window server is
    /// still animating when the notification fires and a single immediate
    /// re-assert gets overwritten by the tail of that animation.
    ///
    /// To re-check: run the watcher in this repo's notes and swipe mid-dictation;
    /// x must return to (screen.maxX - panelW - margin) on every desktop.
    private func reassertAfterSpaceChange() {
        render()
        for delay in [0.25, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.dictationVisible || self.recVisible else { return }
                self.reframe()
                self.panel.orderFrontRegardless()
            }
        }
    }

    /// SELF-HEAL, because the mechanism is not understood.
    ///
    /// 2026-08-04: reported in the wild as the panel not reaching the desktop being
    /// swiped to. Four probes failed to reproduce it, INCLUDING one running the exact
    /// shipped recipe (.stationary + ordered-in-once) across four verified swipes into
    /// full-screen apps. The only real sighting is the live app at 13:46:42 reporting
    /// off-space mid-dictation. Hence a watchdog rather than a fix.
    ///
    /// Rather than ship a fix for a mechanism nobody has pinned down, assert the
    /// INVARIANT continuously: while the panel is meant to be on screen, it is on
    /// the active Space. Cheap (a 0.5s tick that no-ops), and it cannot be wrong,
    /// because being off-space while visible is never a state we want.
    ///
    /// It LOGS every catch. If the log stays empty the bug is elsewhere and this
    /// costs nothing; if it fills up, we finally have the ground truth four probes
    /// could not get.
    private func startSpaceWatchdog() {
        guard spaceWatchdog == nil else { return }
        spaceWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.dictationVisible || self.recVisible else { return }
            guard !self.panel.isOnActiveSpace else { return }
            Self.logCatch(self.panel.frame)
            self.reframe()
            self.panel.orderFrontRegardless()
        }
    }

    private func stopSpaceWatchdog() {
        spaceWatchdog?.invalidate()
        spaceWatchdog = nil
    }

    /// Append-only, so a catch survives the session that saw it.
    private static func logCatch(_ frame: NSRect) {
        Paths.ensureSupportDir()
        let path = Paths.panelLog
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let line = "\(f.string(from: Date()))  off-space while visible, front=\(front), frame=\(NSStringFromRect(frame))\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: path) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: path)
        }
    }

    /// True whenever the recording row has something to say. The KILLED case
    /// keeps it true even though nothing is recording, because that is the alarm.
    private var recVisible: Bool {
        if case .idle = recState { return false }
        return true
    }

    func pushLevel(_ v: Float) { meter.push(v) }

    /// The recording half. Independent of the dictation state machine on purpose:
    /// you can be recording while not dictating, and dictating while not recording.
    func applyRecording(_ s: RecState) {
        recState = s
        recBlinkTimer?.invalidate(); recBlinkTimer = nil
        recDot.isHidden = !recVisible
        recLabel.isHidden = !recVisible

        switch s {
        case .idle:
            break
        case .live(let since):
            recDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            recDot.alphaValue = 1
            recLabel.textColor = NSColor.white.withAlphaComponent(0.85)
            recLabel.stringValue = "RECORDING  " + Self.clock(since)
            // A slow steady pulse reads as alive. Steady-on reads as a decal.
            recBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.recBlinkOn.toggle()
                self.recDot.alphaValue = self.recBlinkOn ? 0.45 : 1
                if case .live(let s0) = self.recState {
                    self.recLabel.stringValue = "RECORDING  " + Self.clock(s0)
                }
            }
        case .paused:
            recDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            recDot.alphaValue = 1
            recLabel.textColor = NSColor.white.withAlphaComponent(0.85)
            recLabel.stringValue = "PAUSED"
        case .killed(let app):
            // HARD blink, not a pulse. This is the one you must not miss.
            recDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            recLabel.textColor = NSColor.systemRed
            recLabel.stringValue = "NOT RECORDING - \(app) opened"
            recBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.recBlinkOn.toggle()
                self.recDot.alphaValue = self.recBlinkOn ? 0.05 : 1
                self.recLabel.alphaValue = self.recBlinkOn ? 0.25 : 1
            }
        }
        reframe()
        render()
    }

    private static func clock(_ since: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(since)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// One place decides whether the panel is on screen: it shows if dictation
    /// wants it OR the optional recording row has something to say. Two independent
    /// reasons, one visibility decision, so neither can hide the other.
    private func render() {
        if dictationVisible || recVisible {
            reframe()
            panel.orderFrontRegardless()
            startSpaceWatchdog()
        } else {
            stopSpaceWatchdog()
            panel.orderOut(nil)
        }
    }

    /// The only mutator. Every visual difference between states lives here so
    /// there is exactly one place to read when the panel looks wrong.
    func apply(_ state: IndicatorState) {
        switch state {
        case .hidden:
            stopPulse()
            dictationVisible = false
            render()
            return

        case .listening(let device):
            showMeter(tint: .systemRed)
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            if primary.stringValue.isEmpty || isStatusText(primary.stringValue) {
                primary.stringValue = "Listening"
            }
            secondary.stringValue = device
            startPulse()

        case .noSignal(let device):
            showMeter(tint: .systemOrange)
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            dot.alphaValue = 1
            stopPulse()
            primary.stringValue = "no signal from \(device)"
            secondary.stringValue = "check System Settings, Sound, Input"

        case .thinking:
            stopPulse()
            meter.freeze()
            meter.isHidden = false
            flash.isHidden = true
            dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            dot.alphaValue = 1
            primary.stringValue = "Transcribing"
            secondary.stringValue = ""

        case .pasted(let preview):
            showGlyph(Glyph.check(22, .systemGreen), dotColor: .systemGreen)
            primary.stringValue = preview
            secondary.stringValue = "pasted"

        case .copied(let preview):
            showGlyph(Glyph.clipboard(22, .systemOrange), dotColor: .systemOrange)
            primary.stringValue = "Copied. Press Cmd V"
            secondary.stringValue = preview

        case .cancelled:
            showGlyph(Glyph.micOff(22, .systemGray), dotColor: .systemGray)
            primary.stringValue = "Cancelled"
            secondary.stringValue = ""

        case .blocked(let reason):
            showGlyph(Glyph.alert(22, .systemRed), dotColor: .systemRed)
            primary.stringValue = reason
            secondary.stringValue = "menubar glyph has the fix"
        }

        // Every case that reaches here is one the dictation half wants on screen.
        dictationVisible = true
        reframe()
        // Never makeKeyAndOrderFront. The frontmost app must keep focus or the
        // synthetic Cmd+V lands in the wrong window.
        panel.orderFrontRegardless()
        startSpaceWatchdog()
    }

    func resetText() {
        primary.stringValue = ""
        secondary.stringValue = ""
        meter.clear()
    }

    /// Show the streaming words. Tail-limited so a long ramble keeps the newest
    /// text on screen instead of scrolling the start.
    func setTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        primary.stringValue = trimmed.isEmpty ? "Listening" : String(trimmed.suffix(90))
    }

    private func isStatusText(_ s: String) -> Bool {
        s == "Listening" || s == "Transcribing" || s == "Cancelled" || s.hasPrefix("no signal from ")
    }

    private func showMeter(tint: NSColor) {
        flash.isHidden = true
        meter.isHidden = false
        meter.tint = tint
    }

    private func showGlyph(_ image: NSImage, dotColor: NSColor) {
        stopPulse()
        meter.isHidden = true
        flash.image = image
        flash.isHidden = false
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.alphaValue = 1
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseUp = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulseUp.toggle()
            self.dot.animator().alphaValue = self.pulseUp ? 1.0 : 0.6
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        dot.alphaValue = 1
    }
}

// ============================================================================
// MARK: - Controller
//
// The state machine. Everything here runs on main except the audio callbacks,
// which do one thing only: write a float under a lock.
// ============================================================================

// ============================================================================
// Disfluency: stutters come out BEFORE the glossary corrector sees the text.
//
// Measured over a real 1,797-take corpus (2026-08-18): 196 fillers (um/uh/hmm),
// 91 doubled words, 57 doubled bigrams, 29 sentence restarts. About 1 take in 5.
// Apple's transcriber has no disfluency option, so this is ours. Deterministic
// only: no fuzzy matching and no model call, the same laws the corrector lives
// under. The delivered text is cleaned; History keeps the raw string beside it
// so the audit can still see what the recognizer heard.
//
// THE HAZARD, and why rule 4 is deliberately narrow: "that that", "had had",
// "very very" and the "what it is is" shape are legitimate English. A repeat
// collapses only for contractions ("let's let's" is never real) and a short
// measured safe list. Widening that list is a decision, not a cleanup.
// ============================================================================
enum Disfluency {
    static let offKey = "disfluencyOff"
    static var isOn: Bool { !UserDefaults.standard.bool(forKey: offKey) }

    /// Words that are safe to collapse when doubled. Measured from the corpus;
    /// every entry is a function word actually observed stuttered in the corpus. "is" is
    /// deliberately absent: "what it is is a problem" is real English, and the
    /// pseudo-cleft cannot be told from the stutter without parsing.
    private static let safeDoubles: Set<String> = [
        "the", "and", "it", "to", "this", "a", "of", "in",
        "i", "you", "we", "so", "yeah",
    ]

    /// Lowercase letters and apostrophes only, so "We'll," == "we'll" and the
    /// recognizer's typographic apostrophe compares equal to the ASCII one.
    private static func core(_ token: some StringProtocol) -> String {
        String(token.lowercased().map { $0 == "\u{2019}" ? "'" : $0 }
            .filter { $0.isLetter || $0 == "'" })
    }

    private static func isFiller(_ c: String) -> Bool {
        guard !c.isEmpty else { return false }
        // um/umm..., uh/uhh..., hm/hmm..., erm. NOT him, huh.
        return c.range(of: "^(u+m+|u+h+|h+m+|erm+)$", options: .regularExpression) != nil
    }

    static func clean(_ text: String) -> String {
        guard isOn, !text.isEmpty else { return text }
        var s = stripFillers(text)
        s = collapseRestarts(s)
        var tokens = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        collapseBigrams(&tokens)
        collapseDoubles(&tokens)
        return tokens.joined(separator: " ")
    }

    /// Rule 1: drop standalone um/uh/hmm tokens. If a sentence-initial filler
    /// carried the capital ("Um, let me"), the capital moves to the next word.
    private static func stripFillers(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < tokens.count {
            if isFiller(core(tokens[i])) {
                let hadCapital = tokens[i].first?.isUppercase == true
                tokens.remove(at: i)
                if hadCapital, i < tokens.count, tokens[i].first?.isLowercase == true {
                    tokens[i] = tokens[i].prefix(1).uppercased() + tokens[i].dropFirst()
                }
            } else {
                i += 1
            }
        }
        return tokens.joined(separator: " ")
    }

    /// Rule 2: "So it's still not. So it's still not letting me." -> keep the
    /// finished sentence. A fragment of 3+ words that is a strict word-prefix
    /// of the NEXT fragment is a restart, not a sentence.
    private static func collapseRestarts(_ text: String) -> String {
        // Split into fragments, remembering each fragment's trailing separator.
        var frags: [(body: String, sep: String)] = []
        var body = "", sep = ""
        for ch in text {
            if ".?!,".contains(ch) || (!sep.isEmpty && ch == " ") {
                sep.append(ch)
            } else {
                if !sep.isEmpty { frags.append((body, sep)); body = ""; sep = "" }
                body.append(ch)
            }
        }
        frags.append((body, sep))

        var out: [(body: String, sep: String)] = []
        for frag in frags {
            if let prev = out.last {
                let a = prev.body.split(separator: " ").map { core($0) }.filter { !$0.isEmpty }
                let b = frag.body.split(separator: " ").map { core($0) }.filter { !$0.isEmpty }
                if a.count >= 3, b.count > a.count, Array(b.prefix(a.count)) == a {
                    out.removeLast()
                }
            }
            out.append(frag)
        }
        return out.map { $0.body + $0.sep }.joined()
    }

    /// Rule 3: "maybe that maybe that" -> "maybe that". A repeated word PAIR is
    /// essentially never legitimate dictation, so no safe list here.
    private static func collapseBigrams(_ tokens: inout [String]) {
        var i = 0
        while i + 3 < tokens.count {
            let a = core(tokens[i]), b = core(tokens[i + 1])
            if !a.isEmpty, !b.isEmpty, a == core(tokens[i + 2]), b == core(tokens[i + 3]) {
                let hadCapital = tokens[i].first?.isUppercase == true
                tokens.removeSubrange(i...(i + 1))
                if hadCapital, tokens[i].first?.isLowercase == true {
                    tokens[i] = tokens[i].prefix(1).uppercased() + tokens[i].dropFirst()
                }
            } else {
                i += 1
            }
        }
    }

    /// Rule 4, the narrow one: "let's let's" -> "let's" (any contraction), and
    /// doubled words from the safe list only. "that that" / "had had" survive.
    private static func collapseDoubles(_ tokens: inout [String]) {
        var i = 0
        while i + 1 < tokens.count {
            let c = core(tokens[i])
            if !c.isEmpty, c == core(tokens[i + 1]), c.contains("'") || safeDoubles.contains(c) {
                let hadCapital = tokens[i].first?.isUppercase == true
                tokens.remove(at: i)
                if hadCapital, tokens[i].first?.isLowercase == true {
                    tokens[i] = tokens[i].prefix(1).uppercased() + tokens[i].dropFirst()
                }
            } else {
                i += 1
            }
        }
    }
}

/// Every finished transcript, appended to one JSONL file, forever.
///
/// A transcript costs a few hundred bytes, so there is no reason to cap it. Append
/// only, one line per dictation, so a crash mid-write costs at most the current line
/// and never the file.
///
/// It never leaves this machine. Nothing in this app makes a network call.
/// Read it back with:
///   tail -5 "$HOME/Library/Application Support/dictation/history.jsonl"
enum History {
    static let path = Paths.history

    static func append(_ text: String, ms: Int, raw: String? = nil) {
        var row: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "ms": ms,
            "words": text.split(whereSeparator: { $0.isWhitespace }).count,
            "text": text,
        ]
        // What the recognizer heard, kept only when the cleaner or corrector
        // changed it: the audit needs the raw string, and identical copies
        // would double the file for nothing.
        if let raw, raw != text { row["raw"] = raw }
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let fh = try? FileHandle(forWritingTo: path) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: path)
        }
    }

    /// The most recent transcript, for the menubar "Copy last transcript" recovery path.
    static func last() -> String? {
        recent(1).first?.text
    }

    struct Entry {
        let at: Date?
        let text: String
        let words: Int
    }

    /// The newest `n` transcripts, newest first, for the menubar History submenu.
    /// Reads the whole file each open: the file is a few hundred bytes per take
    /// and the menu opens a handful of times a day, so streaming it is not worth
    /// the code.
    static func recent(_ n: Int) -> [Entry] {
        guard n > 0, let blob = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        var out: [Entry] = []
        for line in blob.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = o["text"] as? String, !t.isEmpty else { continue }
            let at = (o["at"] as? String).flatMap { iso.date(from: $0) }
            let words = o["words"] as? Int
                ?? t.split(whereSeparator: { $0.isWhitespace }).count
            out.append(Entry(at: at, text: t, words: words))
            if out.count == n { break }
        }
        return out
    }
}

final class Controller: @unchecked Sendable {
    private let transcriber = AppleTranscriber(locale: Config.locale, contextualStrings: Config.terms)
    private let capture = AudioCapture()
    /// Display only. rec owns recording, skhd owns the hotkeys.
    private let recWatch = RecordingWatch()
    private var corrector = GlossaryCorrector.loadMerged()
    private let indicator = Indicator()

    // The audio thread writes here and nowhere else. No UI work, no allocation,
    // no dispatch per callback: the tap fires every 23 ms and a redraw driven
    // straight off it would strobe and steal from the render thread.
    private let levelBox = OSAllocatedUnfairLock(initialState: Float(0))

    private var uiTimer: Timer?
    private var flashTimer: Timer?
    private var recheckTimer: Timer?
    private var monitors: [Any] = []

    private(set) var isListening = false
    /// TRUE between stop() and finish(). stop() clears isListening immediately but the
    /// transcript arrives asynchronously, so without this a tap during that window read
    /// as "not listening" and called start(), which destroyed the in-flight result. That
    /// was a real reported loss: "whenever I hit it twice, then it copies nothing and
    /// then I lose it."
    private(set) var isFinishing = false
    /// HOLD to talk. DOUBLE TAP to latch hands-free.
    /// Latched means a release does NOT stop; only another tap does.
    private var latched = false
    private var pendingStop: Timer?
    private var startedAt = Date()
    private var peak: Float = 0
    private var showingNoSignal = false

    private(set) var micOK = false
    private(set) var axOK = false
    private(set) var fnOK = false
    private(set) var lastMs = 0
    private(set) var lastWords = 0

    var deviceName: String { capture.deviceName }
    var onStatusChange: (() -> Void)?

    // ------------------------------------------------------------------
    // Bootstrap
    // ------------------------------------------------------------------

    @MainActor
    func bootstrap() async {
        Cue.load()

        // Mic permission FIRST. Touching engine.inputNode before the grant
        // yields a zero-channel format and poisons the engine for the session.
        micOK = await AVCaptureDevice.requestAccess(for: .audio)

        axOK = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        fnOK = fnSettingIsDoNothing()

        // 0.44 s, models already on disk. It also RESERVES one of five locale
        // slots, so it happens exactly once, at launch, never on a keypress.
        try? await transcriber.prepare()

        installMonitors()
        // Survive a reboot. Ad-hoc signed apps sometimes refuse this; it is not
        // worth failing the launch over.
        try? SMAppService.mainApp.register()

        applyGateState()
        startRecheckTimer()
        // The OPTIONAL recording half. See RecState: with no ~/.recording.lock and no
        // ~/.recording.state on disk this stays permanently idle and draws nothing.
        recWatch.onChange = { [weak self] s in
            guard let self else { return }
            DispatchQueue.main.async { self.indicator.applyRecording(s) }
        }
        recWatch.start()

        if ProcessInfo.processInfo.environment["DICTATION_DEMO"] == "1" { startDemo() }
    }

    /// The fn key only reaches an app when the system is not consuming it.
    /// Expected value is 0 (Do Nothing). Anything else and macOS eats the key first.
    private func fnSettingIsDoNothing() -> Bool {
        guard let d = UserDefaults(suiteName: "com.apple.HIToolbox") else { return true }
        return d.object(forKey: "AppleFnUsageType") == nil || d.integer(forKey: "AppleFnUsageType") == 0
    }

    /// The one place that decides whether the app is usable, and says why not.
    /// Ordered by which failure makes the others irrelevant.
    private func applyGateState() {
        guard !isListening else { return }
        if !micOK {
            indicator.apply(.blocked(reason: "Microphone denied. Menubar has the settings link."))
        } else if !axOK {
            indicator.apply(.blocked(reason: "Accessibility not granted. fn will not work."))
        } else if !fnOK {
            indicator.apply(.blocked(reason: "Set Keyboard, Press globe key to, Do Nothing"))
        } else {
            indicator.apply(.hidden)
        }
        onStatusChange?()
    }

    /// The app reads its TCC grants at launch, so without this the blocked card
    /// sits on screen forever AFTER the grant is given, which trains you to ignore
    /// the card. That cost a confused ten minutes once, which is why it re-checks.
    /// (build.sh now signs with a stable identity, so grants SURVIVE rebuilds.)
    private func startRecheckTimer() {
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, !self.isListening else { return }
            let ax = AXIsProcessTrusted()
            let fn = self.fnSettingIsDoNothing()
            guard ax != self.axOK || fn != self.fnOK else { return }
            self.axOK = ax
            self.fnOK = fn
            self.applyGateState()
        }
    }

    var isBlocked: Bool { !(micOK && axOK && fnOK) }

    // ------------------------------------------------------------------
    // Hotkeys
    // ------------------------------------------------------------------

    private func installMonitors() {
        // BOTH monitors. The global one is silent while our own process is
        // frontmost, which happens the moment anything of ours takes focus.
        // Parenthesized, not trailing: a trailing closure after `if let` reads
        // as the body of the if to both the compiler and a human.
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown],
            handler: { [weak self] e in self?.handle(e) })
        if let global { monitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown],
            handler: { [weak self] e in
                self?.handle(e)
                return e
            })
        if let local { monitors.append(local) }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .flagsChanged:
            // Gate on the KEYCODE, not the flag alone. Arrow keys and the F row
            // also carry .function in modifierFlags; only keyCode 63 means the
            // fn key itself moved. The matching UP event has the flag cleared,
            // which is how a tap stays a single toggle.
            guard e.keyCode == Config.vkFunction else { return }
            e.modifierFlags.contains(.function) ? fnDown() : fnUp()
        case .keyDown:
            guard e.keyCode == Config.vkEscape, isListening else { return }
            cancel()
        default:
            return
        }
    }

    // ------------------------------------------------------------------
    // The cycle
    // ------------------------------------------------------------------

    /// A tap while the transcript is still coming back is IGNORED, never a new start.
    /// Dropping the tap costs him one keypress; starting over costs him the sentence.
    func toggle() {
        guard !isFinishing else { return }
        isListening ? stop() : start()
    }

    /// fn PRESSED.
    /// - a press while latched and listening ENDS the hands-free take
    /// - a press that arrives while a release is still pending is the second half
    ///   of a DOUBLE TAP, so cancel the stop and latch instead
    /// - otherwise begin an ordinary hold-to-talk take
    private func fnDown() {
        guard !isFinishing else { return }
        if latched && isListening {
            latched = false
            stop()
            return
        }
        if let pending = pendingStop {
            pending.invalidate()
            pendingStop = nil
            latched = true          // second tap inside the window: stay listening
            indicator.apply(.listening(device: capture.deviceName))
            return
        }
        if !isListening { start() }
    }

    /// fn RELEASED. A latched take ignores this entirely. An ordinary take schedules
    /// its stop, so a second press can still arrive and turn it into a double tap.
    private func fnUp() {
        guard isListening, !latched else { return }
        pendingStop?.invalidate()
        pendingStop = Timer.scheduledTimer(withTimeInterval: Config.doubleTapWindow,
                                           repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pendingStop = nil
            guard self.isListening, !self.latched else { return }
            self.stop()
        }
    }

    func start() {
        guard micOK, !isListening else { return }
        guard let fmt = transcriber.requiredFormat else {
            indicator.apply(.blocked(reason: "Speech model did not load. Quit and relaunch."))
            return
        }

        flashTimer?.invalidate()
        isListening = true
        peak = 0
        showingNoSignal = false
        startedAt = Date()
        levelBox.withLock { $0 = 0 }

        Cue.playStart()
        indicator.resetText()
        indicator.apply(.listening(device: capture.deviceName))

        capture.onLevel = { [weak self] v in self?.levelBox.withLock { $0 = v } }
        capture.onBuffer = { [weak transcriber] b in transcriber?.feed(b) }
        capture.onConfigChange = { [weak self] in
            // AirPods connected mid sentence. Rebuild against the new hardware
            // format in place rather than losing the session.
            guard let self else { return }
            try? self.capture.rebuildTap(targetFormat: fmt)
        }

        uiTimer = Timer.scheduledTimer(withTimeInterval: Config.uiHz, repeats: true) { [weak self] _ in
            self?.tickUI()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriber.begin { st in
                    DispatchQueue.main.async { self.onText(st) }
                }
                try self.capture.start(targetFormat: fmt)
            } catch {
                await MainActor.run {
                    self.isListening = false
                    self.uiTimer?.invalidate()
                    self.indicator.apply(.blocked(reason: "Could not open the microphone."))
                }
            }
        }
        onStatusChange?()
    }

    private func tickUI() {
        let v = levelBox.withLock { $0 }
        indicator.pushLevel(v)
        peak = max(peak, v)
        let elapsed = Date().timeIntervalSince(startedAt)
        if v >= Config.noSignalPeak {
            if showingNoSignal {
                showingNoSignal = false
                indicator.apply(.listening(device: capture.deviceName))
            }
        } else if !showingNoSignal, elapsed > Config.noSignalAfter, peak < Config.noSignalPeak {
            showingNoSignal = true
            indicator.apply(.noSignal(device: capture.deviceName))
        }
    }

    /// Display only. Do NOT assume the final is better than the volatile: the
    /// measured behavior is that the final pass re-splits a compound proper noun
    /// back into two words. Repairing that is the corrector's job, not the panel's.
    private func onText(_ st: TranscriptState) {
        guard isListening, !showingNoSignal else { return }
        indicator.setTranscript(st.full)
    }

    /// The caret this take is aimed at, read at RELEASE and carried to the finish.
    ///
    /// This is the whole "it lands where your cursor was" guarantee. Delivery
    /// happens a few hundred milliseconds later, once the recognizer's final
    /// pass returns, and by then focus may be somewhere else entirely. Resolving
    /// the target THEN instead of now is what used to send takes into the wrong
    /// window. See TextTarget.
    private var takeTarget: TextTarget?

    func stop() {
        guard isListening else { return }
        // FIRST LINE OF stop(), deliberately. Every frame that passes between
        // the key coming up and this read is a frame in which focus can move.
        takeTarget = TextTarget.capture()
        isListening = false
        isFinishing = true
        latched = false
        pendingStop?.invalidate(); pendingStop = nil
        uiTimer?.invalidate()
        uiTimer = nil
        capture.stop()
        Cue.playStop()
        indicator.apply(.thinking)
        onStatusChange?()

        Task { [weak self] in
            guard let self else { return }
            let t0 = Date()
            let raw = (try? await self.transcriber.end()) ?? ""
            // Stutters out first, then the glossary: a repeated garble collapses
            // to one instance before the corrector spends a pass on it.
            let text = self.corrector.correct(Disfluency.clean(raw))
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            await MainActor.run { self.finish(text, raw: raw, ms: ms) }
        }
    }

    @MainActor
    private func finish(_ text: String, raw: String, ms: Int) {
        isFinishing = false
        lastMs = ms
        lastWords = text.split(whereSeparator: { $0.isWhitespace }).count
        onStatusChange?()

        guard !text.isEmpty else {
            indicator.apply(.blocked(reason: "Nothing was heard."))
            hide(after: 1.5)
            return
        }

        // WRITE HISTORY FIRST, before any delivery is attempted. Paste can fail
        // silently into an app that accepts nothing, and a failed paste is NOT
        // detectable. So the durable copy lands on disk before we gamble on the
        // keystroke, which makes every downstream failure recoverable instead of
        // permanent. Write first, deliver second.
        History.append(text, ms: ms, raw: raw)

        let preview = String(text.prefix(60))

        // Deliver to the caret captured at RELEASE, not to whatever is focused
        // now. See TextTarget for why those are different and why it matters.
        //
        // ADDING YOUR OWN DELIVERY TARGET goes here. This is the seam. Anything
        // that does not need an app to be focused (an HTTP endpoint, a file, a
        // socket) can be routed from here. Whatever you add, keep the pasteboard
        // as its floor and SAY on the panel which path the take took. Never
        // swallow a take, and never claim one landed when you do not know.
        let target = takeTarget
        takeTarget = nil

        switch Paster.deliver(text, to: target) {
        case .landed:
            indicator.apply(.pasted(preview: preview))
            hide(after: Config.flashPasted)
        case .clipboardOnly:
            indicator.apply(.copied(preview: preview))
            hide(after: Config.flashCopied)
        }
    }

    func cancel() {
        guard isListening else { return }
        isListening = false
        latched = false
        pendingStop?.invalidate(); pendingStop = nil
        uiTimer?.invalidate()
        uiTimer = nil
        capture.stop()
        Task { await transcriber.abort() }
        // No sound, no paste, no clipboard write. Cancel means nothing happened.
        indicator.apply(.cancelled)
        hide(after: 0.6)
        onStatusChange?()
    }

    private func hide(after seconds: TimeInterval) {
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, !self.isListening else { return }
            self.indicator.resetText()
            self.applyGateState()
        }
    }

    // ------------------------------------------------------------------
    // Demo mode, for verifying the panel without a microphone or a grant.
    // DICTATION_DEMO=1 open -a Dictation
    // ------------------------------------------------------------------

    private func startDemo() {
        indicator.apply(.listening(device: "demo signal"))
        indicator.setTranscript("demo mode, this is what the words look like as they land")
        var t: Double = 0
        Timer.scheduledTimer(withTimeInterval: Config.uiHz, repeats: true) { [weak self] _ in
            t += Config.uiHz
            let v = Float(0.5 + 0.5 * sin(t * 2 * Double.pi))
            self?.indicator.pushLevel(v)
        }
    }
}

// ============================================================================
// MARK: - AppDelegate
//
// Accessory app: no Dock tile, no window, a menubar glyph and the panel. The
// menu is the entire settable surface and it is deliberately tiny. Every row is
// either a fact you need when something is wrong, or the one fallback that
// works when fn does not.
// ============================================================================

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = Controller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Glyph.template(Glyph.mic(16, .labelColor))
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.onStatusChange = { [weak self] in self?.refreshGlyph() }

        Task { @MainActor in
            await controller.bootstrap()
            self.refreshGlyph()
        }
    }

    private func refreshGlyph() {
        let img: NSImage
        if controller.isBlocked {
            img = Glyph.micOff(16, .labelColor)
        } else {
            img = Glyph.mic(16, .labelColor)
        }
        statusItem.button?.image = Glyph.template(img)
        statusItem.button?.appearsDisabled = false
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        add(menu, controller.isListening ? "Listening" : "Idle", enabled: false)

        let toggle = NSMenuItem(title: controller.isListening ? "Stop Listening" : "Start Listening",
                                action: #selector(toggleListening), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        // Input picker: submenu of every input device, System Default on top.
        // Applies on the NEXT take (capture re-reads preferences at start).
        let micPick = NSMenuItem(title: "Microphone: \(controller.deviceName)", action: nil, keyEquivalent: "")
        let micSub = NSMenu()
        let chosen = UserDefaults.standard.string(forKey: AudioCapture.deviceKey)
        let defItem = NSMenuItem(title: "System Default", action: #selector(pickDevice(_:)), keyEquivalent: "")
        defItem.target = self
        defItem.state = (chosen == nil || chosen!.isEmpty) ? .on : .off
        micSub.addItem(defItem)
        micSub.addItem(.separator())
        for d in AudioCapture.inputDevices() {
            let it = NSMenuItem(title: d.name, action: #selector(pickDevice(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.name
            it.state = chosen == d.name ? .on : .off
            micSub.addItem(it)
        }
        micPick.submenu = micSub
        menu.addItem(micPick)

        // Boost for quiet mics (the RODE over USB runs ~20 dB low by design).
        let curBoost = UserDefaults.standard.double(forKey: AudioCapture.boostKey)
        let boostPick = NSMenuItem(title: "Input Boost: \(curBoost > 0 ? "+\(Int(curBoost)) dB" : "off")", action: nil, keyEquivalent: "")
        let boostSub = NSMenu()
        for (label, db) in [("Off", 0.0), ("+10 dB", 10.0), ("+20 dB (RODE over USB)", 20.0)] {
            let it = NSMenuItem(title: label, action: #selector(pickBoost(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = db
            it.state = curBoost == db ? .on : .off
            boostSub.addItem(it)
        }
        boostPick.submenu = boostSub
        menu.addItem(boostPick)

        // The stutter cleaner's off switch. Default on; the state
        // lives in UserDefaults so it survives restarts and stays scriptable.
        let stut = NSMenuItem(title: "Clean Stutters",
                              action: #selector(toggleDisfluency), keyEquivalent: "")
        stut.target = self
        stut.state = Disfluency.isOn ? .on : .off
        menu.addItem(stut)

        if controller.micOK {
            add(menu, "Microphone access: granted", enabled: false)
        } else {
            let mic = NSMenuItem(title: "Microphone: NOT GRANTED, open Settings",
                                 action: #selector(openMicSettings), keyEquivalent: "")
            mic.target = self
            menu.addItem(mic)
        }

        if controller.axOK {
            add(menu, "Accessibility: granted", enabled: false)
        } else {
            let ax = NSMenuItem(title: "Accessibility: NOT GRANTED, open Settings",
                                action: #selector(openAXSettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }

        if !controller.fnOK {
            let fn = NSMenuItem(title: "Globe key is not set to Do Nothing, open Settings",
                                action: #selector(openKeyboardSettings), keyEquivalent: "")
            fn.target = self
            menu.addItem(fn)
        }

        // The latency tell. If transcription ever feels slow, this row says
        // whether it actually is, before anyone goes blaming Speech.framework.
        if controller.lastWords > 0 {
            add(menu, "Last: \(controller.lastWords) words in \(controller.lastMs) ms", enabled: false)
        }

        // The recovery path. A failed paste is not detectable, so the answer is not
        // detection, it is making the last transcript one click away, always.
        menu.addItem(.separator())
        let recover = NSMenuItem(title: "Copy Last Transcript",
                                 action: #selector(copyLastTranscript), keyEquivalent: "")
        recover.target = self
        recover.isEnabled = History.last() != nil
        menu.addItem(recover)

        // The full recovery path: recent takes, newest first, click to copy.
        // Previews are truncated for the menu; the row carries the FULL text
        // (representedObject), so what lands on the clipboard is the whole
        // dictation, and the tooltip shows it before the click.
        let historyRoot = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        let histSub = NSMenu()
        let entries = History.recent(20)
        if entries.isEmpty {
            add(histSub, "No dictations yet", enabled: false)
        } else {
            add(histSub, "Click a row to copy it", enabled: false)
            histSub.addItem(.separator())
            let time = DateFormatter()
            time.dateFormat = "h:mm a"
            let day = DateFormatter()
            day.dateFormat = "MMM d, h:mm a"
            for e in entries {
                var stamp = ""
                if let at = e.at {
                    stamp = Calendar.current.isDateInToday(at)
                        ? time.string(from: at) : day.string(from: at)
                }
                let it = NSMenuItem(title: "\(stamp.isEmpty ? "" : stamp + "  ")\(Self.preview(e.text))",
                                    action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = e.text
                it.toolTip = e.text
                histSub.addItem(it)
            }
        }
        historyRoot.submenu = histSub
        menu.addItem(historyRoot)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Dictation", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func copyLastTranscript() {
        guard let t = History.last() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    @objc private func copyHistoryEntry(_ item: NSMenuItem) {
        guard let t = item.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    /// One menu line's worth of a transcript: whitespace collapsed so a
    /// multi-line take stays one row, cut at a word boundary near 60 chars.
    private static func preview(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard oneLine.count > 60 else { return oneLine }
        let cut = oneLine.prefix(60)
        let trimmed = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return trimmed + "…"
    }

    @objc private func pickDevice(_ item: NSMenuItem) {
        if let name = item.representedObject as? String {
            UserDefaults.standard.set(name, forKey: AudioCapture.deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AudioCapture.deviceKey)
        }
    }

    @objc private func pickBoost(_ item: NSMenuItem) {
        UserDefaults.standard.set(item.representedObject as? Double ?? 0, forKey: AudioCapture.boostKey)
    }

    @objc private func toggleDisfluency() {
        UserDefaults.standard.set(Disfluency.isOn, forKey: Disfluency.offKey)
    }

    private func add(_ menu: NSMenu, _ title: String, enabled: Bool) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func toggleListening() { controller.toggle() }

    @objc private func openMicSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @objc private func openAXSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// ============================================================================
// MARK: - main
// ============================================================================

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
