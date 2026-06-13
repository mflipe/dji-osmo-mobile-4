import Foundation

// MARK: - F0 pitch experiment — payload builders
//
// See docs/F0_PITCH_EXPERIMENT.md for the full test protocol.
//
// Hypothesis: pitch is not dead; the command frame and the telemetry frame
// disagree by a constant per-axis offset.
// Strategy A: keep absolute commands (RotationMode.absolute 0x05) and
//   normalize telemetry via AxisOffsetModel.
// Strategy B: use relative moves (RotationMode.relative 0x04).
// Both strategies send the heartbeat (0x50) first to rule out session gating.

private func i16LE(_ v: Int16) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
}

extension GimbalPayloadBuilder {

    /// Relative rotation (mode 0x04): moves by a delta from current position.
    /// Same wire layout as absAngle: [yaw:i16LE, roll:i16LE, pitch:i16LE, mode, time].
    /// Pitch sign is inverted for consistency with setAngle/setSpeed.
    static func setAngleRelative(pitchDeltaDeg: Double, yawDeltaDeg: Double,
                                 durationSec: Double = 1.0) -> (cmdId: UInt8, payload: [UInt8]) {
        let p   = Int16(clamping: Int(-pitchDeltaDeg * 10).clamped(-1800, 1800))
        let y   = Int16(clamping: Int(yawDeltaDeg * 10).clamped(-1800, 1800))
        let dur = UInt8(min(255, max(1, Int(durationSec * 10))))
        var payload = i16LE(y) + i16LE(0) + i16LE(p)
        payload.append(DUML.RotationMode.relative.rawValue)
        payload.append(dur)
        return (DUML.GimbalCmd.absAngle, payload)
    }

    /// Session heartbeat (0x50).
    /// OM Research (clockworkant fork) documents payload 01 04 05, sent
    /// every ~2s, to keep advanced control active.
    static func heartbeat() -> (cmdId: UInt8, payload: [UInt8]) {
        (DUML.GimbalCmd.heartbeat, [0x01, 0x04, 0x05])
    }
}

// MARK: - Scripted experiment steps

struct PitchExperimentStep {
    let title: String
    let cmdId: UInt8
    let payload: [UInt8]
    let settleSeconds: Double
    let expectation: String
}

enum PitchExperimentPlan {

    /// Ordered steps for the manual hardware run.
    /// Send each payload through the existing BLE write path
    /// (cmdSet = DUML.CmdSet.gimbal, flags = DUML.Flag.request),
    /// wait settleSeconds, then record raw telemetry P/R/Y.
    static func steps() -> [PitchExperimentStep] {
        var out: [PitchExperimentStep] = []

        let hb = GimbalPayloadBuilder.heartbeat()
        out.append(.init(
            title: "Heartbeat (0x50)",
            cmdId: hb.cmdId, payload: hb.payload, settleSeconds: 0.5,
            expectation: "No error response. Re-send every ~2s for the rest of the run."))

        let center = GimbalPayloadBuilder.recenter()
        out.append(.init(
            title: "Recenter — absolute 0/0/0 (mode 0x05)",
            cmdId: center.cmdId, payload: center.payload, settleSeconds: 3.0,
            expectation: "Record telemetry P/Y as reference. Hypothesis predicts pitch ≈ -179.9, yaw ≈ -91. Feed AxisOffsetModel.capture(commanded:0, observed:<reading>)."))

        let up = GimbalPayloadBuilder.setAngle(pitchDeg: 30, yawDeg: 0)
        out.append(.init(
            title: "Absolute pitch +30° (mode 0x05)",
            cmdId: up.cmdId, payload: up.payload, settleSeconds: 3.0,
            expectation: "Camera physically tilts. Offset-corrected telemetry ≈ +30."))

        let down = GimbalPayloadBuilder.setAngle(pitchDeg: -30, yawDeg: 0)
        out.append(.init(
            title: "Absolute pitch -30° (mode 0x05)",
            cmdId: down.cmdId, payload: down.payload, settleSeconds: 3.0,
            expectation: "Camera tilts the other way. Offset-corrected telemetry ≈ -30."))

        let relUp = GimbalPayloadBuilder.setAngleRelative(pitchDeltaDeg: 20, yawDeltaDeg: 0)
        out.append(.init(
            title: "Relative pitch +20° (mode 0x04)",
            cmdId: relUp.cmdId, payload: relUp.payload, settleSeconds: 3.0,
            expectation: "Camera tilts ~20° from current position. If 0x05 failed but this works → prefer Strategy B."))

        let relDown = GimbalPayloadBuilder.setAngleRelative(pitchDeltaDeg: -20, yawDeltaDeg: 0)
        out.append(.init(
            title: "Relative pitch -20° (mode 0x04)",
            cmdId: relDown.cmdId, payload: relDown.payload, settleSeconds: 3.0,
            expectation: "Camera tilts back ~20°."))

        let final = GimbalPayloadBuilder.recenter()
        out.append(.init(
            title: "Final recenter",
            cmdId: final.cmdId, payload: final.payload, settleSeconds: 3.0,
            expectation: "Gimbal returns to home. Telemetry matches step-2 reference."))

        return out
    }
}
