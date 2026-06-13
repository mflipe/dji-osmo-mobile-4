import Foundation

// MARK: - Telemetry frame normalization (F0 experiment)
//
// Pure helpers to reconcile the coordinate frame used by gimbal commands
// (absAngle 0x14 / speedCtrl 0x0C) with the frame reported by telemetry
// (getPos 0x02 / positionPush 0x05).
//
// Background: on the reference OM3 (OM Research), commanding absolute
// pitch 0° produces a telemetry reading of ≈ -179.9°, and yaw 0° reads
// ≈ -91°. This repo's logs show pitch telemetry hovering around ±179.9°
// while pitch appears unresponsive. The leading hypothesis is a constant
// per-axis offset between the command frame and the telemetry frame
// (with wraparound at ±180°), not a dead axis.
// See docs/F0_PITCH_EXPERIMENT.md for the manual test protocol.

enum TelemetryNormalization {

    /// Wraps an angle in degrees to the half-open interval (-180, 180].
    static func normalizeDegrees(_ value: Double) -> Double {
        var x = value.truncatingRemainder(dividingBy: 360)
        if x <= -180 { x += 360 }
        if x > 180 { x -= 360 }
        return x
    }

    /// Smallest signed difference a - b in degrees, wrapped to (-180, 180].
    static func angularDifference(_ a: Double, _ b: Double) -> Double {
        normalizeDegrees(a - b)
    }

    /// Decodes an Int16 from two little-endian bytes.
    static func int16LE(_ lo: UInt8, _ hi: UInt8) -> Int16 {
        Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8))
    }

    /// Decodes a 1/10-degree int16 LE angle pair into degrees.
    static func decodeAngleDeciDegrees(lo: UInt8, hi: UInt8) -> Double {
        Double(int16LE(lo, hi)) / 10.0
    }
}

/// Captures and applies a constant offset between the command frame and the
/// telemetry frame for a single axis (pitch or yaw).
struct AxisOffsetModel {
    private(set) var offsetDegrees: Double?

    /// Call after commanding a known absolute angle and letting the gimbal
    /// settle: stores (telemetry - command), wrapped, as the axis offset.
    mutating func capture(commandedDegrees: Double, observedDegrees: Double) {
        offsetDegrees = TelemetryNormalization.angularDifference(observedDegrees, commandedDegrees)
    }

    /// Converts a raw telemetry reading into the command frame.
    func commandFrameAngle(fromObserved observedDegrees: Double) -> Double {
        guard let offset = offsetDegrees else { return observedDegrees }
        return TelemetryNormalization.normalizeDegrees(observedDegrees - offset)
    }

    /// The value telemetry should report once a commanded move completes
    /// (useful to verify the hypothesis during the F0 experiment).
    func expectedObservedAngle(forCommanded commandedDegrees: Double) -> Double {
        guard let offset = offsetDegrees else { return commandedDegrees }
        return TelemetryNormalization.normalizeDegrees(commandedDegrees + offset)
    }

    mutating func reset() { offsetDegrees = nil }
}
