import Foundation

// MARK: - DUML Protocol Constants
//
// Wire format:
//   [0x55][len_lo][ver<<2 | len_hi][crc8][target:2 LE]
//   [seq:2 BE][flags][cmdSet][cmdId][payload][crc16:2 LE]
//
// totalLen = 13 + payloadLen.

enum DUML {

    // Subsystem addresses (sender / receiver).
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
        static let controlPWM: UInt8 = 0x01 // 3× uint16 LE in [363..1685], center=1024
        static let getPos:     UInt8 = 0x02
        static let pushPos:    UInt8 = 0x05 // telemetry push (~20 Hz)
        static let angleSet:   UInt8 = 0x0A // absolute angle
        static let speedCtrl:  UInt8 = 0x0C // angular velocity
        static let absAngle:   UInt8 = 0x14 // absolute angle with duration
        static let movement:   UInt8 = 0x15 // incremental
        static let setMode:    UInt8 = 0x4C // 0=lock, 1=follow, 2=fpv (sport)
    }

    // RC / button notification IDs — cmdSet = 0x06.
    // Actual values must be confirmed by pressing each physical button on the OM3
    // while watching the RX log (GimbalController logs all unknown frames).
    enum ButtonCmd {
        static let cmdSet: UInt8 = 0x06        // TBD: verify against live device log
        static let shutter:  UInt8 = 0x01      // TBD
        static let joystick: UInt8 = 0x02      // TBD
        static let trigger:  UInt8 = 0x03      // TBD
        static let mButton:  UInt8 = 0x04      // TBD
        static let zoom:     UInt8 = 0x05      // TBD
    }

    enum WifiCmd {
        static let setPairingPin:  UInt8 = 0x45
        static let pairingApproved: UInt8 = 0x46
        static let wifiConnect:    UInt8 = 0x47
    }

    enum GimbalMode: UInt8 {
        case lock   = 0
        case follow = 1
        case fpv    = 2 // OM3 "Sport" maps here
    }

    // BLE UUIDs.
    enum BLEUUID {
        static let service = "FFF0"
        static let charFFF3 = "FFF3"
        static let charFFF4 = "FFF4"
        static let charFFF5 = "FFF5"
    }

    static let defaultPin = "love"
    static let defaultIdentifier = "001749319286102"
}

// MARK: - CRC

// CRC8: catalog params width=8, poly=0x31, init=0xEE, refIn=true, refOut=true, xorOut=0x00.
// CRC16: catalog params width=16, poly=0x1021, init=0x496C, refIn=true, refOut=true, xorOut=0x0000.
//
// Implemented as a right-shifting table-driven CRC using the *reflected*
// polynomial. With refIn=refOut=true this is mathematically equivalent to the
// canonical left-shifting algorithm — but the seed must be the reflected form
// of the catalog init: reflect(0xEE)=0x77, reflect(0x496C)=0x3692.
// Validated against `crc-full` (used by lib-osmo-ble and node-osmo).

enum DUMLCRC {

    // Pre-reflected init values (catalog values reflected over their width).
    static let crc8InitReflected:  UInt8  = 0x77   // reflect(0xEE, 8)
    static let crc16InitReflected: UInt16 = 0x3692 // reflect(0x496C, 16)

    private static let crc8Table: [UInt8] = makeTable8(poly: 0x31)
    private static let crc16Table: [UInt16] = makeTable16(poly: 0x1021)

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = crc8InitReflected
        for byte in bytes {
            let idx = Int(crc ^ byte)
            crc = crc8Table[idx]
        }
        return crc
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = crc16InitReflected
        for byte in bytes {
            let idx = Int((crc ^ UInt16(byte)) & 0xFF)
            crc = (crc >> 8) ^ crc16Table[idx]
        }
        return crc
    }

    private static func makeTable8(poly: UInt8) -> [UInt8] {
        // Reflected polynomial for LSB-first calculation.
        let reflected = reverseBits(poly)
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt8(i)
            for _ in 0..<8 {
                if (c & 0x01) != 0 {
                    c = (c >> 1) ^ reflected
                } else {
                    c >>= 1
                }
            }
            table[i] = c
        }
        return table
    }

    private static func makeTable16(poly: UInt16) -> [UInt16] {
        let reflected = reverseBits16(poly)
        var table = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt16(i)
            for _ in 0..<8 {
                if (c & 0x0001) != 0 {
                    c = (c >> 1) ^ reflected
                } else {
                    c >>= 1
                }
            }
            table[i] = c
        }
        return table
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
    let target: UInt16          // sender | (receiver << 8)
    let seq: UInt16             // big-endian on the wire
    let flags: UInt8
    let cmdSet: UInt8
    let cmdId: UInt8
    let payload: [UInt8]

    var sender: UInt8   { UInt8(target & 0xFF) }
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

        // target — little-endian
        buf[4] = UInt8(target & 0xFF)
        buf[5] = UInt8((target >> 8) & 0xFF)

        // seq — big-endian (the only BE field)
        buf[6] = UInt8((seq >> 8) & 0xFF)
        buf[7] = UInt8(seq & 0xFF)

        buf[8] = flags
        buf[9] = cmdSet
        buf[10] = cmdId

        for (i, b) in payload.enumerated() {
            buf[11 + i] = b
        }

        let crc = DUMLCRC.crc16(Array(buf[0..<(totalLen - 2)]))
        buf[totalLen - 2] = UInt8(crc & 0xFF)
        buf[totalLen - 1] = UInt8((crc >> 8) & 0xFF)
        return buf
    }

    static func decode(_ data: [UInt8]) -> DUMLFrame? {
        guard data.count >= 13, data[0] == 0x55 else { return nil }
        let len = Int(data[1]) | ((Int(data[2]) & 0x03) << 8)
        guard len >= 13, data.count >= len else { return nil }

        let headerCRC = DUMLCRC.crc8(Array(data[0..<3]))
        guard headerCRC == data[3] else { return nil }

        let bodyCRC = DUMLCRC.crc16(Array(data[0..<(len - 2)]))
        let recvCRC = UInt16(data[len - 2]) | (UInt16(data[len - 1]) << 8)
        guard bodyCRC == recvCRC else { return nil }

        let target = UInt16(data[4]) | (UInt16(data[5]) << 8)
        let seq = (UInt16(data[6]) << 8) | UInt16(data[7])
        return DUMLFrame(
            target: target,
            seq: seq,
            flags: data[8],
            cmdSet: data[9],
            cmdId: data[10],
            payload: Array(data[11..<(len - 2)])
        )
    }
}

// Reassembles DUML frames from a stream of BLE notification chunks.
final class DUMLStreamParser {
    private var buffer: [UInt8] = []

    func append(_ chunk: [UInt8]) -> [DUMLFrame] {
        buffer.append(contentsOf: chunk)
        var out: [DUMLFrame] = []

        while buffer.count >= 13 {
            // Resync to 0x55.
            guard let magic = buffer.firstIndex(of: 0x55) else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            if magic > 0 {
                buffer.removeFirst(magic)
            }
            if buffer.count < 4 { break }

            let len = Int(buffer[1]) | ((Int(buffer[2]) & 0x03) << 8)
            if len < 13 || len > 1024 {
                buffer.removeFirst(1)
                continue
            }
            if buffer.count < len { break }

            let frameBytes = Array(buffer[0..<len])
            buffer.removeFirst(len)

            if let frame = DUMLFrame.decode(frameBytes) {
                out.append(frame)
            }
            // Bad CRC: drop the candidate and keep going from buffer.
        }
        return out
    }

    func reset() { buffer.removeAll(keepingCapacity: true) }
}

// MARK: - PackString

enum DUMLPack {
    static func string(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        precondition(bytes.count <= 255, "PackString exceeds 255 bytes")
        return [UInt8(bytes.count)] + bytes
    }
}

// MARK: - Sequence counter

final class DUMLSequencer {
    private var seq: UInt16
    private let lock = NSLock()

    init(initial: UInt16 = 0x0100) { self.seq = initial }

    func next() -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        let v = seq
        seq = seq &+ 1
        return v
    }
}
