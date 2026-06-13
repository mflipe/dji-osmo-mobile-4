import Foundation

// MARK: - GimbalPayloadBuilder — relative-mode extension (F0 experiment)
//
// Extends the existing GimbalPayloadBuilder (in DUMLProtocol.swift) with
// builders that use RotationMode.relative (0x04) instead of .absolute (0x05).
//
// Relative mode sends *deltas* from the current position rather than
// absolute angles, making the coordinate-frame offset irrelevant for
// incremental control (PID / keyboard joystick).

extension GimbalPayloadBuilder {

    /// setAngle in relative mode: payload encodes a delta, not an absolute angle.
    /// `pitchDelta` / `yawDelta` are in degrees (positive pitch = up, positive yaw = right).
    static func setAngleRelative(
        pitchDelta: Double,
        yawDelta: Double,
        durationSec: Double = 1.0
    ) -> (cmdId: UInt8, payload: [UInt8]) {
        let p   = Int16(clamping: Int((-pitchDelta * 10).rounded()).clamped(-1800, 1800))
        let y   = Int16(clamping: Int((yawDelta   * 10).rounded()).clamped(-1800, 1800))
        let dur = UInt8(min(255, max(1, Int(durationSec * 10))))
        // Same wire layout as absAngle (0x14): [yaw i16LE, roll i16LE, pitch i16LE, mode u8, time u8]
        // Only the mode byte differs: 0x04 = relative.
        var payload = i16LE(y) + i16LE(0) + i16LE(p)
        payload.append(DUML.RotationMode.relative.rawValue)
        payload.append(dur)
        return (DUML.GimbalCmd.absAngle, payload)
    }

    // MARK: Private helpers (mirror the private helper in DUMLProtocol.swift)
    // These are scoped to this extension to avoid symbol collision.

    private static func i16LE(_ v: Int16) -> [UInt8] {
        [UInt8(bitPattern: Int8(truncatingIfNeeded: v)),
         UInt8(bitPattern: Int8(truncatingIfNeeded: v >> 8))]
    }
}
