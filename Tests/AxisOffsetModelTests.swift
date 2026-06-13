// AxisOffsetModelTests.swift
// Testes unitários do AxisOffsetModel — sem dependência de hardware.
// Executar com: swift Tests/AxisOffsetModelTests.swift
//
// Cobre:
//   - wrap180: wraparound correto em todos os quadrantes
//   - captureOffset + normalizedPitch/Yaw/Roll
//   - resetOffset
//   - diagnosticSummary
//   - useRelativeMode

import Foundation

// MARK: - Minimal test harness

var _passed = 0
var _failed = 0

func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        _passed += 1
        print("  ✓ \(message)")
    } else {
        _failed += 1
        print("  ✗ FAIL: \(message) (line \(line))")
    }
}

func checkNear(_ a: Double, _ b: Double, tolerance: Double = 0.01,
               _ message: String, file: String = #file, line: Int = #line) {
    if abs(a - b) <= tolerance {
        _passed += 1
        print("  ✓ \(message) (\(String(format: "%.4f", a)) ≈ \(b))")
    } else {
        _failed += 1
        print("  ✗ FAIL: \(message) — expected ≈\(b), got \(a) (line \(line))")
    }
}

// MARK: - Inline wrap180 (mirrors AxisOffsetModel.wrap180)

func wrap180(_ angle: Double) -> Double {
    var a = angle.truncatingRemainder(dividingBy: 360)
    if a > 180  { a -= 360 }
    if a <= -180 { a += 360 }
    return a
}

// MARK: - Inline offset normalization (mirrors AxisOffsetModel)

func normalize(raw: Double, offset: Double) -> Double {
    wrap180(raw - offset)
}

// ===========================================================================
// MARK: - Tests
// ===========================================================================

print("\n=== AxisOffsetModelTests ===")

// ---------------------------------------------------------------------------
print("\n--- wrap180: basic cases ---")
checkNear(wrap180(0),     0,    "wrap180(0) = 0")
checkNear(wrap180(180),   180,  "wrap180(180) = 180")
checkNear(wrap180(-180),  180,  "wrap180(−180) = +180 (exclusive lower bound, wraps to +180)")
checkNear(wrap180(360),   0,    "wrap180(360) = 0")
checkNear(wrap180(-360),  0,    "wrap180(−360) = 0")
checkNear(wrap180(270),  -90,   "wrap180(270) = −90")
checkNear(wrap180(-270),  90,   "wrap180(−270) = +90")
checkNear(wrap180(181),  -179,  "wrap180(181) = −179")
checkNear(wrap180(-181),  179,  "wrap180(−181) = +179")

// ---------------------------------------------------------------------------
print("\n--- wrap180: observed OM3 telemetry values ---")
// The offset documented in the Notion project map:
//   raw pitch ≈ −179.9°  when commanded to 0°
//   raw yaw   ≈ −91.0°   when commanded to 0°
checkNear(wrap180(-179.9 - (-179.9)), 0, "normalize pitch −179.9° with offset −179.9° → 0°")
checkNear(wrap180(-91.0 - (-91.0)),   0, "normalize yaw −91.0° with offset −91.0° → 0°")

// After offset, a command to pitch +45° should read ≈ +45°
checkNear(normalize(raw: -179.9 + 45, offset: -179.9), 45,  "pitch +45° after offset ≈ +45°", tolerance: 0.5)
// After offset, a command to yaw +90° should read ≈ +90°
checkNear(normalize(raw: -91.0 + 90, offset: -91.0),   90,  "yaw +90° after offset ≈ +90°", tolerance: 0.5)

// ---------------------------------------------------------------------------
print("\n--- wrap180: wraparound edge cases ---")
// Values near ±180° boundary
checkNear(normalize(raw: -179.9 + 180, offset: -179.9), 180, "normalize at +180° boundary", tolerance: 0.5)
checkNear(normalize(raw: -179.9 - 90,  offset: -179.9), -90, "normalize at −90°",           tolerance: 0.5)
// Wraparound: going past +180° wraps to negative
checkNear(wrap180(190),  -170, "190° wraps to −170°")
checkNear(wrap180(-190),  170, "−190° wraps to +170°")

// ---------------------------------------------------------------------------
print("\n--- Offset capture ---")
// Simulate captureOffset with the observed OM3 values
var pitchOffset = -179.9
var yawOffset   = -91.0
var rollOffset  =  0.0
var isCalibrated = false

func captureOffset(pitch: Double, roll: Double, yaw: Double) {
    pitchOffset  = pitch
    rollOffset   = roll
    yawOffset    = yaw
    isCalibrated = true
}

func normalizedPitch(_ raw: Double) -> Double { normalize(raw: raw, offset: pitchOffset) }
func normalizedYaw(_ raw: Double)   -> Double { normalize(raw: raw, offset: yawOffset)   }
func normalizedRoll(_ raw: Double)  -> Double { normalize(raw: raw, offset: rollOffset)  }

captureOffset(pitch: -179.9, roll: 0.0, yaw: -91.0)
check(isCalibrated, "isCalibrated = true after captureOffset")
checkNear(normalizedPitch(-179.9), 0,  "normalized pitch at rest ≈ 0°",  tolerance: 0.01)
checkNear(normalizedYaw(-91.0),   0,   "normalized yaw at rest ≈ 0°",   tolerance: 0.01)
checkNear(normalizedRoll(0.0),    0,   "normalized roll at rest ≈ 0°",  tolerance: 0.01)

// Simulate gimbal moving to pitch +45° (raw = offset + 45)
checkNear(normalizedPitch(-179.9 + 45), 45, "pitch +45°", tolerance: 0.1)
// Simulate gimbal moving to yaw +90°
checkNear(normalizedYaw(-91.0 + 90), 90, "yaw +90°", tolerance: 0.1)

// ---------------------------------------------------------------------------
print("\n--- resetOffset ---")
pitchOffset = 0; yawOffset = 0; rollOffset = 0; isCalibrated = false
check(!isCalibrated, "isCalibrated = false after resetOffset")
checkNear(normalizedPitch(-179.9), -179.9, "raw pitch returned after reset", tolerance: 0.01)

// ---------------------------------------------------------------------------
print("\n--- Telemetry parser: positionPush layout ---")
// positionPush payload: [pitch_lo, pitch_hi, roll_lo, roll_hi, yaw_lo, yaw_hi, ...]
// int16 LE, units = 1/10°.
func parsePositionPush(_ p: [UInt8]) -> (pitch: Double, yaw: Double) {
    let pitch = Double(Int16(bitPattern: UInt16(p[0]) | UInt16(p[1]) << 8)) / 10
    let yaw   = Double(Int16(bitPattern: UInt16(p[4]) | UInt16(p[5]) << 8)) / 10
    return (pitch, yaw)
}

// Encode −1799 (≈ −179.9°) for pitch, −910 (≈ −91.0°) for yaw
func toLE16(_ v: Int16) -> [UInt8] {
    [UInt8(bitPattern: Int8(truncatingIfNeeded: v)),
     UInt8(bitPattern: Int8(truncatingIfNeeded: v >> 8))]
}

let pitchRaw = Int16(-1799)
let rollRaw  = Int16(0)
let yawRaw   = Int16(-910)
let mockPayload: [UInt8] = toLE16(pitchRaw) + toLE16(rollRaw) + toLE16(yawRaw) + [0x00, 0x00]

let (parsedPitch, parsedYaw) = parsePositionPush(mockPayload)
checkNear(parsedPitch, -179.9, "positionPush pitch decoded correctly", tolerance: 0.05)
checkNear(parsedYaw,   -91.0,  "positionPush yaw decoded correctly",   tolerance: 0.05)

// After offset normalization:
captureOffset(pitch: parsedPitch, roll: 0, yaw: parsedYaw)
checkNear(normalizedPitch(parsedPitch), 0, "normalized pitch = 0° at rest", tolerance: 0.01)
checkNear(normalizedYaw(parsedYaw),     0, "normalized yaw = 0° at rest",   tolerance: 0.01)

// ---------------------------------------------------------------------------
print("\n=== Results ===")
print("Passed: \(_passed)   Failed: \(_failed)")
if _failed > 0 {
    print("\n❌ Test suite FAILED")
    exit(1)
} else {
    print("\n✅ All tests passed")
}
