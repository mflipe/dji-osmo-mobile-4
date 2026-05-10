import Foundation
import Combine

// MARK: - GimbalCheckup

/// End-to-end health checkup for the OM3 gimbal.
/// Runs a sequence of automatic and physical-interaction steps, collecting
/// pass/fail results and raw BLE frame captures for analysis.
@MainActor
final class GimbalCheckup: ObservableObject {

    // MARK: - Types

    enum StepKind {
        case automatic
        case physical(instruction: String, hint: String? = nil)
    }

    struct StepRecord: Identifiable {
        let id    = UUID()
        let index: Int
        let name:  String
        let kind:  StepKind
        var status:  Status  = .pending
        var passed:  Bool?   = nil
        var summary: String  = ""
        var details: [String] = []

        enum Status { case pending, running, waitingUser, done }
    }

    // MARK: - Published state

    @Published private(set) var steps:          [StepRecord] = []
    @Published private(set) var currentIndex:   Int          = 0
    @Published private(set) var isRunning:      Bool         = false
    @Published private(set) var isComplete:     Bool         = false
    @Published private(set) var capturedFrames: [String]     = []
    @Published private(set) var positionBefore: (pitch: Double, yaw: Double)? = nil

    // MARK: - Private

    private weak var ctl: GimbalController?
    private var physicalContinuation: CheckedContinuation<Void, Never>?
    private var frameCaptureCancellable: AnyCancellable?
    private var runTask: Task<Void, Never>?

    // MARK: - Init

    init(controller: GimbalController) {
        self.ctl = controller
        buildSteps()
    }

    // MARK: - Step definitions

    func buildSteps() {
        let defs: [(String, StepKind)] = [
            ("Setup Confirmation", .physical(
                instruction: "Confirm the gimbal is powered on, connected (green LED), and completely free of obstacles. The phone holder should be empty or with the phone securely installed.",
                hint: "The test will send movement commands across the full ±160° yaw and −90°/+45° pitch range. Battery should be > 20%."
            )),
            ("BLE Link Health",              .automatic),
            ("Telemetry Frequency",          .automatic),
            ("Pitch Accuracy — 5 points",    .automatic),
            ("Yaw Accuracy — 5 points",      .automatic),
            ("Diagonal Accuracy — 4 corners",.automatic),
            ("Hysteresis — Pitch",           .automatic),
            ("Hysteresis — Yaw",             .automatic),
            ("Speed Control — Pitch ↑↓",     .automatic),
            ("Speed Control — Yaw ←→",       .automatic),
            ("Mode Switch Round-trip",        .automatic),
            ("Return to Center",             .automatic),
            ("Physical: Trigger × 1", .physical(
                instruction: "Press the TRIGGER button ONCE on the gimbal handle, then tap Continue.",
                hint: "Monitoring all BLE frames that arrive. On OM3 physical buttons may be handled internally — capturing any cmd that appears."
            )),
            ("Physical: Trigger × 2 (recenter)", .physical(
                instruction: "Press the TRIGGER button TWICE quickly. Wait for the gimbal to re-center, then tap Continue.",
                hint: "Position before/after will be compared to verify recenter worked."
            )),
            ("Physical: M Button × 1", .physical(
                instruction: "Press the M button ONCE on the gimbal handle, then tap Continue.",
                hint: "Monitoring for mode or command-frame changes."
            )),
            ("Physical: Joystick ↑", .physical(
                instruction: "Push the physical joystick UP for ~3 seconds, then release and tap Continue.",
                hint: "Joystick reports arrive as cmd=0x57. The app should respond with setSpeed commands."
            )),
            ("Physical: Joystick ↓", .physical(
                instruction: "Push the physical joystick DOWN for ~3 seconds, then release and tap Continue.",
                hint: nil
            )),
            ("Physical: Joystick ←", .physical(
                instruction: "Push the physical joystick LEFT for ~3 seconds, then release and tap Continue.",
                hint: nil
            )),
            ("Physical: Joystick →", .physical(
                instruction: "Push the physical joystick RIGHT for ~3 seconds, then release and tap Continue.",
                hint: nil
            )),
            ("Physical: Zoom Slider T→W", .physical(
                instruction: "Move the zoom slider to T (top) for 2 seconds, then to W (bottom) for 2 seconds, then tap Continue.",
                hint: "Expected: no BLE frames (zoom is hardware-only on OM3). Any frames captured here are unexpected."
            )),
        ]
        steps = defs.enumerated().map { i, d in StepRecord(index: i, name: d.0, kind: d.1) }
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }
        buildSteps()
        currentIndex = 0
        isRunning    = true
        isComplete   = false
        ctl?.checkupLog("📋 Gimbal Checkup started — \(steps.count) steps")
        runTask = Task { await runAll() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        frameCaptureCancellable = nil
        physicalContinuation?.resume()
        physicalContinuation = nil
    }

    func continueFromPhysical() {
        physicalContinuation?.resume()
        physicalContinuation = nil
    }

    // MARK: - Execution loop

    // Steps that don't need a recenter before they run (either they manage position
    // themselves, or position is irrelevant to what they're measuring).
    private let skipRecenterSteps: Set<String> = [
        "Setup Confirmation",   // first physical step — user positions the device
        "BLE Link Health",      // checks connectivity, not position
        "Telemetry Frequency",  // counts updates over time, position irrelevant
        "Mode Switch Round-trip", // just sends mode commands, no position dependency
    ]

    private func runAll() async {
        let total = steps.count
        for i in steps.indices {
            guard !Task.isCancelled else {
                ctl?.checkupLog("⏹ Checkup cancelled at step \(i + 1)/\(total)")
                break
            }
            currentIndex    = i
            let stepLabel   = "[\(i + 1)/\(total)] \(steps[i].name)"

            // Return to center before every step that depends on a known start position.
            if !skipRecenterSteps.contains(steps[i].name), let ctl {
                steps[i].status  = .running
                steps[i].summary = "Recentering…"
                ctl.checkupLog("↻ \(stepLabel) — recentering…")
                await recenterAndWait(ctl: ctl)
            }

            steps[i].status  = .running
            steps[i].summary = ""

            switch steps[i].kind {
            case .automatic:
                ctl?.checkupLog("▶ \(stepLabel)")
                let r = await runAutomatic(index: i)
                steps[i].passed  = r.passed
                steps[i].summary = r.summary
                steps[i].details = r.details
                steps[i].status  = .done
                let icon = r.passed ? "✓" : "✗"
                ctl?.checkupLog("\(icon) \(stepLabel): \(r.summary)")

            case .physical:
                ctl?.checkupLog("👤 \(stepLabel) — waiting for user interaction")
                steps[i].status = .waitingUser
                capturedFrames  = []
                positionBefore  = ctl.map { ($0.pitch, $0.yaw) }
                startFrameCapture()
                await waitForUser()
                stopFrameCapture()

                let frames = capturedFrames
                let before = positionBefore
                let after  = ctl.map { ($0.pitch, $0.yaw) }
                let r = analyzePhysical(index: i, frames: frames, before: before, after: after)
                steps[i].passed  = r.passed
                steps[i].summary = r.summary
                steps[i].details = r.details
                steps[i].status  = .done
                let icon = (r.passed == true) ? "✓" : (r.passed == false ? "✗" : "•")
                ctl?.checkupLog("\(icon) \(stepLabel): \(r.summary) (\(frames.count) frames captured)")
            }
        }
        isRunning  = false
        isComplete = true
        let passed  = steps.filter { $0.passed == true  }.count
        let failed  = steps.filter { $0.passed == false }.count
        let skipped = steps.filter { $0.passed == nil   }.count
        ctl?.checkupLog("📋 Checkup complete — \(passed) passed  \(failed) failed  \(skipped) n/a")
    }

    private func recenterAndWait(ctl: GimbalController) async {
        // Pause and ask the user to manually recenter before the next test.
        // Once they tap Continue, wait 1s for the gimbal to settle.
        steps[currentIndex].status  = .waitingUser
        steps[currentIndex].summary = ""
        await waitForUser()
        steps[currentIndex].status  = .running
        ctl.checkupLog("↻ Manual recenter confirmed — waiting 1s to settle")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private func waitForUser() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            physicalContinuation = cont
        }
    }

    // MARK: - Frame capture

    private func startFrameCapture() {
        guard let ctl else { return }
        frameCaptureCancellable = ctl.frameEvents
            .sink { [weak self] frame in
                guard let self else { return }
                let hex  = frame.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                let line = String(format: "cmdSet=%02X cmd=%02X flags=%02X len=%d  [%@]",
                                  frame.cmdSet, frame.cmdId, frame.flags, frame.payload.count, hex)
                self.capturedFrames.append(line)
            }
    }

    private func stopFrameCapture() {
        frameCaptureCancellable = nil
    }

    // MARK: - Automatic step dispatcher

    private func runAutomatic(index: Int) async -> (passed: Bool, summary: String, details: [String]) {
        guard let ctl else { return (false, "Controller unavailable", []) }
        guard ctl.isReady else {
            return (false, "Gimbal not ready — skipped", ["connectionState: \(ctl.connectionState.label)"])
        }

        switch steps[index].name {
        case "BLE Link Health":              return await checkBLEHealth(ctl: ctl)
        case "Telemetry Frequency":          return await checkTelemetryFreq(ctl: ctl)
        case "Pitch Accuracy — 5 points":    return await checkPitchAccuracy(ctl: ctl)
        case "Yaw Accuracy — 5 points":      return await checkYawAccuracy(ctl: ctl)
        case "Diagonal Accuracy — 4 corners":return await checkDiagonalAccuracy(ctl: ctl)
        case "Hysteresis — Pitch":           return await checkHysteresisPitch(ctl: ctl)
        case "Hysteresis — Yaw":             return await checkHysteresisYaw(ctl: ctl)
        case "Speed Control — Pitch ↑↓":     return await checkSpeedPitch(ctl: ctl)
        case "Speed Control — Yaw ←→":       return await checkSpeedYaw(ctl: ctl)
        case "Mode Switch Round-trip":        return await checkModeSwitch(ctl: ctl)
        case "Return to Center":             return await checkReturnToCenter(ctl: ctl)
        default: return (false, "Unknown step", [])
        }
    }

    // MARK: - Automatic checks

    private func checkBLEHealth(ctl: GimbalController) async -> (Bool, String, [String]) {
        var details = [String]()
        var passed  = true

        let ready = ctl.isReady
        details.append("Connection: \(ctl.connectionState.label) → \(ready ? "✓" : "✗")")
        if !ready { passed = false }

        if let bat = ctl.battery {
            let warn = bat < 15
            details.append("Battery: \(bat)%  charging=\(ctl.isCharging) → \(warn ? "⚠️ LOW" : "✓")")
            if warn { passed = false }
        } else {
            details.append("Battery: no data received → ✗")
            passed = false
        }

        let sanePitch = abs(ctl.pitch) < 200
        let saneYaw   = abs(ctl.yaw)   < 400
        details.append(String(format: "Telemetry: P=%.1f° Y=%.1f° → %@",
                              ctl.pitch, ctl.yaw, (sanePitch && saneYaw) ? "✓" : "✗ (garbage value)"))
        if !sanePitch || !saneYaw { passed = false }

        details.append("yawBody: \(String(format: "%.1f", ctl.yawBody))° (heading-relative)")

        return (passed, passed ? "BLE link healthy" : "Issues detected — check details", details)
    }

    private func checkTelemetryFreq(ctl: GimbalController) async -> (Bool, String, [String]) {
        let histBefore = ctl.positionHistory.count
        let p0 = ctl.pitch
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let histAfter = ctl.positionHistory.count
        let p1 = ctl.pitch

        let changed = abs(p1 - p0) > 0.1 || histAfter > 0
        let newEntries = histAfter - histBefore          // may undercount due to ring-buffer eviction
        let freqNote = newEntries > 0
            ? "≥\(newEntries) updates in 4s (ring-buffer eviction may hide higher rates)"
            : "could not count — ring buffer at capacity or no updates"

        return (changed, "Position data: \(changed ? "flowing ✓" : "stalled ✗")", [
            "positionHistory before: \(histBefore)  after: \(histAfter)  Δ\(newEntries)",
            "P before: \(String(format: "%.1f", p0))°  P after: \(String(format: "%.1f", p1))°",
            "Frequency estimate: \(freqNote)",
            changed ? "✓ Telemetry is live" : "✗ No position updates — check BLE connection and cmd=0x05 / cmd=0x02 handling"
        ])
    }

    private func checkPitchAccuracy(ctl: GimbalController) async -> (Bool, String, [String]) {
        let targets: [(pitch: Double, yaw: Double)] = [(0, 0), (20, 0), (45, 0), (-45, 0), (-90, 0)]
        return await accuracyTest(ctl: ctl, targets: targets) { $0.pitch }
    }

    private func checkYawAccuracy(ctl: GimbalController) async -> (Bool, String, [String]) {
        let targets: [(pitch: Double, yaw: Double)] = [(0, 0), (0, 45), (0, -45), (0, 90), (0, -90)]
        return await accuracyTest(ctl: ctl, targets: targets) { $0.yaw }
    }

    private func checkDiagonalAccuracy(ctl: GimbalController) async -> (Bool, String, [String]) {
        let targets: [(pitch: Double, yaw: Double)] = [(30, 60), (-30, -60), (30, -60), (-30, 60)]
        var details = [String](); var allPassed = true

        for (p, y) in targets {
            ctl.setAngle(pitchDeg: p, yawDeg: y, durationSec: 2.5)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let rp = ctl.pitch, ry = ctl.yaw
            let ep = abs(rp - p), ey = abs(ry - y)
            let ok = ep < 3.0 && ey < 3.0
            if !ok { allPassed = false }
            details.append(String(format: "%@ Target P%+.0f° Y%+.0f°  Got P%+.1f° Y%+.1f°  ΔP=%.1f° ΔY=%.1f°",
                                  ok ? "✓" : "✗", p, y, rp, ry, ep, ey))
        }
        ctl.recenter(); try? await Task.sleep(nanoseconds: 2_500_000_000)
        return (allPassed, allPassed ? "All corners within ±3° ✓" : "Some corners out of tolerance ✗", details)
    }

    private func checkHysteresisPitch(ctl: GimbalController) async -> (Bool, String, [String]) {
        var details = [String]()
        let target  = 20.0

        ctl.setAngle(pitchDeg: -45, yawDeg: 0, durationSec: 2)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        ctl.setAngle(pitchDeg: target, yawDeg: 0, durationSec: 1.5)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        let fromBelow = ctl.pitch
        details.append(String(format: "Approach from below (−45°→+20°): got %.2f°", fromBelow))

        ctl.setAngle(pitchDeg: 45, yawDeg: 0, durationSec: 2)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        ctl.setAngle(pitchDeg: target, yawDeg: 0, durationSec: 1.5)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        let fromAbove = ctl.pitch
        details.append(String(format: "Approach from above (+45°→+20°): got %.2f°", fromAbove))

        let h = abs(fromAbove - fromBelow)
        details.append(String(format: "Hysteresis: %.2f°  threshold: 2°", h))
        let ok = h < 2.0
        ctl.recenter(); try? await Task.sleep(nanoseconds: 2_500_000_000)
        return (ok, String(format: "Pitch hysteresis %.2f° %@", h, ok ? "✓" : "✗"), details)
    }

    private func checkHysteresisYaw(ctl: GimbalController) async -> (Bool, String, [String]) {
        var details = [String]()
        let target  = 45.0

        ctl.setAngle(pitchDeg: 0, yawDeg: -90, durationSec: 2)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        ctl.setAngle(pitchDeg: 0, yawDeg: target, durationSec: 1.5)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        let fromLeft = ctl.yaw
        details.append(String(format: "Approach from left (−90°→+45°): got %.2f°", fromLeft))

        ctl.setAngle(pitchDeg: 0, yawDeg: 90, durationSec: 2)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        ctl.setAngle(pitchDeg: 0, yawDeg: target, durationSec: 1.5)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        let fromRight = ctl.yaw
        details.append(String(format: "Approach from right (+90°→+45°): got %.2f°", fromRight))

        let h = abs(fromRight - fromLeft)
        details.append(String(format: "Hysteresis: %.2f°  threshold: 2°", h))
        let ok = h < 2.0
        ctl.recenter(); try? await Task.sleep(nanoseconds: 2_500_000_000)
        return (ok, String(format: "Yaw hysteresis %.2f° %@", h, ok ? "✓" : "✗"), details)
    }

    private func checkSpeedPitch(ctl: GimbalController) async -> (Bool, String, [String]) {
        ctl.setAngle(pitchDeg: 0, yawDeg: 0, durationSec: 1.5)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        var details = [String](); var passed = true

        let p0 = ctl.pitch
        ctl.checkupLog(String(format: "  Pitch speed ↑: start P=%.1f°, sending 35°/s for 1.5s", p0))
        ctl.setSpeed(pitchDeg: 35, yawDeg: 0)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        ctl.stopMotion()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let p1 = ctl.pitch
        let up = abs(p1 - p0)
        let upOk = up > 8
        if !upOk { passed = false }
        ctl.checkupLog(String(format: "  Pitch ↑ result: %.1f°→%.1f° (Δ%.1f°) %@", p0, p1, up, upOk ? "✓" : "✗ <8°"))
        details.append(String(format: "%@ Up 35°/s × 1.5s: %.1f°→%.1f° (moved %.1f°)", upOk ? "✓" : "✗", p0, p1, up))

        let p2 = ctl.pitch
        ctl.checkupLog(String(format: "  Pitch speed ↓: start P=%.1f°, sending −35°/s for 1.5s", p2))
        ctl.setSpeed(pitchDeg: -35, yawDeg: 0)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        ctl.stopMotion()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let p3 = ctl.pitch
        let dn = abs(p3 - p2)
        let dnOk = dn > 8
        if !dnOk { passed = false }
        ctl.checkupLog(String(format: "  Pitch ↓ result: %.1f°→%.1f° (Δ%.1f°) %@", p2, p3, dn, dnOk ? "✓" : "✗ <8°"))
        details.append(String(format: "%@ Down −35°/s × 1.5s: %.1f°→%.1f° (moved %.1f°)", dnOk ? "✓" : "✗", p2, p3, dn))

        ctl.recenter(); try? await Task.sleep(nanoseconds: 2_000_000_000)
        return (passed, String(format: "Pitch speed: up %.0f°  down %.0f° %@", up, dn, passed ? "✓" : "✗"), details)
    }

    private func checkSpeedYaw(ctl: GimbalController) async -> (Bool, String, [String]) {
        ctl.setAngle(pitchDeg: 0, yawDeg: 0, durationSec: 1.5)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        var details = [String](); var passed = true

        let y0 = ctl.yaw
        ctl.checkupLog(String(format: "  Yaw speed →: start Y=%.1f°, sending 35°/s for 1.5s", y0))
        ctl.setSpeed(pitchDeg: 0, yawDeg: 35)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        ctl.stopMotion()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let y1 = ctl.yaw
        let rt = abs(y1 - y0)
        let rtOk = rt > 8
        if !rtOk { passed = false }
        ctl.checkupLog(String(format: "  Yaw → result: %.1f°→%.1f° (Δ%.1f°) %@", y0, y1, rt, rtOk ? "✓" : "✗ <8°"))
        details.append(String(format: "%@ Right 35°/s × 1.5s: %.1f°→%.1f° (moved %.1f°)", rtOk ? "✓" : "✗", y0, y1, rt))

        let y2 = ctl.yaw
        ctl.checkupLog(String(format: "  Yaw speed ←: start Y=%.1f°, sending −35°/s for 1.5s", y2))
        ctl.setSpeed(pitchDeg: 0, yawDeg: -35)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        ctl.stopMotion()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let y3 = ctl.yaw
        let lt = abs(y3 - y2)
        let ltOk = lt > 8
        if !ltOk { passed = false }
        ctl.checkupLog(String(format: "  Yaw ← result: %.1f°→%.1f° (Δ%.1f°) %@", y2, y3, lt, ltOk ? "✓" : "✗ <8°"))
        details.append(String(format: "%@ Left −35°/s × 1.5s: %.1f°→%.1f° (moved %.1f°)", ltOk ? "✓" : "✗", y2, y3, lt))

        ctl.recenter(); try? await Task.sleep(nanoseconds: 2_000_000_000)
        return (passed, String(format: "Yaw speed: right %.0f°  left %.0f° %@", rt, lt, passed ? "✓" : "✗"), details)
    }

    private func checkModeSwitch(ctl: GimbalController) async -> (Bool, String, [String]) {
        var details = [String](); var passed = true

        ctl.setMode(.lock)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let lockOk = ctl.mode == .lock
        if !lockOk { passed = false }
        details.append("\(lockOk ? "✓" : "✗") Follow → Lock (state: \(ctl.mode.rawValue))")

        ctl.setMode(.sport)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let sportOk = ctl.mode == .sport
        if !sportOk { passed = false }
        details.append("\(sportOk ? "✓" : "✗") Lock → Sport (state: \(ctl.mode.rawValue))")

        ctl.setMode(.follow)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let followOk = ctl.mode == .follow
        if !followOk { passed = false }
        details.append("\(followOk ? "✓" : "✗") Sport → Follow (state: \(ctl.mode.rawValue))")

        details.append("Note: mode state is local-only — the gimbal may lag by one frame.")
        return (passed, passed ? "All 3 modes switched ✓" : "Mode switch issue ✗", details)
    }

    private func checkReturnToCenter(ctl: GimbalController) async -> (Bool, String, [String]) {
        ctl.setAngle(pitchDeg: 30, yawDeg: 60, durationSec: 2)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        ctl.recenter()
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        let p = ctl.pitch, y = ctl.yaw
        let ok = abs(p) < 3.0 && abs(y) < 3.0
        return (ok, String(format: "Center: P%.1f° Y%.1f° %@", p, y, ok ? "✓" : "✗"), [
            String(format: "After recenter: Pitch=%.2f°  Yaw=%.2f°  Roll=%.2f°", p, y, ctl.roll),
            String(format: "Tolerance ±3°: %@", ok ? "PASS" : "FAIL — gimbal did not return within tolerance")
        ])
    }

    // MARK: - Helper: generic axis accuracy

    private func accuracyTest(
        ctl: GimbalController,
        targets: [(pitch: Double, yaw: Double)],
        readAxis: (GimbalController) -> Double
    ) async -> (Bool, String, [String]) {
        var details = [String](); var errors = [Double](); var allPassed = true

        for t in targets {
            ctl.setAngle(pitchDeg: t.pitch, yawDeg: t.yaw, durationSec: 2.5)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let actual   = readAxis(ctl)
            let target   = targets.contains(where: { $0.pitch != 0 }) ? t.pitch : t.yaw
            let err      = abs(actual - target)
            errors.append(err)
            let ok = err < 3.0
            if !ok { allPassed = false }
            ctl.checkupLog(String(format: "  → P%+.0f° Y%+.0f°: got %.1f°  Δ=%.2f° %@",
                                  t.pitch, t.yaw, actual, err, ok ? "✓" : "✗"))
            details.append(String(format: "%@ Target %+.0f°  Got %+.1f°  Δ=%.2f°",
                                  ok ? "✓" : "✗", target, actual, err))
        }

        let avg = errors.isEmpty ? 0.0 : errors.reduce(0, +) / Double(errors.count)
        let max = errors.max() ?? 0.0
        details.append(String(format: "Mean Δ=%.2f°  Max Δ=%.2f°", avg, max))

        ctl.recenter(); try? await Task.sleep(nanoseconds: 2_500_000_000)
        return (allPassed, String(format: "Accuracy: mean Δ%.1f°  max Δ%.1f° %@", avg, max, allPassed ? "✓" : "✗"), details)
    }

    // MARK: - Physical step analysis

    private func analyzePhysical(
        index: Int,
        frames: [String],
        before: (pitch: Double, yaw: Double)?,
        after: (pitch: Double, yaw: Double)?
    ) -> (passed: Bool, summary: String, details: [String]) {

        var details = [String]()
        details.append("BLE frames captured: \(frames.count)")
        details.append(contentsOf: frames.prefix(40).map { "  ↙ \($0)" })
        if frames.count > 40 { details.append("  … (\(frames.count - 40) more frames)") }

        if let b = before, let a = after {
            details.append(String(format: "Position before: P=%.1f°  Y=%.1f°", b.pitch, b.yaw))
            details.append(String(format: "Position after:  P=%.1f°  Y=%.1f°", a.pitch, a.yaw))
            let dp = abs(a.pitch - b.pitch), dy = abs(a.yaw - b.yaw)
            if dp > 1.0 || dy > 1.0 {
                details.append(String(format: "Δ Position: ΔP=%.1f°  ΔY=%.1f°", dp, dy))
            }
        }

        let name = steps[index].name
        let passed: Bool
        let summary: String

        if name.contains("Joystick") {
            let jFrames = frames.filter { $0.contains("cmd=57") }
            passed  = !jFrames.isEmpty
            summary = passed
                ? "✓ \(jFrames.count) joystick frame(s) received (cmd=57)"
                : "✗ No joystick frames — check if cmd=57 arrives on this device"
        } else if name.contains("Trigger × 2") {
            if let a = after {
                let centered = abs(a.pitch) < 5 && abs(a.yaw) < 5
                passed  = centered
                summary = centered
                    ? String(format: "✓ Recentered: P=%.1f° Y=%.1f°", a.pitch, a.yaw)
                    : String(format: "? Not recentered: P=%.1f° Y=%.1f° — may need physical confirmation", a.pitch, a.yaw)
            } else {
                passed = true; summary = "Completed (no position data)"
            }
        } else if name.contains("Zoom") {
            let unexpected = frames.filter { !$0.contains("cmd=57") && !$0.contains("cmd=05") && !$0.contains("cmd=02") }
            passed  = unexpected.isEmpty
            summary = unexpected.isEmpty
                ? "✓ No unexpected BLE frames from zoom slider (expected)"
                : "⚠️ \(unexpected.count) unexpected frame(s) captured"
        } else {
            passed  = true
            summary = frames.isEmpty ? "Completed — no BLE frames captured" : "Completed — \(frames.count) frame(s) captured"
        }

        return (passed, summary, details)
    }

    // MARK: - Summary

    var passCount: Int    { steps.filter { $0.passed == true  }.count }
    var failCount: Int    { steps.filter { $0.passed == false }.count }
    var doneCount: Int    { steps.filter { $0.status == .done }.count }
    var totalCount: Int   { steps.count }
}
