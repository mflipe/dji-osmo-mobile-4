import Foundation

// MARK: - DUML Protocol Constants
//
// Wire format:
//   [0x55][len_lo][ver<<2 | len_hi][crc8][target:2 LE]
//   [seq:2 BE][flags][cmdSet][cmdId][payload][crc16:2 LE]
//
// totalLen = 13 + payloadLen.

enum DUML {

    enum Address: UInt8 {
        case any         = 0x00
        case camera      = 0x01
        case app         = 0x02
        case fc          = 0x03
        case gimbal      = 0x04
        case centerBoard = 0x05
        case rc          = 0x06
        case wifi        = 0x07
        case dm36x       = 0x08
    }

    // sender | (receiver << 8) — written little-endian on the wire.
    static func target(from sender: Address, to receiver: Address) -> UInt16 {
        UInt16(sender.rawValue) | (UInt16(receiver.rawValue) << 8)
    }

    enum Flag {
        static let request:  UInt8 = 0x40
        static let response: UInt8 = 0xC0
        static let notify:   UInt8 = 0x00
    }

    enum CmdSet {
        static let general: UInt8 = 0x00
        static let camera:  UInt8 = 0x01
        static let fc:      UInt8 = 0x03
        static let gimbal:  UInt8 = 0x04
        static let battery: UInt8 = 0x06
        static let wifi:    UInt8 = 0x07
    }

    // Gimbal command IDs (cmdSet = 0x04).
    enum GimbalCmd {
        static let controlPWM:     UInt8 = 0x01
        // 0x02: getPos pull response — OM3 sends this every ~1s as position telemetry.
        // Layout: [flags pitch_lo pitch_hi roll_lo roll_hi yaw_lo yaw_hi ? ?] (9 bytes, 1/10°)
        static let getPos:         UInt8 = 0x02
        static let angleSet:       UInt8 = 0x0A
        static let speedCtrl:      UInt8 = 0x0C // angular velocity — payload: [pitch, roll, yaw, mode]
        static let absAngle:       UInt8 = 0x14 // absolute angle — payload: [yaw, roll, pitch, axisMask, dur]
        // NOTE: absAngle byte order (yaw-first) differs from speedCtrl (pitch-first).
        static let movement:       UInt8 = 0x15
        static let setMode:        UInt8 = 0x4C // 0=lock, 1=follow, 2=fpv (sport)
        // 0x1C: battery level push every ~2s. payload[0] = 0..100 percent.
        static let batteryLevel:   UInt8 = 0x1C
        // 0x57: physical joystick deflection at ~25Hz while held.
        // Layout: [yaw_lo yaw_hi pitch_lo pitch_hi 0x01 flags] (6 bytes, raw -1000..+1000)
        // Host must respond with setSpeed commands; the joystick does NOT move the gimbal directly.
        static let joystickReport: UInt8 = 0x57
    }

    // Rotation modes for gimbal commands (from OM Research project).
    // The mode byte in rotate payload determines the type of movement.
    enum RotationMode: UInt8 {
        case relative = 0x04  // relative movement
        case absolute = 0x05  // absolute angle positioning
        case speed    = 0x80  // velocity control mode
    }

    // Deprecated: use RotationMode instead
    enum GimbalPayload {
        static let defaultDuration: UInt8 = 30    // absAngle ramp time in 1/10 s
    }

    // Physical button events (M, shutter, trigger, zoom) are NOT transmitted via BLE on the OM3.
    // The firmware handles them internally. Only the joystick reports deflection (cmdId=0x57 above).

    enum WifiCmd {
        static let setPairingPin:   UInt8 = 0x45
        static let pairingApproved: UInt8 = 0x46
        static let wifiConnect:     UInt8 = 0x47
    }

    enum GimbalMode: UInt8 {
        case lock   = 0
        case follow = 1
        case fpv    = 2 // OM3 "Sport" maps here
    }

    enum BLEUUID {
        static let service  = "FFF0"
        static let charFFF3 = "FFF3"
        static let charFFF4 = "FFF4"
        static let charFFF5 = "FFF5"
    }

    static let defaultPin        = "love"
    static let defaultIdentifier = "001749319286102"
}

// MARK: - CRC
//
// CRC8:  catalog params width=8,  poly=0x31,   init=0xEE,   refIn=true, refOut=true.
// CRC16: catalog params width=16, poly=0x1021, init=0x496C, refIn=true, refOut=true.
//
// Right-shifting table-driven CRC using the reflected polynomial.
// Seeds are the reflected catalog init values: reflect(0xEE)=0x77, reflect(0x496C)=0x3692.
// Do NOT change these to the catalog values — it would silently break every CRC.

enum DUMLCRC {

    static let crc8InitReflected:  UInt8  = 0x77
    static let crc16InitReflected: UInt16 = 0x3692

    private static let crc8Table:  [UInt8]  = makeTable8(poly: 0x31)
    private static let crc16Table: [UInt16] = makeTable16(poly: 0x1021)

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = crc8InitReflected
        for byte in bytes { crc = crc8Table[Int(crc ^ byte)] }
        return crc
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = crc16InitReflected
        for byte in bytes { crc = (crc >> 8) ^ crc16Table[Int((crc ^ UInt16(byte)) & 0xFF)] }
        return crc
    }

    private static func makeTable8(poly: UInt8) -> [UInt8] {
        let reflected = reverseBits(poly)
        return (0..<256).map { i -> UInt8 in
            var c = UInt8(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ reflected : c >> 1 }
            return c
        }
    }

    private static func makeTable16(poly: UInt16) -> [UInt16] {
        let reflected = reverseBits16(poly)
        return (0..<256).map { i -> UInt16 in
            var c = UInt16(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ reflected : c >> 1 }
            return c
        }
    }

    private static func reverseBits(_ b: UInt8) -> UInt8 {
        var x = b
        x = ((x >> 1) & 0x55) | ((x & 0x55) << 1)
        x = ((x >> 2) & 0x33) | ((x & 0x33) << 2)
        x = ((x >> 4) & 0x0F) | ((x & 0x0F) << 4)
        return x
    }

    private static func reverseBits16(_ v: UInt16) -> UInt16 {
        var x = v
        x = ((x >> 1) & 0x5555) | ((x & 0x5555) << 1)
        x = ((x >> 2) & 0x3333) | ((x & 0x3333) << 2)
        x = ((x >> 4) & 0x0F0F) | ((x & 0x0F0F) << 4)
        x = ((x >> 8) & 0x00FF) | ((x & 0x00FF) << 8)
        return x
    }
}

// MARK: - Frame

struct DUMLFrame {
    let target:  UInt16
    let seq:     UInt16  // big-endian on the wire (only BE field)
    let flags:   UInt8
    let cmdSet:  UInt8
    let cmdId:   UInt8
    let payload: [UInt8]

    var sender:   UInt8 { UInt8(target & 0xFF) }
    var receiver: UInt8 { UInt8((target >> 8) & 0xFF) }
    var isResponse: Bool { (flags & 0x80) != 0 }

    func encode() -> [UInt8] {
        let totalLen = 13 + payload.count
        precondition(totalLen <= 0x3FF, "DUML frame exceeds 10-bit length field")

        var buf = [UInt8](repeating: 0, count: totalLen)
        let version: UInt8 = 1

        buf[0] = 0x55
        buf[1] = UInt8(totalLen & 0xFF)
        buf[2] = UInt8((totalLen >> 8) & 0x03) | (version << 2)
        buf[3] = DUMLCRC.crc8(Array(buf[0..<3]))
        buf[4] = UInt8(target & 0xFF)
        buf[5] = UInt8((target >> 8) & 0xFF)
        buf[6] = UInt8((seq >> 8) & 0xFF) // seq is big-endian
        buf[7] = UInt8(seq & 0xFF)
        buf[8] = flags
        buf[9] = cmdSet
        buf[10] = cmdId
        for (i, b) in payload.enumerated() { buf[11 + i] = b }
        let crc = DUMLCRC.crc16(Array(buf[0..<(totalLen - 2)]))
        buf[totalLen - 2] = UInt8(crc & 0xFF)
        buf[totalLen - 1] = UInt8((crc >> 8) & 0xFF)
        return buf
    }

    static func decode(_ data: [UInt8]) -> DUMLFrame? {
        guard data.count >= 13, data[0] == 0x55 else { return nil }
        let len = Int(data[1]) | ((Int(data[2]) & 0x03) << 8)
        guard len >= 13, data.count >= len else { return nil }
        guard DUMLCRC.crc8(Array(data[0..<3])) == data[3] else { return nil }
        let bodyCRC = DUMLCRC.crc16(Array(data[0..<(len - 2)]))
        let recvCRC = UInt16(data[len - 2]) | (UInt16(data[len - 1]) << 8)
        guard bodyCRC == recvCRC else { return nil }
        let target = UInt16(data[4]) | (UInt16(data[5]) << 8)
        let seq    = (UInt16(data[6]) << 8) | UInt16(data[7])
        return DUMLFrame(target: target, seq: seq, flags: data[8],
                         cmdSet: data[9], cmdId: data[10],
                         payload: Array(data[11..<(len - 2)]))
    }
}

// MARK: - Stream parser (actor for thread-safe access)

actor DUMLStreamParser {
    private var buffer: [UInt8] = []

    func append(_ chunk: [UInt8]) -> [DUMLFrame] {
        buffer.append(contentsOf: chunk)
        var out: [DUMLFrame] = []
        while buffer.count >= 13 {
            guard let magic = buffer.firstIndex(of: 0x55) else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            if magic > 0 { buffer.removeFirst(magic) }
            if buffer.count < 4 { break }
            let len = Int(buffer[1]) | ((Int(buffer[2]) & 0x03) << 8)
            if len < 13 || len > 1024 { buffer.removeFirst(1); continue }
            if buffer.count < len { break }
            let frameBytes = Array(buffer[0..<len])
            buffer.removeFirst(len)
            if let frame = DUMLFrame.decode(frameBytes) { out.append(frame) }
        }
        return out
    }

    func reset() { buffer.removeAll(keepingCapacity: true) }
}

// MARK: - Sequence counter (@MainActor — always called from GimbalController)

@MainActor
final class DUMLSequencer {
    private var seq: UInt16
    init(initial: UInt16 = 0x0100) { seq = initial }
    func next() -> UInt16 { let v = seq; seq = seq &+ 1; return v }
}

// MARK: - Pack helpers

enum DUMLPack {
    static func string(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        precondition(bytes.count <= 255)
        return [UInt8(bytes.count)] + bytes
    }
}

// MARK: - Comparable clamp helper

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { max(lo, min(hi, self)) }
}

// MARK: - Gimbal payload builder (pure, no state)

enum GimbalPayloadBuilder {

    static func recenter() -> (cmdId: UInt8, payload: [UInt8]) {
        var p = i16(0) + i16(0) + i16(0)  // yaw=0, roll=0, pitch=0
        p.append(DUML.RotationMode.absolute.rawValue)  // mode=ABSOLUTE
        p.append(DUML.GimbalPayload.defaultDuration)
        return (DUML.GimbalCmd.absAngle, p)
    }

    static func setMode(_ mode: DUML.GimbalMode) -> (cmdId: UInt8, payload: [UInt8]) {
        (DUML.GimbalCmd.setMode, [mode.rawValue, 0x00])
    }

    static func setAngle(pitchDeg: Double, yawDeg: Double,
                         durationSec: Double = 1.0) -> (cmdId: UInt8, payload: [UInt8]) {
        let p   = Int16(clamping: Int(-pitchDeg * 10).clamped(-1800, 1800))  // Pitch direction inverted
        let y   = Int16(clamping: Int(yawDeg   * 10).clamped(-1800, 1800))
        let dur = UInt8(min(255, max(1, Int(durationSec * 10))))
        // OM3 absAngle (0x14) wire layout: [yaw:i16LE, roll:i16LE, pitch:i16LE, mode:u8, time:u8]
        // Verified against OM Research (alkersan/om-research) — mode=0x05 for ABSOLUTE.
        // NOTE: Pitch direction is inverted on OM3 — negative pitch commands move up.
        var payload = i16(y) + i16(0) + i16(p)
        payload.append(DUML.RotationMode.absolute.rawValue)
        payload.append(dur)
        return (DUML.GimbalCmd.absAngle, payload)
    }

    static func setSpeed(pitchDeg: Double, yawDeg: Double) -> (cmdId: UInt8, payload: [UInt8]) {
        let p = Int16(clamping: Int(-pitchDeg * 10).clamped(-1800, 1800))  // Pitch direction inverted
        let y = Int16(clamping: Int(yawDeg   * 10).clamped(-1800, 1800))
        // OM3 speedCtrl (0x0c) wire layout: [yaw:i16LE, roll:i16LE, pitch:i16LE, mode:u8, time:u8]
        // mode=0x80 for SPEED (velocity control), time=0 for continuous.
        // NOTE: Pitch direction is inverted on OM3 — negative pitch commands move up.
        var payload = i16(y) + i16(0) + i16(p)
        payload.append(DUML.RotationMode.speed.rawValue)
        payload.append(0)  // time=0 for continuous velocity mode
        return (DUML.GimbalCmd.speedCtrl, payload)
    }

    static func pairingPin(identifier: String, pin: String) -> (cmdId: UInt8, payload: [UInt8]) {
        (DUML.WifiCmd.setPairingPin, DUMLPack.string(identifier) + DUMLPack.string(pin))
    }

    private static func i16(_ v: Int16) -> [UInt8] {
        [UInt8(bitPattern: Int8(truncatingIfNeeded: v)),
         UInt8(bitPattern: Int8(truncatingIfNeeded: v >> 8))]
    }
}
