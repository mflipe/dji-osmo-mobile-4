import Foundation

// Standalone unit tests — no Xcode test target required.
// Run:  bash Tests/run_tests.sh
// Exits non-zero on any failure (CI-friendly).

var passCount = 0
var failCount = 0

func expect(_ condition: Bool, _ name: String) {
    if condition { passCount += 1; print("  PASS  \(name)") }
    else         { failCount += 1; print("  FAIL  \(name)") }
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { passCount += 1; print("  PASS  \(name)") }
    else { failCount += 1; print("  FAIL  \(name) — expected \(expected), got \(actual)") }
}
func expectClose(_ actual: Double, _ expected: Double, tolerance: Double = 1e-6, _ name: String) {
    if abs(actual - expected) <= tolerance { passCount += 1; print("  PASS  \(name)") }
    else { failCount += 1; print("  FAIL  \(name) — expected \(expected), got \(actual)") }
}

// MARK: - CRC (cross-check against an independent bit-wise implementation)

func referenceCRC8(_ bytes: [UInt8]) -> UInt8 {
    var crc: UInt8 = 0x77 // reflect(0xEE)
    for byte in bytes {
        crc ^= byte
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1 }
    }
    return crc
}
func referenceCRC16(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0x3692 // reflect(0x496C)
    for byte in bytes {
        crc ^= UInt16(byte)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
    }
    return crc
}

print("== CRC ==")
let crcVectors: [[UInt8]] = [[], [0x55], [0x55, 0x0D, 0x04], Array(0...255), [0xAA, 0x00, 0xFF, 0x12, 0x34]]
for (i, v) in crcVectors.enumerated() {
    expectEqual(DUMLCRC.crc8(v),  referenceCRC8(v),  "crc8  vector \(i)")
    expectEqual(DUMLCRC.crc16(v), referenceCRC16(v), "crc16 vector \(i)")
}

// MARK: - Frame encode / decode

print("== DUMLFrame ==")
let frame = DUMLFrame(
    target: DUML.target(from: .app, to: .gimbal), seq: 0x0102,
    flags: DUML.Flag.request, cmdSet: DUML.CmdSet.gimbal,
    cmdId: DUML.GimbalCmd.absAngle, payload: [1, 2, 3, 4, 5, 6, 7, 8])
let encoded = frame.encode()
expectEqual(encoded.count, 21, "encode: totalLen = 13 + payload(8)")
expectEqual(encoded[0],  0x55, "encode: magic byte")
expectEqual(encoded[3],  referenceCRC8(Array(encoded[0..<3])), "encode: header CRC8")
expectEqual(encoded[4],  0x02, "encode: target sender LE (app=0x02)")
expectEqual(encoded[5],  0x04, "encode: target receiver LE (gimbal=0x04)")
expectEqual(encoded[6],  0x01, "encode: seq high byte (big-endian)")
expectEqual(encoded[7],  0x02, "encode: seq low byte")
let wireCRC16 = UInt16(encoded[19]) | (UInt16(encoded[20]) << 8)
expectEqual(wireCRC16, referenceCRC16(Array(encoded[0..<19])), "encode: trailing CRC16 LE")

if let decoded = DUMLFrame.decode(encoded) {
    expectEqual(decoded.target,  frame.target,  "decode: target roundtrip")
    expectEqual(decoded.seq,     frame.seq,     "decode: seq roundtrip")
    expectEqual(decoded.flags,   frame.flags,   "decode: flags roundtrip")
    expectEqual(decoded.cmdSet,  frame.cmdSet,  "decode: cmdSet roundtrip")
    expectEqual(decoded.cmdId,   frame.cmdId,   "decode: cmdId roundtrip")
    expectEqual(decoded.payload, frame.payload, "decode: payload roundtrip")
    expect(!decoded.isResponse,                 "decode: request flag → not a response")
} else { expect(false, "decode: roundtrip returned nil") }

var corrupted = encoded; corrupted[12] ^= 0xFF
expect(DUMLFrame.decode(corrupted) == nil, "decode: rejects corrupted body (CRC16)")
var badHdr = encoded; badHdr[3] ^= 0xFF
expect(DUMLFrame.decode(badHdr) == nil, "decode: rejects corrupted header (CRC8)")

// MARK: - Payload builders (existing)

print("== GimbalPayloadBuilder (existing) ==")

// setAngle: wire layout is [yaw:i16LE, roll:i16LE, pitch:i16LE, mode, time].
// yaw -45° → -450 → 0xFE3E LE; pitch +30° inverted → -300 → 0xFED4 LE.
let angle = GimbalPayloadBuilder.setAngle(pitchDeg: 30, yawDeg: -45, durationSec: 1.0)
expectEqual(angle.cmdId, DUML.GimbalCmd.absAngle, "setAngle: cmdId 0x14")
expectEqual(angle.payload.count, 8,                "setAngle: payload length 8")
expectEqual(Array(angle.payload[0...1]), [0x3E, 0xFE], "setAngle: yaw -45° → -450 i16 LE")
expectEqual(Array(angle.payload[2...3]), [0x00, 0x00], "setAngle: roll = 0")
expectEqual(Array(angle.payload[4...5]), [0xD4, 0xFE], "setAngle: pitch +30° inverted → -300 i16 LE")
expectEqual(angle.payload[6], DUML.RotationMode.absolute.rawValue, "setAngle: mode 0x05")
expectEqual(angle.payload[7], 10,                                   "setAngle: dur 1.0s → 10")

let clamped = GimbalPayloadBuilder.setAngle(pitchDeg: 200, yawDeg: 0)
let pClamped = TelemetryNormalization.int16LE(clamped.payload[4], clamped.payload[5])
expectEqual(pClamped, -1800, "setAngle: pitch clamped to ±180°")

let speed = GimbalPayloadBuilder.setSpeed(pitchDeg: 10, yawDeg: 20)
expectEqual(speed.cmdId, DUML.GimbalCmd.speedCtrl, "setSpeed: cmdId 0x0C")
expectEqual(Array(speed.payload[0...1]), [0xC8, 0x00], "setSpeed: yaw 20°/s → 200 i16 LE")
expectEqual(Array(speed.payload[4...5]), [0x9C, 0xFF], "setSpeed: pitch 10°/s inverted → -100 i16 LE")
expectEqual(speed.payload[6], DUML.RotationMode.speed.rawValue, "setSpeed: mode 0x80")
expectEqual(speed.payload[7], 15,                                "setSpeed: time 15 (OM4 requires >0)")

let center = GimbalPayloadBuilder.recenter()
expectEqual(center.cmdId,    DUML.GimbalCmd.absAngle,            "recenter: cmdId 0x14")
expectEqual(center.payload,  [0,0,0,0,0,0,0x05,30],              "recenter: zeros + absolute + default dur")

let modeCmd = GimbalPayloadBuilder.setMode(.follow)
expectEqual(modeCmd.cmdId,    DUML.GimbalCmd.setMode, "setMode: cmdId 0x4C")
expectEqual(modeCmd.payload,  [0x01, 0x00],            "setMode: follow = 1")

// MARK: - Payload builders (F0)

print("== GimbalPayloadBuilder (F0) ==")

let rel = GimbalPayloadBuilder.setAngleRelative(pitchDeltaDeg: 20, yawDeltaDeg: 0, durationSec: 1.5)
expectEqual(rel.cmdId, DUML.GimbalCmd.absAngle,          "setAngleRelative: cmdId 0x14")
expectEqual(rel.payload.count, 8,                         "setAngleRelative: payload length 8")
expectEqual(Array(rel.payload[4...5]), [0x38, 0xFF],      "setAngleRelative: pitch +20° inverted → -200 i16 LE")
expectEqual(rel.payload[6], DUML.RotationMode.relative.rawValue, "setAngleRelative: mode 0x04")
expectEqual(rel.payload[7], 15,                           "setAngleRelative: dur 1.5s → 15")

let hb = GimbalPayloadBuilder.heartbeat()
expectEqual(hb.cmdId,    DUML.GimbalCmd.heartbeat,  "heartbeat: cmdId 0x50")
expectEqual(hb.payload,  [0x01, 0x04, 0x05],        "heartbeat: payload 01 04 05")

expectEqual(PitchExperimentPlan.steps().count, 7, "experiment: 7 ordered steps")

// MARK: - Telemetry normalization (F0)

print("== TelemetryNormalization ==")

expectClose(TelemetryNormalization.normalizeDegrees(190),   -170, "normalize 190 → -170")
expectClose(TelemetryNormalization.normalizeDegrees(-190),   170, "normalize -190 → 170")
expectClose(TelemetryNormalization.normalizeDegrees(-180),   180, "normalize -180 → 180 (half-open)")
expectClose(TelemetryNormalization.normalizeDegrees(540),    180, "normalize 540 → 180")
expectClose(TelemetryNormalization.angularDifference(-179.9, 179.9), 0.2, tolerance: 1e-3,
            "angularDifference wraps across ±180")
expectEqual(TelemetryNormalization.int16LE(0x3E, 0xFE), -450, "int16LE negative")
expectClose(TelemetryNormalization.decodeAngleDeciDegrees(lo: 0x3E, hi: 0xFE), -45.0,
            "decodeAngleDeciDegrees: -450 → -45.0°")

// OM3 reference: pitch 0° → telemetry ≈ -179.9°; yaw 0° → ≈ -91°.
var pitchModel = AxisOffsetModel()
pitchModel.capture(commandedDegrees: 0, observedDegrees: -179.9)
expectClose(pitchModel.offsetDegrees ?? .nan,                     -179.9, "pitch: offset captured")
expectClose(pitchModel.expectedObservedAngle(forCommanded: 30),   -149.9, "pitch: +30 expected at -149.9")
expectClose(pitchModel.commandFrameAngle(fromObserved: -149.9),    30,    "pitch: -149.9 → +30 command frame")
expectClose(pitchModel.commandFrameAngle(fromObserved: 150.2),    -29.9, tolerance: 1e-3,
            "pitch: wraparound across ±180 handled")

var yawModel = AxisOffsetModel()
yawModel.capture(commandedDegrees: 0, observedDegrees: -91)
expectClose(yawModel.expectedObservedAngle(forCommanded: 45), -46, "yaw: +45 expected at -46")
expectClose(yawModel.commandFrameAngle(fromObserved: -46),     45, "yaw: -46 → +45 command frame")

var unset = AxisOffsetModel()
expectClose(unset.commandFrameAngle(fromObserved: 12.3), 12.3, "no offset → pass-through")
unset.capture(commandedDegrees: 0, observedDegrees: 10)
unset.reset()
expect(unset.offsetDegrees == nil, "reset clears offset")

// MARK: - Stream parser (actor)

print("== DUMLStreamParser ==")
let sem = DispatchSemaphore(value: 0)
Task.detached {
    let parser = DUMLStreamParser()
    let f1 = DUMLFrame(target: DUML.target(from: .gimbal, to: .app), seq: 1,
                       flags: DUML.Flag.notify, cmdSet: DUML.CmdSet.gimbal,
                       cmdId: DUML.GimbalCmd.getPos,
                       payload: [0,1,2,3,4,5,6,7,8]).encode()
    let f2 = DUMLFrame(target: DUML.target(from: .gimbal, to: .app), seq: 2,
                       flags: DUML.Flag.notify, cmdSet: DUML.CmdSet.gimbal,
                       cmdId: DUML.GimbalCmd.batteryLevel, payload: [87]).encode()

    var frames = await parser.append([0x00, 0xFF, 0x13] + Array(f1[0..<10]))
    expectEqual(frames.count, 0, "parser: waits for complete frame")
    frames = await parser.append(Array(f1[10...]) + f2)
    expectEqual(frames.count, 2, "parser: resyncs past garbage, emits both frames")
    if frames.count == 2 {
        expectEqual(frames[0].cmdId,   DUML.GimbalCmd.getPos, "parser: first frame cmdId")
        expectEqual(frames[1].payload, [87],                   "parser: second frame payload")
    }
    await parser.reset()
    frames = await parser.append(f2)
    expectEqual(frames.count, 1, "parser: works after reset")
    sem.signal()
}
sem.wait()

// MARK: - Summary

print("\n\(passCount) passed, \(failCount) failed")
exit(failCount == 0 ? 0 : 1)
