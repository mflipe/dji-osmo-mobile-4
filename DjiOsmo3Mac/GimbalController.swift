import AppKit
import Foundation
import Combine
import CoreBluetooth
import CoreMedia

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

    // Tracking
    @Published var isTracking = false
    @Published var trackingBounds: CGRect? = nil

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let direction: Direction
        let text: String
        enum Direction { case info, tx, rx, err }
    }

    // MARK: Dependencies

    private let ble = BLEManager()
    private let seq = DUMLSequencer()
    private var pairingTimer: Timer?

    let cameraManager = CameraManager()
    let settings = SettingsModel()
    private let tracking = TrackingEngine()

    // Keyboard joystick: tracks currently-pressed keys.
    private var heldKeys: Set<String> = []
    private var joystickTimer: Timer?

    override init() {
        super.init()
        ble.delegate = self
        setupTrackingPipeline()
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
        var p: [UInt8] = []
        p.append(contentsOf: i16le(0)); p.append(contentsOf: i16le(0)); p.append(contentsOf: i16le(0))
        p.append(0x07)
        p.append(30)
        sendGimbal(cmd: DUML.GimbalCmd.absAngle, payload: p, label: "Recenter")
    }

    func setMode(_ m: Mode) {
        mode = m
        sendGimbal(cmd: DUML.GimbalCmd.setMode, payload: [m.dumlValue.rawValue, 0x00], label: "SetMode(\(m.rawValue))")
    }

    func setAngle(pitchDeg: Double, yawDeg: Double, durationSec: Double = 1.0) {
        let p = Int16(clamping: Int(pitchDeg * 10).clamped(-1800, 1800))
        let y = Int16(clamping: Int(yawDeg * 10).clamped(-1800, 1800))
        var payload: [UInt8] = []
        payload.append(contentsOf: i16le(p)); payload.append(contentsOf: i16le(0)); payload.append(contentsOf: i16le(y))
        payload.append(0x05)
        payload.append(UInt8(min(255, max(1, Int(durationSec * 10)))))
        sendGimbal(cmd: DUML.GimbalCmd.absAngle, payload: payload, label: "Angle(p=\(pitchDeg)°, y=\(yawDeg)°)")
    }

    func setSpeed(pitchDeg: Double, yawDeg: Double) {
        let scale = settings.sportMode ? 2.0 : 1.0
        let panSign: Double = settings.invertPan ? -1 : 1
        let tiltSign: Double = settings.invertTilt ? -1 : 1

        let rawPitch = pitchDeg * scale * tiltSign
        let rawYaw   = yawDeg   * scale * panSign

        let p = Int16(clamping: Int(rawPitch * 10).clamped(-1800, 1800))
        let y = Int16(clamping: Int(rawYaw   * 10).clamped(-1800, 1800))
        var payload: [UInt8] = []
        payload.append(contentsOf: i16le(p)); payload.append(contentsOf: i16le(0)); payload.append(contentsOf: i16le(y))
        payload.append(0x01)
        sendGimbal(cmd: DUML.GimbalCmd.speedCtrl, payload: payload, label: "Speed(p=\(pitchDeg), y=\(yawDeg))")
    }

    func stopMotion() { setSpeed(pitchDeg: 0, yawDeg: 0) }

    func calibrate() {
        // Calibration cmd ID TBD — will be confirmed via device log.
        appendLog(.info, "Calibrate: cmd ID TBD — connect and check RX log.")
    }

    // MARK: Tracking

    func toggleTracking() {
        tracking.toggle()
        isTracking = tracking.isActive
        if !isTracking { trackingBounds = nil; stopMotion() }
    }

    func setTrackingTarget(faceOnly: Bool) {
        tracking.target = faceOnly ? .face : .body
        tracking.reset()
    }

    private func setupTrackingPipeline() {
        cameraManager.frameHandler = { [weak self] buffer in
            guard let self else { return }
            guard let out = self.tracking.process(sampleBuffer: buffer) else { return }
            Task { @MainActor in
                self.trackingBounds = out.bounds
                if self.isReady {
                    self.setSpeed(pitchDeg: out.pitch, yawDeg: out.yaw)
                }
            }
        }
    }

    // MARK: Keyboard joystick

    func keyDown(_ key: String) {
        guard heldKeys.insert(key).inserted else { return }
        if joystickTimer == nil {
            joystickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                self?.applyKeyboardJoystick()
            }
        }
    }

    func keyUp(_ key: String) {
        heldKeys.remove(key)
        if heldKeys.isEmpty {
            joystickTimer?.invalidate()
            joystickTimer = nil
            stopMotion()
        }
    }

    private func applyKeyboardJoystick() {
        guard isReady else { return }
        var p: Double = 0, y: Double = 0
        let speed = settings.joystickSpeed.degreesPerSecond

        if heldKeys.contains("w") || heldKeys.contains(String(UnicodeScalar(NSUpArrowFunctionKey)!))    { p += speed }
        if heldKeys.contains("s") || heldKeys.contains(String(UnicodeScalar(NSDownArrowFunctionKey)!))  { p -= speed }
        if heldKeys.contains("a") || heldKeys.contains(String(UnicodeScalar(NSLeftArrowFunctionKey)!))  { y -= speed }
        if heldKeys.contains("d") || heldKeys.contains(String(UnicodeScalar(NSRightArrowFunctionKey)!)) { y += speed }

        switch settings.axisMode {
        case .horizontal: p = 0
        case .vertical:   y = 0
        case .free:       break
        }

        setSpeed(pitchDeg: p, yawDeg: y)
    }

    // MARK: Physical button handlers (cmd IDs are TBD — update DUML.ButtonCmd when confirmed)

    private func handleButtonFrame(_ frame: DUMLFrame) {
        guard frame.cmdSet == DUML.ButtonCmd.cmdSet else { return }
        switch frame.cmdId {
        case DUML.ButtonCmd.shutter:
            handleShutterPress(frame.payload)
        case DUML.ButtonCmd.joystick:
            handleJoystickNotify(frame.payload)
        case DUML.ButtonCmd.trigger:
            handleTriggerPress(frame.payload)
        case DUML.ButtonCmd.mButton:
            handleMButtonPress(frame.payload)
        case DUML.ButtonCmd.zoom:
            handleZoomSlider(frame.payload)
        default:
            break
        }
    }

    private func handleShutterPress(_ payload: [UInt8]) {
        let held = payload.first == 0x02
        if held {
            cameraManager.startBurst()
        } else {
            cameraManager.stopBurst()
            if cameraManager.captureMode == .video {
                cameraManager.toggleRecording()
            } else {
                cameraManager.capturePhoto()
            }
        }
    }

    private func handleJoystickNotify(_ payload: [UInt8]) {
        guard isReady, payload.count >= 4 else { return }
        let rawX = Int16(bitPattern: UInt16(payload[0]) | UInt16(payload[1]) << 8)
        let rawY = Int16(bitPattern: UInt16(payload[2]) | UInt16(payload[3]) << 8)
        let speed = settings.joystickSpeed.degreesPerSecond
        let yaw   = Double(rawX) / 1000.0 * speed
        let pitch = Double(rawY) / 1000.0 * speed
        setSpeed(pitchDeg: pitch, yawDeg: yaw)
    }

    private func handleTriggerPress(_ payload: [UInt8]) {
        let clicks = payload.first ?? 1
        switch clicks {
        case 1:
            if isTracking { toggleTracking() }
        case 2:
            recenter()
        case 3:
            cameraManager.switchToNextCamera()
        default:
            break
        }
    }

    private func handleMButtonPress(_ payload: [UInt8]) {
        let clicks = payload.first ?? 1
        switch clicks {
        case 1:
            switch settings.mButtonAction {
            case .toggleMode:
                let modes = Mode.allCases
                let next = modes[(modes.firstIndex(of: mode)! + 1) % modes.count]
                setMode(next)
            case .openPanel:
                break  // handled in UI
            }
        case 2:
            break  // landscape/portrait toggle — handled in UI
        case 3:
            if isTracking { toggleTracking() }
        default:
            break
        }
    }

    private func handleZoomSlider(_ payload: [UInt8]) {
        guard let raw = payload.first else { return }
        let delta: CGFloat = raw > 127 ? 0.5 : -0.5
        cameraManager.adjustZoom(delta: delta)
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
        let encoded = frame.encode()
        appendLog(.tx, "→ \(label) [\(hex(encoded))]")
        ble.writeDUML(frame, encoded: encoded)
    }

    // MARK: Log

    private func appendLog(_ d: LogEntry.Direction, _ text: String) {
        let e = LogEntry(timestamp: Date(), direction: d, text: text)
        log.append(e)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    func clearLog() { log.removeAll() }

    // MARK: Helpers

    var isReady: Bool {
        switch connectionState {
        case .ready, .connected: return true
        default: return false
        }
    }

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
            if self.autoPair { self.startPairing() } else { self.connectionState = .ready }
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
        if frame.cmdSet == DUML.CmdSet.gimbal, frame.cmdId == DUML.GimbalCmd.pushPos,
           frame.payload.count >= 6 {
            let p = frame.payload
            pitch = Double(Int16(bitPattern: UInt16(p[0]) | UInt16(p[1]) << 8)) / 10.0
            roll  = Double(Int16(bitPattern: UInt16(p[2]) | UInt16(p[3]) << 8)) / 10.0
            yaw   = Double(Int16(bitPattern: UInt16(p[4]) | UInt16(p[5]) << 8)) / 10.0
            return
        }

        // Battery (cmdSet=0x0D / 0x06).
        if (frame.cmdSet == 0x0D || frame.cmdSet == DUML.CmdSet.battery),
           let first = frame.payload.first {
            battery = Int(first)
        }

        // Physical button events.
        handleButtonFrame(frame)

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
            } else if frame.cmdId == DUML.WifiCmd.pairingApproved, frame.payload.first == 0x01 {
                appendLog(.rx, "Pairing approved.")
                pairingTimer?.invalidate()
                connectionState = .ready
            }
        }

        appendLog(.rx,
            String(format: "← cmdSet=%02X cmdId=%02X flags=%02X len=%d",
                   frame.cmdSet, frame.cmdId, frame.flags, frame.payload.count))
    }
}

// MARK: - Utilities

extension Comparable {
    func clamped(_ a: Self, _ b: Self) -> Self { max(a, min(b, self)) }
}
