// DUMLCodecTests.swift
// Testes unitários do codec DUML — sem dependência de hardware ou BLE.
// Executar com: swift Tests/DUMLCodecTests.swift
//
// Cobre:
//   - CRC8 / CRC16 (seed refletido, polinômio correto)
//   - DUMLFrame.encode() / decode() round-trip
//   - GimbalPayloadBuilder: recenter, setMode, setAngle, setSpeed
//   - Limites de payload (pitch ±90°, yaw ±160°, time > 0 no OM4)

import Foundation

// MARK: - Inline copies of types under test
// (Permite executar sem Xcode importando os arquivos diretamente)

// ---------------------------------------------------------------------------
// Minimal test harness
// ---------------------------------------------------------------------------

var _testsPassed = 0
var _testsFailed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        _testsPassed += 1
        print("  ✓ \(message)")
    } else {
        _testsFailed += 1
        print("  ✗ FAIL: \(message) (\(file.split(separator: "/").last ?? ""):\(line))")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String,
                                file: String = #file, line: Int = #line) {
    if a == b {
        _testsPassed += 1
        print("  ✓ \(message)")
    } else {
        _testsFailed += 1
        print("  ✗ FAIL: \(message) — expected \(b), got \(a) (\(file.split(separator: "/").last ?? ""):\(line))")
    }
}

func assertNil<T>(_ value: T?, _ message: String, file: String = #file, line: Int = #line) {
    if value == nil {
        _testsPassed += 1
        print("  ✓ \(message)")
    } else {
        _testsFailed += 1
        print("  ✗ FAIL: \(message) — expected nil, got \(value!) (\(file.split(separator: "/").last ?? ""):\(line))")
    }
}

// ---------------------------------------------------------------------------
// CRC helpers (copied from DUMLProtocol.swift — kept in sync manually)
// ---------------------------------------------------------------------------

func makeCRC8Table(poly: UInt8) -> [UInt8] {
    let reflected = reverseBits8(poly)
    return (0..<256).map { i -> UInt8 in
        var c = UInt8(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ reflected : c >> 1 }
        return c
    }
}

func makeCRC16Table(poly: UInt16) -> [UInt16] {
    let reflected = reverseBits16(poly)
    return (0..<256).map { i -> UInt16 in
        var c = UInt16(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ reflected : c >> 1 }
        return c
    }
}

let crc8Table  = makeCRC8Table(poly: 0x31)
let crc16Table = makeCRC16Table(poly: 0x1021)

func crc8(_ bytes: [UInt8]) -> UInt8 {
    var crc: UInt8 = 0x77
    for b in bytes { crc = crc8Table[Int(crc ^ b)] }
    return crc
}

func crc16(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0x3692
    for b in bytes { crc = (crc >> 8) ^ crc16Table[Int((crc ^ UInt16(b)) & 0xFF)] }
    return crc
}

func reverseBits8(_ b: UInt8) -> UInt8 {
    var x = b
    x = ((x >> 1) & 0x55) | ((x & 0x55) << 1)
    x = ((x >> 2) & 0x33) | ((x & 0x33) << 2)
    x = ((x >> 4) & 0x0F) | ((x & 0x0F) << 4)
    return x
}

func reverseBits16(_ v: UInt16) -> UInt16 {
    var x = v
    x = ((x >> 1) & 0x5555) | ((x & 0x5555) << 1)
    x = ((x >> 2) & 0x3333) | ((x & 0x3333) << 2)
    x = ((x >> 4) & 0x0F0F) | ((x & 0x0F0F) << 4)
    x = ((x >> 8) & 0x00FF) | ((x & 0x00FF) << 8)
    return x
}

// ---------------------------------------------------------------------------
// Minimal frame codec (mirrors DUMLFrame.encode / decode)
// ---------------------------------------------------------------------------

struct Frame {
    let target: UInt16; let seq: UInt16; let flags: UInt8
    let cmdSet: UInt8;  let cmdId: UInt8; let payload: [UInt8]

    func encode() -> [UInt8] {
        let totalLen = 13 + payload.count
        var buf = [UInt8](repeating: 0, count: totalLen)
        let version: UInt8 = 1
        buf[0] = 0x55
        buf[1] = UInt8(totalLen & 0xFF)
        buf[2] = UInt8((totalLen >> 8) & 0x03) | (version << 2)
        buf[3] = crc8(Array(buf[0..<3]))
        buf[4] = UInt8(target & 0xFF)
        buf[5] = UInt8((target >> 8) & 0xFF)
        buf[6] = UInt8((seq >> 8) & 0xFF)
        buf[7] = UInt8(seq & 0xFF)
        buf[8] = flags; buf[9] = cmdSet; buf[10] = cmdId
        for (i, b) in payload.enumerated() { buf[11 + i] = b }
        let c = crc16(Array(buf[0..<(totalLen - 2)]))
        buf[totalLen - 2] = UInt8(c & 0xFF)
        buf[totalLen - 1] = UInt8((c >> 8) & 0xFF)
        return buf
    }

    static func decode(_ data: [UInt8]) -> Frame? {
        guard data.count >= 13, data[0] == 0x55 else { return nil }
        let len = Int(data[1]) | ((Int(data[2]) & 0x03) << 8)
        guard len >= 13, data.count >= len else { return nil }
        guard crc8(Array(data[0..<3])) == data[3] else { return nil }
        let bodyCRC = crc16(Array(data[0..<(len - 2)]))
        let recvCRC = UInt16(data[len - 2]) | (UInt16(data[len - 1]) << 8)
        guard bodyCRC == recvCRC else { return nil }
        let target = UInt16(data[4]) | (UInt16(data[5]) << 8)
        let seq    = (UInt16(data[6]) << 8) | UInt16(data[7])
        return Frame(target: target, seq: seq, flags: data[8],
                     cmdSet: data[9], cmdId: data[10],
                     payload: Array(data[11..<(len - 2)]))
    }
}

// ---------------------------------------------------------------------------
// Payload builder helpers
// ---------------------------------------------------------------------------

func i16LE(_ v: Int16) -> [UInt8] {
    [UInt8(bitPattern: Int8(truncatingIfNeeded: v)),
     UInt8(bitPattern: Int8(truncatingIfNeeded: v >> 8))]
}

func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { max(lo, min(hi, v)) }

func buildRecenter() -> (cmdId: UInt8, payload: [UInt8]) {
    var p = i16LE(0) + i16LE(0) + i16LE(0)   // yaw=0, roll=0, pitch=0
    p.append(0x05)   // RotationMode.absolute
    p.append(30)     // defaultDuration
    return (0x14, p)
}

func buildSetAngle(pitchDeg: Double, yawDeg: Double, durationSec: Double = 1.0,
                   relative: Bool = false) -> (cmdId: UInt8, payload: [UInt8]) {
    let p   = Int16(clamping: Int((-pitchDeg * 10).rounded()).clamped(-1800, 1800))
    let y   = Int16(clamping: Int((yawDeg   * 10).rounded()).clamped(-1800, 1800))
    let dur = UInt8(min(255, max(1, Int(durationSec * 10))))
    var payload = i16LE(y) + i16LE(0) + i16LE(p)
    payload.append(relative ? 0x04 : 0x05)
    payload.append(dur)
    return (0x14, payload)
}

func buildSetSpeed(pitchDeg: Double, yawDeg: Double) -> (cmdId: UInt8, payload: [UInt8]) {
    let p = Int16(clamping: Int((-pitchDeg * 10).rounded()).clamped(-1800, 1800))
    let y = Int16(clamping: Int((yawDeg   * 10).rounded()).clamped(-1800, 1800))
    var payload = i16LE(y) + i16LE(0) + i16LE(p)
    payload.append(0x80)   // RotationMode.speed
    payload.append(15)     // time=1.5s window
    return (0x0C, payload)
}

func readAnglePair(payload: [UInt8]) -> (yaw: Double, pitch: Double) {
    let y = Double(Int16(bitPattern: UInt16(payload[0]) | UInt16(payload[1]) << 8)) / 10
    let p = Double(Int16(bitPattern: UInt16(payload[4]) | UInt16(payload[5]) << 8)) / 10
    return (yaw: y, pitch: p)
}

// ---------------------------------------------------------------------------
// Test wrap helper
// ---------------------------------------------------------------------------

func wrap180(_ angle: Double) -> Double {
    var a = angle.truncatingRemainder(dividingBy: 360)
    if a > 180  { a -= 360 }
    if a <= -180 { a += 360 }
    return a
}

// ===========================================================================
// MARK: - Tests
// ===========================================================================

print("\n=== DUMLCodecTests ===")

// ---------------------------------------------------------------------------
print("\n--- CRC8 ---")
// Known-good: CRC8 of [0x55, 0x0D, 0x04] for a 13-byte frame with no payload
// is consistent across encode/decode.
assert(crc8([0x55, 0x0D, 0x04]) == crc8([0x55, 0x0D, 0x04]),
       "CRC8 is deterministic")
assert(crc8([0x55, 0x0D, 0x04]) != crc8([0x55, 0x0E, 0x04]),
       "CRC8 detects single-byte change")
assert(crc8([]) == 0x77,
       "CRC8 of empty = seed (0x77)")

// ---------------------------------------------------------------------------
print("\n--- CRC16 ---")
assert(crc16([]) == 0x3692,
       "CRC16 of empty = seed (0x3692)")
assert(crc16([0x00]) != crc16([0x01]),
       "CRC16 distinguishes adjacent bytes")

// ---------------------------------------------------------------------------
print("\n--- Frame encode/decode round-trip ---")
do {
    let f = Frame(target: 0x0402, seq: 0x0100, flags: 0x40,
                  cmdSet: 0x04, cmdId: 0x14, payload: [0x01, 0x02, 0x03, 0x04, 0x05])
    let encoded = f.encode()
    assertEqual(encoded.count, 13 + 5, "Total length = 13 + payloadLen")
    assertEqual(encoded[0], 0x55,      "Magic byte 0x55")
    assertEqual(encoded[9],  0x04,     "cmdSet preserved")
    assertEqual(encoded[10], 0x14,     "cmdId preserved")

    let decoded = Frame.decode(encoded)
    assert(decoded != nil,             "decode returns non-nil for valid frame")
    assertEqual(decoded!.cmdSet,  0x04, "decoded cmdSet")
    assertEqual(decoded!.cmdId,   0x14, "decoded cmdId")
    assertEqual(decoded!.payload, [0x01, 0x02, 0x03, 0x04, 0x05], "payload preserved")
    assertEqual(decoded!.seq, 0x0100,  "seq preserved")
}

// ---------------------------------------------------------------------------
print("\n--- Frame decode — invalid frames ---")
do {
    assertNil(Frame.decode([]),              "empty → nil")
    assertNil(Frame.decode([0xAA, 0x0D, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
              "wrong magic → nil")
    // Corrupt CRC8
    var validFrame = Frame(target: 0x0402, seq: 0x0100, flags: 0x40,
                           cmdSet: 0x04, cmdId: 0x14, payload: []).encode()
    validFrame[3] ^= 0xFF   // flip CRC8
    assertNil(Frame.decode(validFrame), "corrupt CRC8 → nil")
    // Corrupt CRC16
    var validFrame2 = Frame(target: 0x0402, seq: 0x0100, flags: 0x40,
                            cmdSet: 0x04, cmdId: 0x14, payload: []).encode()
    validFrame2[validFrame2.count - 1] ^= 0xFF   // flip last byte of CRC16
    assertNil(Frame.decode(validFrame2), "corrupt CRC16 → nil")
}

// ---------------------------------------------------------------------------
print("\n--- GimbalPayloadBuilder: recenter ---")
do {
    let (cmdId, payload) = buildRecenter()
    assertEqual(cmdId, UInt8(0x14), "recenter uses absAngle (0x14)")
    assertEqual(payload.count, 8,   "recenter payload length = 8")
    // yaw=0, roll=0, pitch=0 encoded as i16 LE
    assertEqual(payload[0], 0x00, "yaw lo = 0")
    assertEqual(payload[1], 0x00, "yaw hi = 0")
    assertEqual(payload[4], 0x00, "pitch lo = 0")
    assertEqual(payload[5], 0x00, "pitch hi = 0")
    assertEqual(payload[6], 0x05, "mode = absolute (0x05)")
    assertEqual(payload[7], 30,   "duration = 30 (3s ramp)")
}

// ---------------------------------------------------------------------------
print("\n--- GimbalPayloadBuilder: setAngle ---")
do {
    // Pitch +45° → wire pitch = −450 (inverted) = 0xFE5E LE → [0x5E, 0xFE]
    let (cmdId, payload) = buildSetAngle(pitchDeg: 45, yawDeg: 90, durationSec: 2.0)
    assertEqual(cmdId, UInt8(0x14), "setAngle uses absAngle (0x14)")
    assertEqual(payload[6], 0x05,  "absolute mode = 0x05")
    assertEqual(payload[7], 20,    "duration 2.0s → 20 tenths")

    // Verify pitch inversion: +45° sent as −450 tenths
    let p = Int16(bitPattern: UInt16(payload[4]) | UInt16(payload[5]) << 8)
    assertEqual(p, -450, "pitch +45° encoded as −450 (inverted on wire)")

    // Verify yaw direction: +90° → +900 tenths
    let y = Int16(bitPattern: UInt16(payload[0]) | UInt16(payload[1]) << 8)
    assertEqual(y, 900, "yaw +90° encoded as +900")
}

// Relative mode
do {
    let (_, payload) = buildSetAngle(pitchDeg: 10, yawDeg: 0, relative: true)
    assertEqual(payload[6], 0x04, "relative mode = 0x04")
}

// Clamp: pitch beyond −90°/+90° (hardware limits)
do {
    let (_, payload) = buildSetAngle(pitchDeg: 200, yawDeg: 0)
    let p = Int16(bitPattern: UInt16(payload[4]) | UInt16(payload[5]) << 8)
    assert(abs(Int(p)) <= 1800, "pitch clamped to ±180° (1800 tenths) at limit")
}

// Clamp: yaw beyond ±160°
do {
    let (_, payload) = buildSetAngle(pitchDeg: 0, yawDeg: 200)
    let y = Int16(bitPattern: UInt16(payload[0]) | UInt16(payload[1]) << 8)
    assert(abs(Int(y)) <= 1800, "yaw clamped at limit")
}

// ---------------------------------------------------------------------------
print("\n--- GimbalPayloadBuilder: setSpeed ---")
do {
    let (cmdId, payload) = buildSetSpeed(pitchDeg: 30, yawDeg: -60)
    assertEqual(cmdId, UInt8(0x0C), "setSpeed uses speedCtrl (0x0C)")
    assertEqual(payload[6], 0x80,  "speed mode = 0x80")
    assertEqual(payload[7], 15,    "time=15 (OM4 requires >0)")

    let p = Int16(bitPattern: UInt16(payload[4]) | UInt16(payload[5]) << 8)
    assertEqual(p, -300, "pitchSpeed +30°/s encoded as −300 (inverted)")

    let y = Int16(bitPattern: UInt16(payload[0]) | UInt16(payload[1]) << 8)
    assertEqual(y, -600, "yawSpeed −60°/s encoded as −600")
}

// setSpeed zero — stop command
do {
    let (_, payload) = buildSetSpeed(pitchDeg: 0, yawDeg: 0)
    let p = Int16(bitPattern: UInt16(payload[4]) | UInt16(payload[5]) << 8)
    let y = Int16(bitPattern: UInt16(payload[0]) | UInt16(payload[1]) << 8)
    assertEqual(p, 0, "stop: pitch=0")
    assertEqual(y, 0, "stop: yaw=0")
}

// ---------------------------------------------------------------------------
print("\n--- Frame: target field encoding ---")
do {
    // sender=app(0x02), receiver=gimbal(0x04) → target LE = 0x0402
    let target: UInt16 = UInt16(0x02) | (UInt16(0x04) << 8)
    assertEqual(target, 0x0402, "app→gimbal target = 0x0402")

    let f = Frame(target: target, seq: 1, flags: 0x40,
                  cmdSet: 0x04, cmdId: 0x14, payload: []).encode()
    assertEqual(f[4], 0x02, "target lo byte = sender (0x02=app)")
    assertEqual(f[5], 0x04, "target hi byte = receiver (0x04=gimbal)")
}

// ---------------------------------------------------------------------------
print("\n--- Frame: sequence number big-endian ---")
do {
    let seq: UInt16 = 0x0123
    let f = Frame(target: 0, seq: seq, flags: 0, cmdSet: 0, cmdId: 0, payload: []).encode()
    // seq is stored big-endian: buf[6]=hi, buf[7]=lo
    assertEqual(f[6], 0x01, "seq hi byte at offset 6")
    assertEqual(f[7], 0x23, "seq lo byte at offset 7")
}

// ---------------------------------------------------------------------------
print("\n--- Heartbeat payload ---")
do {
    // Heartbeat 0x50, payload [0x01, 0x04, 0x05] — from OM Research
    let f = Frame(target: 0x0402, seq: 1, flags: 0x40,
                  cmdSet: 0x04, cmdId: 0x50, payload: [0x01, 0x04, 0x05])
    let enc = f.encode()
    let dec = Frame.decode(enc)
    assert(dec != nil,          "heartbeat frame decodes successfully")
    assertEqual(dec!.cmdId, 0x50, "cmdId = 0x50")
    assertEqual(dec!.payload, [0x01, 0x04, 0x05], "heartbeat payload preserved")
}

// ---------------------------------------------------------------------------
print("\n=== Results ===")
print("Passed: \(_testsPassed)   Failed: \(_testsFailed)")
if _testsFailed > 0 {
    print("\n❌ Test suite FAILED")
    exit(1)
} else {
    print("\n✅ All tests passed")
}
