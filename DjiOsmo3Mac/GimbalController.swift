import AppKit
import Foundation
import Combine
import CoreBluetooth
import CoreMedia

// MARK: - GimbalController

@MainActor
final class GimbalController: NSObject, ObservableObject {

    // MARK: Connection state

    enum ConnectionState: Equatable {
        case idle, scanning, connecting, discoveringServices, connected, pairing, ready
        case failed(String)

        var label: String {
            switch self {
            case .idle:                return "Disconnected"
            case .scanning:            return "Scanning…"
            case .connecting:          return "Connecting…"
            case .discoveringServices: return "Discovering services…"
            case .connected:           return "Connected"
            case .pairing:             return "Pairing…"
            case .ready:               return "Ready"
            case .failed(let s):       return "Failed: \(s)"
            }
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case follow = "Follow"
        case lock   = "Lock"
        case sport  = "Sport"   // FPV on the wire

        var id: String { rawValue }

        var dumlMode: DUML.GimbalMode {
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
    @Published var pitch: Double = 0
    @Published var roll:  Double = 0
    @Published var yaw:   Double = 0
    @Published var battery: Int? = nil
    @Published var isCharging: Bool = false
    @Published var yawBody: Double = 0
    @Published var gimbalWaypoints: [(pitch: Double, yaw: Double)] = []
    @Published var gimbalTimelapseDuration: Double = 10.0
    @Published var gimbalTimelapseRunning: Bool = false
    @Published private(set) var log: [LogEntry] = []
    @Published var pin:        String = DUML.defaultPin
    @Published var identifier: String = DUML.defaultIdentifier
    @Published var autoPair:   Bool = true
    @Published var isTracking = false
    @Published var trackingBounds: CGRect? = nil
    @Published var newGimbalAlert: String? = nil
    // Last 14 telemetry positions for the minimap trail (~14 s at 1 Hz).
    @Published private(set) var positionHistory: [(pitch: Double, yaw: Double)] = []
    // Last user-initiated angle target (minimap click). Shown as orange dot on minimap.
    @Published private(set) var debugAngleTarget: (pitch: Double, yaw: Double)? = nil
    // Log filtering
    @Published var hideFrequentLogs: Bool = true  // hide repetitive RX/TX (getPos, joystickReport, etc.)
    @Published var showActionsOnly: Bool = false  // show only logs with action descriptions

    // Calibration routine
    @Published var calibrationActive: Bool = false
    @Published var calibrationStep: String = ""
    @Published var calibrationResults: [(name: String, expected: Double, actual: Double, passed: Bool)] = []

    // Manual calibration
    @Published var manualCalibrationActive: Bool = false
    @Published var manualCalibrationStep: Int = 0
    @Published var manualCalibrationData: [(label: String, pitch: Double, yaw: Double, roll: Double)] = []

    // Pitch mapping test
    @Published var pitchMappingTestActive: Bool = false
    @Published var pitchMappingTestResults: [(sent: Double, received: Double)] = []
    @Published var yawMappingTestActive: Bool = false
    @Published var yawMappingTestResults: [(sent: Double, received: Double)] = []
    @Published var pitchSpeedTestActive: Bool = false
    @Published var pitchSpeedTestResults: [(direction: String, initialPitch: Double, finalPitch: Double, movement: Double)] = []

    let manualCalibrationLabels = [
        "Center (posição inicial padrão)",
        "Máximo para cima",
        "Máximo para direita",
        "Máximo para baixo",
        "Máximo para esquerda",
        "Máximo para cima (novamente)",
        "Máximo para direita (fechando)",
        "Volta ao centro"
    ]

    // Detailed pairing feedback for the UI.
    enum PairingStep: Equatable {
        case idle
        case trigger(attempt: Int)   // 1..3 — sending trigger pulses
        case pin                     // PIN frame sent
        case waitingGimbal           // got status 0x02 — press trigger on gimbal
        case done
    }
    @Published var pairingStep: PairingStep = .idle

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let direction: Direction
        let text: String
        let action: String?  // "Pairing", "Tracking", "Angle", etc.
        let payload: [UInt8]?  // raw bytes for inspection
        enum Direction { case info, tx, rx, err }

        init(timestamp: Date, direction: Direction, text: String,
             action: String? = nil, payload: [UInt8]? = nil) {
            self.timestamp = timestamp
            self.direction = direction
            self.text = text
            self.action = action
            self.payload = payload
        }
    }

    // MARK: Dependencies (injected via protocol — enables testing)

    private let ble: any BLEServicing
    private let seq = DUMLSequencer()
    let cameraManager = CameraManager()
    let settings = SettingsModel()
    private let tracking = TrackingEngine()

    // MARK: Reactive pipelines

    private let frameSubject = PassthroughSubject<DUMLFrame, Never>()
    var frameEvents: AnyPublisher<DUMLFrame, Never> { frameSubject.eraseToAnyPublisher() }

    private var cancellables = Set<AnyCancellable>()
    private var pairingCancellable: AnyCancellable?
    private var keyboardTimerCancellable: AnyCancellable?
    private var joystickDriveCancellable: AnyCancellable?
    private var debugSettleCancellable: AnyCancellable?
    private var heartbeatCancellable: AnyCancellable?
    private var gimbalTimelapseCancellable: AnyCancellable?
    private var heldKeys: Set<String> = []
    private var joystickRatePitch: Double = 0
    private var joystickRateYaw: Double = 0

    // MARK: Init

    init(bleService: any BLEServicing = BLEManager()) {
        self.ble = bleService
        super.init()
        subscribeToBLEEvents()
        setupTrackingPipeline()
    }

    // MARK: BLE event subscription (replaces BLEManagerDelegate)

    private func subscribeToBLEEvents() {
        ble.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(bleEvent: event) }
            .store(in: &cancellables)
    }

    private func handle(bleEvent event: BLEEvent) {
        switch event {
        case .stateChanged(let state):
            bleState = state
            if state != .poweredOn, case .ready = connectionState { connectionState = .idle }

        case .discovered(let devs):
            let prevIDs = Set(devices.map(\.id))
            devices = devs
            if let newDev = devs.first(where: { !prevIDs.contains($0.id) }) {
                newGimbalAlert = newDev.name
            }

        case .connected(let device):
            selected = device
            connectionState = .discoveringServices

        case .disconnected:
            connectionState = .idle
            selected = nil
            pitch = 0; roll = 0; yaw = 0; yawBody = 0
            isCharging = false
            stopGimbalTimelapse()
            heartbeatCancellable = nil

        case .ready:
            connectionState = .connected
            appendLog(.info, "BLE characteristics ready.")
            if autoPair { startPairing() } else { connectionState = .ready; startHeartbeat() }

        case .received(let frame):
            frameSubject.send(frame)
            handleFrame(frame)

        case .log(let message):
            appendLog(.info, message)
        }
    }

    // MARK: User actions

    func startScan() { connectionState = .scanning; ble.startScan() }

    func stopScan() {
        ble.stopScan()
        if case .scanning = connectionState { connectionState = .idle }
    }

    func connect(_ device: DiscoveredPeripheral) {
        selected = device
        connectionState = .connecting
        ble.connect(device.id)
    }

    func disconnect() { ble.disconnect() }

    // MARK: Pairing (Combine timer replaces Timer.scheduledTimer)

    func startPairing() {
        connectionState = .pairing
        pairingStep = .trigger(attempt: 1)

        // Send trigger 3 times at 0 / 600ms / 1200ms.
        // The OM3 is intermittent: multiple pulses improve reliability.
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) { [weak self] in
                guard let self, case .pairing = self.connectionState else { return }
                self.ble.writePairingTrigger()
                self.pairingStep = .trigger(attempt: i + 1)
                self.appendLog(.info, "🔐 Pairing trigger \(i + 1)/3", action: "PairingTrigger")
            }
        }

        // Send PIN 300ms after the last trigger.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, case .pairing = self.connectionState else { return }
            self.pairingStep = .pin
            self.sendPairingPin()
            self.appendLog(.info, "🔐 Pairing PIN sent — awaiting gimbal confirmation…", action: "PairingPIN")
        }

        // Give the gimbal 8 s to respond (OM3 is slow with BLE ack).
        pairingCancellable = Timer.publish(every: 8, on: .main, in: .common)
            .autoconnect()
            .first()
            .sink { [weak self] _ in
                guard let self, case .pairing = self.connectionState else { return }
                // OM3 has no WiFi subsystem; DUML pairing frames are usually ignored.
                // Treat timeout as "paired" so gimbal commands can flow.
                self.appendLog(.info, "Pairing timeout — proceeding (OM3 may not require PIN).")
                self.pairingStep = .done
                self.connectionState = .ready
                self.startHeartbeat()
                self.sendFeatureControl()
            }
    }

    private func sendPairingPin() {
        let (cmdId, payload) = GimbalPayloadBuilder.pairingPin(identifier: identifier, pin: pin)
        let frame = DUMLFrame(target: DUML.target(from: .app, to: .wifi),
                              seq: seq.next(), flags: DUML.Flag.request,
                              cmdSet: DUML.CmdSet.wifi, cmdId: cmdId, payload: payload)
        send(frame, label: "SetPairingPIN")
    }

    // MARK: Gimbal commands

    func recenter() {
        let (cmdId, payload) = GimbalPayloadBuilder.recenter()
        appendLog(.info, "↻ Recenter gimbal to centre position", action: "Recenter")
        sendGimbal(cmd: cmdId, payload: payload, label: "Recenter", action: "Recenter")
    }

    func setMode(_ m: Mode) {
        mode = m
        let (cmdId, payload) = GimbalPayloadBuilder.setMode(m.dumlMode)
        appendLog(.info, "⟳ Switching gimbal mode → \(m.rawValue)", action: "SetMode")
        sendGimbal(cmd: cmdId, payload: payload, label: "SetMode(\(m.rawValue))", action: "SetMode")
    }

    func setAngle(pitchDeg: Double, yawDeg: Double, durationSec: Double = 1.0) {
        let (cmdId, payload) = GimbalPayloadBuilder.setAngle(pitchDeg: pitchDeg,
                                                              yawDeg: yawDeg,
                                                              durationSec: durationSec)
        let actionDesc = "⌖ Angle → p=\(String(format: "%+.0f", pitchDeg))° y=\(String(format: "%+.0f", yawDeg))°"
        appendLog(.info, actionDesc, action: "SetAngle")
        sendGimbal(cmd: cmdId, payload: payload,
                   label: "Angle(p=\(pitchDeg)°, y=\(yawDeg)°)", action: "SetAngle")
    }

    // User-initiated absolute move (minimap click). Wraps setAngle with debug logging:
    // logs the target immediately, then compares against actual telemetry after settling.
    func moveToAngle(pitchDeg: Double, yawDeg: Double) {
        let dist = sqrt(pow(pitchDeg - pitch, 2) + pow(yawDeg - yaw, 2))
        let dur  = (dist / 90).clamped(0.5, 3.0)

        debugAngleTarget = (pitchDeg, yawDeg)
        setAngle(pitchDeg: pitchDeg, yawDeg: yawDeg, durationSec: dur)

        appendLog(.info, String(format: "↗ Minimap target → Tilt %+.1f°  Pan %+.1f°  (dist %.0f°, ramp %.1fs)",
                                pitchDeg, yawDeg, dist, dur))

        // Wait for the ramp + 1 s settle, then compare telemetry to target.
        debugSettleCancellable?.cancel()
        debugSettleCancellable = Timer.publish(every: dur + 1.0, on: .main, in: .common)
            .autoconnect()
            .first()
            .sink { [weak self] _ in
                guard let self, let tgt = self.debugAngleTarget else { return }
                let dp = self.pitch - tgt.pitch
                let dy = self.yaw   - tgt.yaw
                let ok = abs(dp) < 3.0 && abs(dy) < 3.0
                self.appendLog(ok ? .info : .err,
                    String(format: "%@ Settle → Tilt %+.1f° Pan %+.1f°  ΔTilt %+.1f° ΔPan %+.1f°",
                           ok ? "✓" : "✗", self.pitch, self.yaw, dp, dy))
            }
    }

    func setSpeed(pitchDeg: Double, yawDeg: Double) {
        let panSign  = settings.invertPan  ? -1.0 : 1.0
        let tiltSign = settings.invertTilt ? -1.0 : 1.0
        let (cmdId, payload) = GimbalPayloadBuilder.setSpeed(
            pitchDeg: pitchDeg * tiltSign,
            yawDeg:   yawDeg   * panSign
        )
        if abs(pitchDeg) > 0.1 || abs(yawDeg) > 0.1 {
            appendLog(.info, "⟳ Speed → p=\(String(format: "%+.0f", pitchDeg))°/s y=\(String(format: "%+.0f", yawDeg))°/s",
                     action: "SetSpeed")
        }
        sendGimbal(cmd: cmdId, payload: payload,
                   label: "Speed(p=\(pitchDeg), y=\(yawDeg))")
    }

    private var lastMotionStopTime: Date = Date.distantPast

    func stopMotion() {
        guard Date().timeIntervalSince(lastMotionStopTime) > 0.1 else { return }
        lastMotionStopTime = Date()
        appendLog(.info, "⏸ Motion stopped", action: "StopMotion")
        setSpeed(pitchDeg: 0, yawDeg: 0)
    }

    func calibrate() {
        appendLog(.info, "🔧 Manual calibration initiated", action: "Calibrate")
    }

    // MARK: Calibration routine (rehearsal execution)

    func startCalibrationRoutine() {
        guard isReady else {
            appendLog(.err, "❌ Cannot start calibration: gimbal not ready", action: "CalibError")
            return
        }
        calibrationActive = true
        calibrationResults.removeAll()
        appendLog(.info, "📊 === CALIBRATION ROUTINE START ===", action: "CalibStart")

        let testPoints: [(name: String, pitch: Double, yaw: Double, expectedPitch: Double?, expectedYaw: Double?)] = [
            ("Center", 0, 0, 0, 0),
            ("Pitch Max (+45°)", 45, 0, 45, 0),
            ("Pitch Min (-90°)", -90, 0, -90, 0),
            ("Yaw Right (+160°)", 0, 160, 0, 160),
            ("Yaw Left (-160°)", 0, -160, 0, -160),
            ("Diagonal (+45°, +160°)", 45, 160, 45, 160),
            ("Diagonal (-90°, -160°)", -90, -160, -90, -160),
            ("Return Center", 0, 0, 0, 0),
        ]

        var index = 0
        func runNextTest() {
            guard index < testPoints.count, calibrationActive else {
                if calibrationActive {
                    appendLog(.info, "📊 === CALIBRATION ROUTINE COMPLETE ===", action: "CalibEnd")
                    calibrationActive = false
                }
                return
            }

            let test = testPoints[index]
            calibrationStep = "[\(index + 1)/\(testPoints.count)] \(test.name)"
            appendLog(.info, "📍 Test: \(test.name) → P=\(test.pitch)° Y=\(test.yaw)°", action: "CalibTest")

            // Send command and wait for telemetry response
            moveToAngle(pitchDeg: test.pitch, yawDeg: test.yaw)

            // Wait 3.5s for gimbal to settle and collect telemetry (can take up to 3s to reach final position)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self else { return }

                // Collect current telemetry
                let actualPitch = self.pitch
                let actualYaw = self.yaw
                let actualRoll = self.roll

                // Check results with ±2° tolerance
                let tolerance = 2.0
                let pitchMatch = test.expectedPitch.map { abs(actualPitch - $0) < tolerance } ?? true
                let yawMatch = test.expectedYaw.map { abs(actualYaw - $0) < tolerance } ?? true
                let passed = pitchMatch && yawMatch

                let result = (
                    name: test.name,
                    expected: test.pitch,
                    actual: actualPitch,
                    passed: passed
                )
                self.calibrationResults.append(result)

                let status = passed ? "✓ PASS" : "✗ FAIL"
                self.appendLog(passed ? .info : .err,
                    "\(status) | P: exp=\(String(format: "%+.0f", test.expectedPitch ?? 0))° actual=\(String(format: "%+.1f", actualPitch))° (Δ\(String(format: "%.1f", abs(actualPitch - (test.expectedPitch ?? 0))))°) | Y: exp=\(String(format: "%+.0f", test.expectedYaw ?? 0))° actual=\(String(format: "%+.1f", actualYaw))° (Δ\(String(format: "%.1f", abs(actualYaw - (test.expectedYaw ?? 0))))°) | R: \(String(format: "%+.1f", actualRoll))°",
                    action: "CalibResult")

                index += 1
                runNextTest()
            }
        }

        runNextTest()
    }

    func stopCalibration() {
        calibrationActive = false
        appendLog(.info, "⏹ Calibration routine stopped by user", action: "CalibStop")
    }

    // MARK: Manual Calibration

    func startManualCalibration() {
        guard isReady else {
            appendLog(.err, "❌ Cannot start manual calibration: gimbal not ready", action: "ManualCalibError")
            return
        }
        manualCalibrationActive = true
        manualCalibrationStep = 0
        manualCalibrationData.removeAll()
        appendLog(.info, "📏 === MANUAL CALIBRATION START ===", action: "ManualCalibStart")
        appendLog(.info, "📍 Posição 1/8: \(manualCalibrationLabels[0])", action: "ManualCalibPos")
        appendLog(.info, "👉 Posicione o gimbal usando o joystick físico e clique READY quando pronto", action: nil)
    }

    func captureManualCalibrationPoint() {
        guard manualCalibrationActive, manualCalibrationStep < manualCalibrationLabels.count else { return }

        let label = manualCalibrationLabels[manualCalibrationStep]
        let data = (label: label, pitch: pitch, yaw: yaw, roll: roll)
        manualCalibrationData.append(data)

        appendLog(.info, "✓ Capturado: \(label) → P=\(String(format: "%.1f", pitch))° Y=\(String(format: "%.1f", yaw))° R=\(String(format: "%.1f", roll))°", action: "ManualCapture")

        manualCalibrationStep += 1

        if manualCalibrationStep < manualCalibrationLabels.count {
            appendLog(.info, "📍 Posição \(manualCalibrationStep + 1)/\(manualCalibrationLabels.count): \(manualCalibrationLabels[manualCalibrationStep])", action: "ManualCalibPos")
            appendLog(.info, "👉 Posicione o gimbal e clique NEXT", action: nil)
        } else {
            finishManualCalibration()
        }
    }

    private func finishManualCalibration() {
        manualCalibrationActive = false
        appendLog(.info, "📏 === MANUAL CALIBRATION COMPLETE ===", action: "ManualCalibEnd")
        appendLog(.info, "📋 Resumo dos pontos coletados:", action: nil)

        for (i, point) in manualCalibrationData.enumerated() {
            appendLog(.info, "  [\(i + 1)] \(point.label)", action: nil)
            appendLog(.info, "      P=\(String(format: "%+.1f", point.pitch))° Y=\(String(format: "%+.1f", point.yaw))° R=\(String(format: "%+.1f", point.roll))°", action: nil)
        }
    }

    // MARK: Pitch Mapping Test

    func startPitchMappingTest() {
        guard isReady else {
            appendLog(.err, "❌ Cannot start pitch mapping test: gimbal not ready", action: nil)
            return
        }
        pitchMappingTestActive = true
        pitchMappingTestResults.removeAll()
        appendLog(.info, "🧪 === PITCH MAPPING TEST START ===", action: "PitchMapStart")
        appendLog(.info, "📡 Testando 5 valores de pitch: 0°, +45°, -90°, +90°, -45°", action: nil)

        let testValues: [Double] = [0, 45, -90, 90, -45]
        var index = 0

        func runNextTest() {
            guard index < testValues.count, pitchMappingTestActive else {
                if pitchMappingTestActive {
                    finishPitchMappingTest()
                }
                return
            }

            let pitchValue = testValues[index]
            appendLog(.info, "📍 Teste [\(index + 1)/\(testValues.count)]: Enviando pitch=\(String(format: "%+.0f", pitchValue))°", action: nil)

            moveToAngle(pitchDeg: pitchValue, yawDeg: 0)

            // Aguardar 3.5s para o gimbal se estabilizar completamente (pode levar até 3s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self else { return }

                let receivedPitch = self.pitch
                self.pitchMappingTestResults.append((sent: pitchValue, received: receivedPitch))
                appendLog(.info, "✓ Resposta: pitch=\(String(format: "%+.1f", receivedPitch))° (enviado \(String(format: "%+.0f", pitchValue))°, delta \(String(format: "%+.1f", receivedPitch - pitchValue))°)", action: nil)

                index += 1
                runNextTest()
            }
        }

        runNextTest()
    }

    private func finishPitchMappingTest() {
        pitchMappingTestActive = false
        appendLog(.info, "🧪 === PITCH MAPPING TEST COMPLETE ===", action: "PitchMapEnd")
        appendLog(.info, "📊 Análise dos resultados:", action: nil)

        for (sent, received) in pitchMappingTestResults {
            let delta = received - sent
            let relationship = "Enviado \(String(format: "%+.0f", sent))° → Recebido \(String(format: "%+.1f", received))° (Δ\(String(format: "%+.1f", delta))°)"
            appendLog(.info, "  \(relationship)", action: nil)
        }

        // Detect pattern
        if pitchMappingTestResults.count >= 2 {
            let deltas = pitchMappingTestResults.map { $0.received - $0.sent }
            let avgDelta = deltas.reduce(0, +) / Double(deltas.count)
            appendLog(.info, "📈 Delta médio: \(String(format: "%+.1f", avgDelta))° (offset consistente detectado)", action: nil)
        }
    }

    func startYawMappingTest() {
        guard isReady else {
            appendLog(.err, "❌ Cannot start yaw mapping test: gimbal not ready", action: nil)
            return
        }
        yawMappingTestActive = true
        yawMappingTestResults.removeAll()
        appendLog(.info, "🧪 === YAW MAPPING TEST START ===", action: "YawMapStart")
        appendLog(.info, "📡 Testando 5 valores de yaw: 0°, +45°, -90°, +90°, -45°", action: nil)

        let testValues: [Double] = [0, 45, -90, 90, -45]
        var index = 0

        func runNextTest() {
            guard index < testValues.count, yawMappingTestActive else {
                if yawMappingTestActive {
                    finishYawMappingTest()
                }
                return
            }

            let yawValue = testValues[index]
            appendLog(.info, "📍 Teste [\(index + 1)/\(testValues.count)]: Enviando yaw=\(String(format: "%+.0f", yawValue))°", action: nil)

            moveToAngle(pitchDeg: 0, yawDeg: yawValue)

            // Aguardar 3.5s para o gimbal se estabilizar completamente (pode levar até 3s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self else { return }

                let receivedYaw = self.yaw
                self.yawMappingTestResults.append((sent: yawValue, received: receivedYaw))
                appendLog(.info, "✓ Resposta: yaw=\(String(format: "%+.1f", receivedYaw))° (enviado \(String(format: "%+.0f", yawValue))°, delta \(String(format: "%+.1f", receivedYaw - yawValue))°)", action: nil)

                index += 1
                runNextTest()
            }
        }

        runNextTest()
    }

    private func finishYawMappingTest() {
        yawMappingTestActive = false
        appendLog(.info, "🧪 === YAW MAPPING TEST COMPLETE ===", action: "YawMapEnd")
        appendLog(.info, "📊 Análise dos resultados:", action: nil)

        for (sent, received) in yawMappingTestResults {
            let delta = received - sent
            let relationship = "Enviado \(String(format: "%+.0f", sent))° → Recebido \(String(format: "%+.1f", received))° (Δ\(String(format: "%+.1f", delta))°)"
            appendLog(.info, "  \(relationship)", action: nil)
        }

        // Detect pattern
        if yawMappingTestResults.count >= 2 {
            let deltas = yawMappingTestResults.map { $0.received - $0.sent }
            let avgDelta = deltas.reduce(0, +) / Double(deltas.count)
            appendLog(.info, "📈 Delta médio: \(String(format: "%+.1f", avgDelta))° (offset consistente detectado)", action: nil)
        }
    }

    func startPitchSpeedTest() {
        guard isReady else {
            appendLog(.err, "❌ Cannot start pitch speed test: gimbal not ready", action: nil)
            return
        }
        pitchSpeedTestActive = true
        pitchSpeedTestResults.removeAll()
        appendLog(.info, "🧪 === PITCH SPEED CONTROL TEST START ===", action: "PitchSpeedStart")
        appendLog(.info, "📡 Testando controle de velocidade em pitch (não ângulo absoluto)", action: nil)

        let testSequence: [(direction: String, speed: Double, duration: Double)] = [
            ("Up", 45, 2.0),      // 45°/s por 2s = ~90° esperado
            ("Down", -45, 2.0),   // -45°/s por 2s = ~90° esperado
        ]
        var index = 0

        func runNextTest() {
            guard index < testSequence.count, pitchSpeedTestActive else {
                if pitchSpeedTestActive {
                    finishPitchSpeedTest()
                }
                return
            }

            let test = testSequence[index]
            let initialPitch = self.pitch
            appendLog(.info, "📍 Teste [\(index + 1)/\(testSequence.count)]: Pitch atual = \(String(format: "%+.1f", initialPitch))°", action: nil)
            appendLog(.info, "   Enviando velocidade de \(String(format: "%+.0f", test.speed))°/s por \(String(format: "%.1f", test.duration))s", action: nil)

            setSpeed(pitchDeg: test.speed, yawDeg: 0)

            DispatchQueue.main.asyncAfter(deadline: .now() + test.duration) { [weak self] in
                guard let self else { return }

                setSpeed(pitchDeg: 0, yawDeg: 0)

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }

                    let finalPitch = self.pitch
                    let movement = finalPitch - initialPitch
                    self.pitchSpeedTestResults.append((direction: test.direction, initialPitch: initialPitch, finalPitch: finalPitch, movement: movement))
                    appendLog(.info, "✓ Resultado: Pitch \(String(format: "%+.1f", initialPitch))° → \(String(format: "%+.1f", finalPitch))° (movimento: \(String(format: "%+.1f", movement))°)", action: nil)

                    index += 1
                    runNextTest()
                }
            }
        }

        runNextTest()
    }

    private func finishPitchSpeedTest() {
        pitchSpeedTestActive = false
        appendLog(.info, "🧪 === PITCH SPEED CONTROL TEST COMPLETE ===", action: "PitchSpeedEnd")
        appendLog(.info, "📊 Análise dos resultados:", action: nil)

        for result in pitchSpeedTestResults {
            let movementStr = abs(result.movement) > 5 ? "✓ MOVIMENTO DETECTADO" : "✗ SEM MOVIMENTO"
            appendLog(.info, "  \(result.direction): \(String(format: "%+.1f", result.initialPitch))° → \(String(format: "%+.1f", result.finalPitch))° (Δ\(String(format: "%+.1f", result.movement))°) \(movementStr)", action: nil)
        }

        let hasSignificantMovement = pitchSpeedTestResults.allSatisfy { abs($0.movement) > 10 }
        if hasSignificantMovement {
            appendLog(.info, "✅ CONCLUSÃO: Pitch responde a setSpeed (velocidade) — OM3 suporta controle por velocidade!", action: nil)
        } else {
            appendLog(.info, "❌ CONCLUSÃO: Pitch NÃO responde a setSpeed — problema diferente", action: nil)
        }
    }

    // MARK: Tracking

    func toggleTracking() {
        tracking.toggle()
        isTracking = tracking.isActive
        let msg = isTracking ? "👁 Tracking ENABLED" : "👁 Tracking disabled"
        appendLog(.info, msg, action: isTracking ? "TrackingOn" : "TrackingOff")
        if !isTracking { trackingBounds = nil; stopMotion() }
    }

    func setTrackingTarget(faceOnly: Bool) {
        tracking.target = faceOnly ? .face : .body
        tracking.reset()
        appendLog(.info, "📍 Tracking target: \(faceOnly ? "Face" : "Body")", action: "SetTarget")
    }

    private func setupTrackingPipeline() {
        cameraManager.frameHandler = { [weak self] buffer in
            guard let self else { return }
            guard let out = self.tracking.process(sampleBuffer: buffer) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackingBounds = out.bounds
                if self.isReady { self.setSpeed(pitchDeg: out.pitch, yawDeg: out.yaw) }
            }
        }
    }

    // MARK: Keyboard joystick

    func keyDown(_ key: String) {
        guard heldKeys.insert(key).inserted else { return }
        if keyboardTimerCancellable == nil {
            keyboardTimerCancellable = Timer.publish(every: 1.0 / 30, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.applyKeyboardJoystick() }
        }
    }

    func keyUp(_ key: String) {
        heldKeys.remove(key)
        if heldKeys.isEmpty { keyboardTimerCancellable = nil }
    }

    private func applyKeyboardJoystick() {
        guard isReady else { return }
        let up    = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down  = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let left  = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        var rP: Double = 0, rY: Double = 0
        if heldKeys.contains("w") || heldKeys.contains(up)    { rP += 1 }
        if heldKeys.contains("s") || heldKeys.contains(down)  { rP -= 1 }
        if heldKeys.contains("a") || heldKeys.contains(left)  { rY -= 1 }
        if heldKeys.contains("d") || heldKeys.contains(right) { rY += 1 }
        switch settings.axisMode {
        case .horizontal: rP = 0
        case .vertical:   rY = 0
        case .free:       break
        }
        applyDriveRate(pitchRate: rP, yawRate: rY, dt: 1.0 / 30)
    }

    // MARK: On-screen joystick drive
    // speedCtrl (0x0C) is not supported on the OM3 firmware.
    // Instead we send incremental setAngle commands at ~10 Hz.

    func setJoystickDriveRate(pitchRate: Double, yawRate: Double) {
        joystickRatePitch = pitchRate
        joystickRateYaw   = yawRate
        if pitchRate == 0, yawRate == 0 {
            joystickDriveCancellable = nil
        } else if joystickDriveCancellable == nil {
            joystickDriveCancellable = Timer.publish(every: 1.0 / 10, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.applyJoystickDrive() }
        }
    }

    private func applyJoystickDrive() {
        guard isReady else { return }
        applyDriveRate(pitchRate: joystickRatePitch, yawRate: joystickRateYaw, dt: 1.0 / 10)
    }

    // Shared incremental angle-drive logic used by both keyboard and on-screen joystick.
    // Sends setAngle with a small step per tick; duration slightly longer than dt for smooth ramp.
    private func applyDriveRate(pitchRate: Double, yawRate: Double, dt: Double) {
        let speed    = min(settings.joystickSpeedDPS, 30)
        let panSign  = settings.invertPan  ? -1.0 : 1.0
        let tiltSign = settings.invertTilt ? -1.0 : 1.0
        let dp = pitchRate * tiltSign * speed * dt
        let dy = yawRate   * panSign  * speed * dt
        let targetP = (pitch + dp).clamped(-90, 45)
        let targetY = (yaw   + dy).clamped(-160, 160)
        setAngle(pitchDeg: targetP, yawDeg: targetY, durationSec: dt * 1.5)
    }

    // MARK: Frame dispatch

    private func handleFrame(_ frame: DUMLFrame) {
        guard frame.cmdSet == DUML.CmdSet.gimbal || frame.cmdSet == DUML.CmdSet.wifi else {
            // Skip high-frequency background frames (heartbeat, centerBoard, etc.)
            // to keep the log readable — only log unknown gimbal/wifi frames below.
            logUnknownIfNeeded(frame)
            return
        }

        switch (frame.cmdSet, frame.cmdId) {

        // Position telemetry — getPos pull response sent by OM3 every ~1s.
        // Confirmed layout from live capture: [flags p_lo p_hi r_lo r_hi y_lo y_hi ? ?]
        case (DUML.CmdSet.gimbal, DUML.GimbalCmd.getPos) where frame.payload.count >= 7:
            let p = frame.payload
            pitch = Double(Int16(bitPattern: UInt16(p[1]) | UInt16(p[2]) << 8)) / 10
            roll  = Double(Int16(bitPattern: UInt16(p[3]) | UInt16(p[4]) << 8)) / 10
            yaw   = Double(Int16(bitPattern: UInt16(p[5]) | UInt16(p[6]) << 8)) / 10
            appendLog(.rx, "getPos raw: [\(hex(p))] → P=\(String(format: "%.1f", pitch))° R=\(String(format: "%.1f", roll))° Y=\(String(format: "%.1f", yaw))°")
            positionHistory.append((pitch, yaw))
            if positionHistory.count > 14 { positionHistory.removeFirst() }
            return

        // High-frequency position push — OM3 sends continuously.
        // Layout: [pitch_lo pitch_hi roll_lo roll_hi yaw_lo yaw_hi yawBody_lo yawBody_hi ...]
        // Bytes are 1/10° int16 LE. yawBody = heading relative to gimbal body.
        case (DUML.CmdSet.gimbal, DUML.GimbalCmd.positionPush) where frame.payload.count >= 8:
            let p = frame.payload
            pitch   = Double(Int16(bitPattern: UInt16(p[0]) | UInt16(p[1]) << 8)) / 10
            roll    = Double(Int16(bitPattern: UInt16(p[2]) | UInt16(p[3]) << 8)) / 10
            yaw     = Double(Int16(bitPattern: UInt16(p[4]) | UInt16(p[5]) << 8)) / 10
            yawBody = Double(Int16(bitPattern: UInt16(p[6]) | UInt16(p[7]) << 8)) / 10
            positionHistory.append((pitch, yaw))
            if positionHistory.count > 14 { positionHistory.removeFirst() }
            return

        // Physical joystick deflection — OM3 sends at ~25Hz while joystick is held.
        // Host must translate deflection into setSpeed commands; the joystick does NOT
        // move the motor directly. Layout: [yaw_lo yaw_hi pitch_lo pitch_hi 0x01 flags]
        // Raw range: –1000..+1000.
        // Note: OM3 sends 0,0 repeatedly when joystick is released; we ignore to avoid
        // spamming stopMotion. Gimbal will maintain position until next command.
        case (DUML.CmdSet.gimbal, DUML.GimbalCmd.joystickReport) where frame.payload.count >= 4:
            let p = frame.payload
            let rawX = Int16(bitPattern: UInt16(p[0]) | UInt16(p[1]) << 8)
            let rawY = Int16(bitPattern: UInt16(p[2]) | UInt16(p[3]) << 8)
            if (rawX != 0 || rawY != 0) && isReady {
                let speed = min(settings.joystickSpeedDPS, 30)
                setSpeed(pitchDeg: curveJoystick(rawY) * speed,
                         yawDeg:   curveJoystick(rawX) * speed)
            }
            return

        // Battery level — pushed every ~2s. payload[0] = 0..100 percent; payload.last == 0x01 = charging.
        case (DUML.CmdSet.gimbal, DUML.GimbalCmd.batteryLevel) where !frame.payload.isEmpty:
            let pct = Int(frame.payload[0])
            battery = pct
            isCharging = frame.payload.count >= 2 && frame.payload.last == 0x01
            appendLog(.rx, "Battery: \(pct)% charging=\(isCharging) raw=[\(frame.payload.map { String(format: "%02X", $0) }.joined(separator: " "))]")
            return

        // Pairing responses
        case (DUML.CmdSet.wifi, DUML.WifiCmd.setPairingPin) where frame.isResponse:
            let status = frame.payload.count >= 2 ? frame.payload[1] : (frame.payload.first ?? 0)
            if status == 0x01 {
                appendLog(.rx, "Already paired.")
                pairingCancellable = nil
                pairingStep = .done
                connectionState = .ready
                startHeartbeat()
                sendFeatureControl()
            } else if status == 0x02 {
                pairingStep = .waitingGimbal
                appendLog(.rx, "Press the TRIGGER button on the gimbal to confirm pairing.")
            }

        case (DUML.CmdSet.wifi, DUML.WifiCmd.pairingApproved) where frame.payload.first == 0x01:
            appendLog(.rx, "Pairing approved.")
            pairingCancellable = nil
            pairingStep = .done
            connectionState = .ready
            startHeartbeat()
            sendFeatureControl()

        case (DUML.CmdSet.gimbal, DUML.GimbalCmd.featureControl) where frame.isResponse:
            let ok = frame.payload.first == 0x00
            appendLog(ok ? .rx : .err,
                      "FeatureControl response: \(ok ? "OK" : "FAIL") raw=[\(frame.payload.map { String(format: "%02X", $0) }.joined(separator: " "))]")

        default:
            logUnknownIfNeeded(frame)
        }
    }

    private func logUnknownIfNeeded(_ frame: DUMLFrame) {
        // Suppress high-frequency known-background frames to keep the log useful.
        let silent: Set<UInt16> = [
            UInt16(DUML.CmdSet.gimbal) << 8 | 0x0C,  // setSpeed ACK response
            UInt16(DUML.CmdSet.gimbal) << 8 | 0x57,  // joystickReport (handled above)
            UInt16(DUML.CmdSet.gimbal) << 8 | 0x19,  // GetGimbalState poll
            UInt16(DUML.CmdSet.gimbal) << 8 | 0x27,  // GetFollowParam poll
            0x00F1,                                    // heartbeat
            0xEE01,                                    // vendor heartbeat
            UInt16(0x05) << 8 | 0x06,                 // centerBoard telemetry
        ]
        let key = UInt16(frame.cmdSet) << 8 | UInt16(frame.cmdId)
        if !silent.contains(key) && !(frame.isResponse && frame.payload.count <= 1) {
            let payloadHex = frame.payload.isEmpty ? "" : " [\(hex(frame.payload))]"
            appendLog(.rx, String(format: "← cmdSet=%02X cmdId=%02X flags=%02X len=%d%@",
                                  frame.cmdSet, frame.cmdId, frame.flags, frame.payload.count, payloadHex))
        }
    }

    // MARK: Send helpers

    private func sendGimbal(cmd: UInt8, payload: [UInt8], label: String, action: String? = nil) {
        let frame = DUMLFrame(target: DUML.target(from: .app, to: .gimbal),
                              seq: seq.next(), flags: DUML.Flag.request,
                              cmdSet: DUML.CmdSet.gimbal, cmdId: cmd, payload: payload)
        send(frame, label: label, action: action, payload: payload)
    }

    private func send(_ frame: DUMLFrame, label: String, action: String? = nil, payload: [UInt8]? = nil) {
        let encoded = frame.encode()
        let payloadInfo = payload.map { " payload=\(hex($0))" } ?? ""
        appendLog(.tx, "→ \(label)\(payloadInfo)", action: action, payload: payload)
        ble.writeDUML(frame, encoded: encoded)
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeatCancellable = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.isReady else { return }
                self.sendGimbal(cmd: DUML.GimbalCmd.heartbeat,
                                payload: [0x01, 0x04, 0x05],
                                label: "Heartbeat")
            }
    }

    // MARK: Feature control

    private func sendFeatureControl() {
        sendGimbal(cmd: DUML.GimbalCmd.featureControl,
                   payload: [0x01, 0xB0, 0x04, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00],
                   label: "FeatureControl")
    }

    // MARK: Waypoint timelapse (gimbal A→B pan)

    func captureWaypoint() {
        guard gimbalWaypoints.count < 5 else { return }
        gimbalWaypoints.append((pitch: pitch, yaw: yaw))
        appendLog(.info, "📍 Waypoint \(gimbalWaypoints.count) captured: P=\(String(format: "%+.1f", pitch))° Y=\(String(format: "%+.1f", yaw))°",
                  action: "WaypointCapture")
    }

    func clearWaypoints() {
        gimbalWaypoints.removeAll()
        appendLog(.info, "🗑 Waypoints cleared", action: "WaypointClear")
    }

    func startGimbalTimelapse() {
        guard gimbalWaypoints.count >= 2 else {
            appendLog(.err, "❌ Need at least 2 waypoints to start pan.", action: "TimelapsError")
            return
        }
        guard isReady else { return }

        let waypoints = gimbalWaypoints
        let durationMs = UInt32(gimbalTimelapseDuration * 1000)

        // Send 3 heartbeats then feature control before the timelapse command.
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { [weak self] in
                guard let self, self.isReady else { return }
                self.sendGimbal(cmd: DUML.GimbalCmd.heartbeat, payload: [0x01, 0x04, 0x05],
                                label: "Heartbeat (timelapse prep)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.isReady else { return }
            self.sendFeatureControl()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.isReady else { return }
            self.sendTimelapseStart(waypoints: waypoints, durationMs: durationMs)
        }

        gimbalTimelapseRunning = true
        appendLog(.info, "🎬 Gimbal waypoint pan started (\(waypoints.count) points, \(Int(gimbalTimelapseDuration))s)",
                  action: "TimelapsStart")

        // Keep heartbeat + feature control alive during execution.
        gimbalTimelapseCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.gimbalTimelapseRunning, self.isReady else { return }
                self.sendGimbal(cmd: DUML.GimbalCmd.heartbeat, payload: [0x01, 0x04, 0x05],
                                label: "Heartbeat (timelapse running)")
                self.sendFeatureControl()
            }

        // Auto-stop after duration + 2s buffer.
        DispatchQueue.main.asyncAfter(deadline: .now() + gimbalTimelapseDuration + 2) { [weak self] in
            guard let self, self.gimbalTimelapseRunning else { return }
            self.stopGimbalTimelapse()
        }
    }

    func stopGimbalTimelapse() {
        guard gimbalTimelapseRunning else { return }
        gimbalTimelapseRunning = false
        gimbalTimelapseCancellable = nil
        appendLog(.info, "⏹ Gimbal waypoint pan stopped", action: "TimelapsStop")
    }

    private func sendTimelapseStart(waypoints: [(pitch: Double, yaw: Double)], durationMs: UInt32) {
        let count = waypoints.count
        // Payload: [0x12, count, dur uint32LE (4 bytes), 00 00, (yaw roll pitch 4*00) per keyframe]
        var payload = [UInt8]()
        payload.append(0x12)                             // opcode: start
        payload.append(UInt8(count))
        payload.append(UInt8(durationMs & 0xFF))
        payload.append(UInt8((durationMs >> 8) & 0xFF))
        payload.append(UInt8((durationMs >> 16) & 0xFF))
        payload.append(UInt8((durationMs >> 24) & 0xFF))
        payload.append(0x00); payload.append(0x00)       // reserved

        for (i, wp) in waypoints.enumerated() {
            // Axis mapping from OM Research web-bluetooth-enhancements fork:
            // payload yaw  ← live yaw  × 10
            // payload roll ← 0
            // payload pitch ← 500 on first keyframe, 0 on others
            let yawVal   = Int16((wp.yaw * 10).rounded())
            let rollVal  = Int16(0)
            let pitchVal = Int16(i == 0 ? 500 : 0)
            func appendInt16(_ v: Int16) {
                let u = UInt16(bitPattern: v)
                payload.append(UInt8(u & 0xFF))
                payload.append(UInt8((u >> 8) & 0xFF))
            }
            appendInt16(yawVal)
            appendInt16(rollVal)
            appendInt16(pitchVal)
            payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // padding
        }

        sendGimbal(cmd: DUML.GimbalCmd.timelapseStart, payload: payload,
                   label: "TimelapsStart(\(count) waypoints)", action: "TimelapsStart")
    }

    // MARK: Joystick curve
    // Applies deadzone + quadratic curve to a raw OM3 joystick axis value (-1000..+1000).
    // Returns a normalized speed fraction in -1..+1.
    // Quadratic: gives fine control at low deflection without sacrificing max speed.
    private func curveJoystick(_ raw: Int16) -> Double {
        let v = Double(raw)
        let absV = abs(v)
        let deadzone: Double = 80          // ignore below 8% deflection
        let maxRaw:   Double = 1000
        guard absV > deadzone else { return 0 }
        let normalized = (absV - deadzone) / (maxRaw - deadzone)   // 0..1
        let curved = normalized * normalized                        // quadratic
        return curved * (v > 0 ? 1 : -1)
    }

    // MARK: Log

    /// Public entry point for subsystems (e.g. GimbalCheckup) to write to the shared log.
    func checkupLog(_ text: String) {
        appendLog(.info, text, action: "Checkup")
    }

    private func appendLog(_ d: LogEntry.Direction, _ text: String,
                          action: String? = nil, payload: [UInt8]? = nil) {
        let entry = LogEntry(timestamp: Date(), direction: d, text: text,
                            action: action, payload: payload)
        // Filter: suppress high-frequency background traffic when hideFrequentLogs is on.
        // "Checkup" action entries are always shown regardless.
        if hideFrequentLogs && action != "Checkup" {
            // Speed commands: ~30 Hz human-readable summary + raw TX frame
            if action == "SetSpeed" { return }
            if d == .tx && text.hasPrefix("→ Speed(") { return }
            // Heartbeat TX (~0.5 Hz) and its RX ack
            if d == .tx && text.hasPrefix("→ Heartbeat") { return }
            // getPos telemetry push (~1 Hz)
            if d == .rx && text.hasPrefix("getPos raw:") { return }
            // Other periodic RX frames by cmdId (positionPush, joystick, battery, etc.)
            if d == .rx, let range = text.range(of: "cmdId=") {
                let hexStr = String(text[range.upperBound...].prefix(2))
                let silentCmdIds = Set<UInt8>([0x02, 0x04, 0x19, 0x27, 0x50, 0x57, 0x1C])
                if let cmdId = UInt8(hexStr, radix: 16), silentCmdIds.contains(cmdId) { return }
            }
        }
        // Filter: show only action logs if requested
        if showActionsOnly && entry.action == nil && d == .rx { return }

        log.append(entry)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    func clearLog() { log.removeAll() }

    // MARK: Computed

    var isReady: Bool {
        switch connectionState {
        case .ready, .connected: return true
        default: return false
        }
    }

    // MARK: Utilities

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
