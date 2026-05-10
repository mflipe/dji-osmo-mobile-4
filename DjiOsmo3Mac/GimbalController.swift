import Foundation
import Combine
import CoreBluetooth

// High-level gimbal controller. Owns the BLEManager, builds DUML frames,
// parses telemetry, and exposes observable state to SwiftUI.
@MainActor
final class GimbalController: NSObject, ObservableObject {

    // MARK: Connection state

    enum ConnectionState: Equatable {
        case idle
        case scanning
        case connecting
        case discoveringServices
        case connected
        case pairing
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Disconnected"
            case .scanning: return "Scanning…"
            case .connecting: return "Connecting…"
            case .discoveringServices: return "Discovering services…"
            case .connected: return "Connected"
            case .pairing: return "Pairing…"
            case .ready: return "Ready"
            case .failed(let s): return "Failed: \(s)"
            }
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case follow = "Follow"
        case lock = "Lock"
        case sport = "Sport" // mapped to FPV on the wire

        var id: String { rawValue }

        var dumlValue: DUML.GimbalMode {
            switch self {
            case .follow: return .follow
            case .lock:   return .lock
            case .sport:  return .fpv
            }
        }
    }

    // MARK: Published state

    @Published var bleState: CBManagerState = .unknown
    @Published var connectionState: ConnectionState = .idle
    @Published var devices: [DiscoveredPeripheral] = []
    @Published var selected: DiscoveredPeripheral?
    @Published var mode: Mode = .follow
    @Published var pitch: Double = 0   // degrees, telemetry
    @Published var roll: Double = 0
    @Published var yaw: Double = 0
    @Published var battery: Int? = nil
    @Published private(set) var log: [LogEntry] = []
    @Published var pin: String = DUML.defaultPin
    @Published var identifier: String = DUML.defaultIdentifier
    @Published var autoPair: Bool = true

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let direction: Direction
        let text: String
        enum Direction { case info, tx, rx, err }
    }

    // MARK: Internals

    private let ble = BLEManager()
    private let seq = DUMLSequencer()
    private var pairingTimer: Timer?

    override init() {
        super.init()
        ble.delegate = self
    }

    // MARK: User actions

    func startScan() {
        connectionState = .scanning
        ble.startScan()
    }

    func stopScan() {
        ble.stopScan()
        if case .scanning = connectionState { connectionState = .idle }
    }

    func connect(_ device: DiscoveredPeripheral) {
        selected = device
        connectionState = .connecting
        ble.connect(device.id)
    }

    func disconnect() {
        ble.disconnect()
    }

    // MARK: Pairing

    func startPairing() {
        connectionState = .pairing
        ble.writePairingTrigger()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.sendPairingPin()
        }
        // Fall back to .ready after 4s even without an explicit ack — the OM3
        // accepts gimbal commands even before WiFi pairing completes.
        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if case .pairing = self.connectionState {
                    self.appendLog(.info, "Pairing timeout — proceeding (gimbal commands often work without it).")
                    self.connectionState = .ready
                }
            }
        }
    }

    private func sendPairingPin() {
        let payload = DUMLPack.string(identifier) + DUMLPack.string(pin)
        let frame = DUMLFrame(
            target: DUML.target(from: .app, to: .wifi),
            seq: seq.next(),
            flags: DUML.Flag.request,
            cmdSet: DUML.CmdSet.wifi,
            cmdId: DUML.WifiCmd.setPairingPin,
            payload: payload
        )
        send(frame, label: "SetPairingPIN")
    }

    // MARK: Gimbal commands

    func recenter() {
        // Absolute angle (0,0,0) on all axes, ~3s duration.
        var p: [UInt8] = []
        p.append(contentsOf: i16le(0)) // pitch ×0.1°
        p.append(contentsOf: i16le(0)) // roll
        p.append(contentsOf: i16le(0)) // yaw
        p.append(0x07)                  // axis flags: pitch|roll|yaw
        p.append(30)                    // duration ×0.1s
        sendGimbal(cmd: DUML.GimbalCmd.absAngle, payload: p, label: "Recenter")
    }

    func setMode(_ m: Mode) {
        mode = m
        let payload: [UInt8] = [m.dumlValue.rawValue, 0x00]
        sendGimbal(cmd: DUML.GimbalCmd.setMode, payload: payload, label: "SetMode(\(m.rawValue))")
    }

    // Absolute angle command: pitch & yaw in degrees (roll left at 0).
    // Used by sliders.
    func setAngle(pitchDeg: Double, yawDeg: Double, durationSec: Double = 1.0) {
        let pitch = Int16(clamping: Int(pitchDeg * 10).clamped(-1800, 1800))
        let yaw   = Int16(clamping: Int(yawDeg * 10).clamped(-1800, 1800))
        var p: [UInt8] = []
        p.append(contentsOf: i16le(pitch))
        p.append(contentsOf: i16le(0))    // roll
        p.append(contentsOf: i16le(yaw))
        p.append(0x05)                     // pitch + yaw only
        p.append(UInt8(min(255, max(1, Int(durationSec * 10)))))
        sendGimbal(cmd: DUML.GimbalCmd.absAngle, payload: p, label: "Angle(p=\(pitchDeg)°, y=\(yawDeg)°)")
    }

    // Velocity control (degrees/s).
    func setSpeed(pitchDeg: Double, yawDeg: Double) {
        let pitch = Int16(clamping: Int(pitchDeg * 10).clamped(-1800, 1800))
        let yaw   = Int16(clamping: Int(yawDeg * 10).clamped(-1800, 1800))
        var p: [UInt8] = []
        p.append(contentsOf: i16le(pitch))
        p.append(contentsOf: i16le(0))    // roll
        p.append(contentsOf: i16le(yaw))
        p.append(0x01)                     // enable bit
        sendGimbal(cmd: DUML.GimbalCmd.speedCtrl, payload: p, label: "Speed(p=\(pitchDeg), y=\(yawDeg))")
    }

    func stopMotion() {
        setSpeed(pitchDeg: 0, yawDeg: 0)
    }

    // MARK: Sending

    private func sendGimbal(cmd: UInt8, payload: [UInt8], label: String) {
        let frame = DUMLFrame(
            target: DUML.target(from: .app, to: .gimbal),
            seq: seq.next(),
            flags: DUML.Flag.request,
            cmdSet: DUML.CmdSet.gimbal,
            cmdId: cmd,
            payload: payload
        )
        send(frame, label: label)
    }

    private func send(_ frame: DUMLFrame, label: String) {
        let bytes = frame.encode()
        appendLog(.tx, "→ \(label) [\(hex(bytes))]")
        ble.writeDUML(frame)
    }

    // MARK: Log

    private func appendLog(_ d: LogEntry.Direction, _ text: String) {
        let e = LogEntry(timestamp: Date(), direction: d, text: text)
        log.append(e)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    func clearLog() { log.removeAll() }

    // MARK: Helpers

    private func i16le(_ v: Int16) -> [UInt8] {
        [UInt8(bitPattern: Int8(truncatingIfNeeded: v)),
         UInt8(bitPattern: Int8(truncatingIfNeeded: v >> 8))]
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// MARK: - BLEManagerDelegate

extension GimbalController: BLEManagerDelegate {

    nonisolated func bleStateChanged(_ state: CBManagerState) {
        Task { @MainActor in
            self.bleState = state
            if state != .poweredOn, case .ready = self.connectionState {
                self.connectionState = .idle
            }
        }
    }

    nonisolated func bleDiscovered(_ devices: [DiscoveredPeripheral]) {
        Task { @MainActor in self.devices = devices }
    }

    nonisolated func bleConnected(_ device: DiscoveredPeripheral) {
        Task { @MainActor in
            self.selected = device
            self.connectionState = .discoveringServices
        }
    }

    nonisolated func bleDisconnected(_ error: Error?) {
        Task { @MainActor in
            self.connectionState = .idle
            self.selected = nil
            self.pitch = 0; self.roll = 0; self.yaw = 0
        }
    }

    nonisolated func bleReady() {
        Task { @MainActor in
            self.connectionState = .connected
            self.appendLog(.info, "BLE characteristics ready.")
            if self.autoPair {
                self.startPairing()
            } else {
                self.connectionState = .ready
            }
        }
    }

    nonisolated func bleReceived(_ frame: DUMLFrame) {
        Task { @MainActor in self.handleFrame(frame) }
    }

    nonisolated func bleLog(_ message: String) {
        Task { @MainActor in self.appendLog(.info, message) }
    }

    @MainActor
    private func handleFrame(_ frame: DUMLFrame) {
        // Gimbal telemetry push (cmdSet=0x04, cmdId=0x05).
        if frame.cmdSet == DUML.CmdSet.gimbal,
           frame.cmdId == DUML.GimbalCmd.pushPos,
           frame.payload.count >= 6 {
            let p = frame.payload
            let pitchRaw = Int16(bitPattern: UInt16(p[0]) | (UInt16(p[1]) << 8))
            let rollRaw  = Int16(bitPattern: UInt16(p[2]) | (UInt16(p[3]) << 8))
            let yawRaw   = Int16(bitPattern: UInt16(p[4]) | (UInt16(p[5]) << 8))
            self.pitch = Double(pitchRaw) / 10.0
            self.roll  = Double(rollRaw) / 10.0
            self.yaw   = Double(yawRaw) / 10.0
            return
        }

        // Battery (cmdSet=0x0D / 0x06).
        if (frame.cmdSet == 0x0D || frame.cmdSet == DUML.CmdSet.battery),
           let first = frame.payload.first {
            self.battery = Int(first)
        }

        // Pairing responses.
        if frame.cmdSet == DUML.CmdSet.wifi {
            if frame.cmdId == DUML.WifiCmd.setPairingPin && (frame.flags & 0x80) != 0 {
                let status = frame.payload.count >= 2 ? frame.payload[1] : (frame.payload.first ?? 0)
                if status == 0x01 {
                    appendLog(.rx, "Already paired.")
                    pairingTimer?.invalidate()
                    connectionState = .ready
                } else if status == 0x02 {
                    appendLog(.rx, "Pairing required — confirm on the gimbal.")
                }
            } else if frame.cmdId == DUML.WifiCmd.pairingApproved,
                      frame.payload.first == 0x01 {
                appendLog(.rx, "Pairing approved.")
                pairingTimer?.invalidate()
                connectionState = .ready
            }
        }

        // Generic log line for unhandled frames (rate-limited by log cap).
        appendLog(.rx,
            String(format: "← cmdSet=%02X cmdId=%02X flags=%02X len=%d",
                   frame.cmdSet, frame.cmdId, frame.flags, frame.payload.count))
    }
}

// MARK: - Utilities

private extension Comparable {
    func clamped(_ a: Self, _ b: Self) -> Self { max(a, min(b, self)) }
}
