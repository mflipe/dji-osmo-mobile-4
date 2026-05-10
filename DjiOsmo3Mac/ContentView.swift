import SwiftUI
import CoreBluetooth
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var ctl: GimbalController
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var sidebarSelection: SidebarItem? = .devices

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } detail: {
            MainDetail()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 600)
        .onKeyEvents(down: { ctl.keyDown($0) }, up: { ctl.keyUp($0) })
        .alert("Gimbal detected", isPresented: Binding(
            get: { ctl.newGimbalAlert != nil },
            set: { if !$0 { ctl.newGimbalAlert = nil } }
        )) {
            Button("Connect") {
                if let dev = ctl.devices.first(where: { $0.name == ctl.newGimbalAlert }) {
                    ctl.connect(dev)
                }
                ctl.newGimbalAlert = nil
            }
            Button("Dismiss", role: .cancel) { ctl.newGimbalAlert = nil }
        } message: {
            Text("\(ctl.newGimbalAlert ?? "") is nearby. Connect now?")
        }
    }
}

// MARK: - Sidebar

enum SidebarItem: String, CaseIterable, Identifiable {
    case devices            = "Devices"
    case camera             = "Camera"
    case settings           = "Settings"
    case calibration        = "Calibration"
    case manualCalibration  = "Manual Cal"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .devices:            return "wave.3.right"
        case .camera:             return "camera"
        case .settings:           return "slider.horizontal.3"
        case .calibration:        return "dial.max"
        case .manualCalibration:  return "square.and.pencil"
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var ctl: GimbalController
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Connection") {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Group {
                switch selection {
                case .devices:            DevicePanel()
                case .camera:             CameraPanel()
                case .settings:           SettingsPanel()
                case .calibration:        CalibrationPanel()
                case .manualCalibration:  ManualCalibrationPanel()
                case .none:               EmptyView()
                }
            }
            .padding(10)
        }
    }
}

// MARK: - Sidebar panels

private struct DevicePanel: View {
    @EnvironmentObject var ctl: GimbalController
    @State private var showGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Scan / disconnect controls
            HStack {
                Button {
                    if case .scanning = ctl.connectionState { ctl.stopScan() }
                    else { ctl.startScan() }
                } label: {
                    if case .scanning = ctl.connectionState {
                        Label("Stop", systemImage: "stop.circle")
                    } else {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                }
                .disabled(ctl.bleState != .poweredOn)
                Spacer()
                if !ctl.isReady {
                    Button(role: .destructive) { ctl.disconnect() } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .disabled(!isConnected)
                }
            }

            // Device list
            List(ctl.devices) { dev in
                Button { ctl.connect(dev) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(dev.name).font(.system(.body, design: .rounded))
                            Text("RSSI \(dev.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if ctl.selected?.id == dev.id { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.bordered)
            .frame(minHeight: 100, maxHeight: 180)

            // Pairing progress (shown while pairing)
            PairingProgressView()

            Divider()
            Toggle("Auto-pair", isOn: $ctl.autoPair)
            HStack {
                Text("PIN").frame(width: 40)
                TextField("", text: $ctl.pin).textFieldStyle(.roundedBorder)
            }
            Button("Re-pair") { ctl.startPairing() }
                .disabled(!isConnected)

            Divider()

            Button {
                showGuide = true
            } label: {
                Label("How to pair the OM3", systemImage: "questionmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .sheet(isPresented: $showGuide) {
                PairingGuideView()
                    .padding()
                    .frame(minWidth: 380, minHeight: 420)
            }
        }
    }

    private var isConnected: Bool {
        switch ctl.connectionState {
        case .connected, .pairing, .ready: return true
        default: return false
        }
    }
}

// MARK: Pairing progress indicator

private struct PairingProgressView: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        switch ctl.pairingStep {
        case .idle, .done:
            EmptyView()
        case .trigger(let n):
            statusRow(icon: "antenna.radiowaves.left.and.right",
                      color: .blue,
                      text: "Sending wake-up signal (\(n)/3)…")
        case .pin:
            statusRow(icon: "key.horizontal",
                      color: .blue,
                      text: "Sending pairing PIN…")
        case .waitingGimbal:
            statusRow(icon: "hand.point.up",
                      color: .orange,
                      text: "Press the TRIGGER on the gimbal to confirm.")
        }
    }

    private func statusRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: Step-by-step pairing guide

private struct PairingGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(n: 1, icon: "power",
                 title: "Power on the gimbal",
                 detail: "Hold the power button for 2 seconds until the status LED lights up.")

            step(n: 2, icon: "wave.3.right",
                 title: "Make it discoverable",
                 detail: "The gimbal broadcasts BLE for ~60 s after power-on. If it doesn't appear after scanning, hold the M button for 3 seconds until the LED flashes blue — this resets the Bluetooth advertising.")

            step(n: 3, icon: "magnifyingglass",
                 title: "Scan & Connect",
                 detail: "Tap Scan above. Your OM3 will appear as \"OM-…\" or \"Osmo Mobile 3\". Tap it to connect.")

            step(n: 4, icon: "hand.point.right",
                 title: "Confirm on the gimbal (if asked)",
                 detail: "If the status shows \"Press TRIGGER\", press the trigger button on the physical gimbal once within 30 seconds.")

            Divider()

            Text("Troubleshooting")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            troubleshootRow(icon: "arrow.counterclockwise",
                            text: "Not appearing? Restart the gimbal and re-scan.")
            troubleshootRow(icon: "iphone.slash",
                            text: "Was paired to another device? Hold M + Trigger for 5 s to factory-reset BLE on the gimbal.")
            troubleshootRow(icon: "battery.25",
                            text: "Battery below 10%: the gimbal may not advertise BLE. Charge first.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func step(n: Int, icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(.blue.opacity(0.15)).frame(width: 20, height: 20)
                Text("\(n)").font(.caption2.weight(.bold)).foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon).font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func troubleshootRow(icon: String, text: String) -> some View {
        Label(text, systemImage: icon).fixedSize(horizontal: false, vertical: true)
    }
}

private struct CameraPanel: View {
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera").font(.headline)

            Picker("Device", selection: Binding(
                get: { cameraManager.selectedCamera },
                set: { if let cam = $0 { cameraManager.switchCamera(cam) } }
            )) {
                ForEach(cameraManager.availableCameras, id: \.uniqueID) { cam in
                    Label {
                        Text(cam.localizedName)
                    } icon: {
                        Image(systemName: cameraManager.isContinuityCamera(cam)
                              ? "iphone.gen3" : "camera")
                    }
                    .tag(Optional(cam))
                }
            }

            if cameraManager.continuityCamera != nil {
                ContinuityCameraEffectsView()
            }

            if !cameraManager.availableMicrophones.isEmpty {
                Picker("Mic", selection: Binding(
                    get: { cameraManager.selectedMicrophone },
                    set: { if let mic = $0 { cameraManager.switchMicrophone(mic) } }
                )) {
                    ForEach(cameraManager.availableMicrophones, id: \.uniqueID) { mic in
                        Label(mic.localizedName, systemImage: "mic")
                            .tag(Optional(mic))
                    }
                }
            }

            Divider()

            Picker("Mode", selection: $cameraManager.captureMode) {
                ForEach(CaptureMode.allCases) { m in
                    Label(m.rawValue, systemImage: m.systemImage).tag(m)
                }
            }

            if cameraManager.captureMode == .timelapse {
                HStack {
                    Text("Interval").font(.caption)
                    Slider(value: $cameraManager.timelapseInterval, in: 0.5...30, step: 0.5)
                    Text("\(String(format: "%.1f", cameraManager.timelapseInterval))s")
                        .font(.caption).monospacedDigit()
                }
            }

            Toggle("Grid overlay", isOn: $settings.showGrid)
        }
    }
}

private struct ContinuityCameraEffectsView: View {
    @EnvironmentObject var cameraManager: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("iPhone Effects", systemImage: "iphone.gen3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Center Stage — settable by apps
            Toggle("Center Stage", isOn: Binding(
                get: { cameraManager.centerStageEnabled },
                set: { cameraManager.setCenterStage($0) }
            ))
            .font(.caption)

            // Portrait mode — read-only, controlled via Control Center
            HStack {
                Image(systemName: "person.crop.rectangle")
                    .foregroundStyle(cameraManager.portraitEffectActive ? .primary : .secondary)
                Text("Portrait mode")
                Spacer()
                Text(cameraManager.portraitEffectActive ? "On" : "Off")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CalibrationPanel: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calibration Test").font(.headline)

            if !ctl.calibrationActive {
                Button {
                    ctl.startCalibrationRoutine()
                } label: {
                    Label("Start Routine", systemImage: "play.circle.fill")
                }
                .disabled(!ctl.isReady)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8, anchor: .center)
                        Text(ctl.calibrationStep)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            ctl.stopCalibration()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !ctl.calibrationResults.isEmpty {
                Divider()
                Text("Results").font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ctl.calibrationResults, id: \.name) { result in
                            HStack(spacing: 6) {
                                Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(result.passed ? .green : .red)
                                Text(result.name)
                                    .font(.caption)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(String(format: "%.1f°", result.actual))
                                        .font(.system(size: 8, design: .monospaced))
                                    Text(String(format: "exp %.0f°", result.expected))
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .font(.caption)
                }
                .frame(height: 120)

                Button {
                    let report = ctl.calibrationResults.map { r in
                        "\(r.name): \(String(format: "%.1f", r.actual))° (exp: \(String(format: "%.0f", r.expected))°) [\(r.passed ? "OK" : "FAIL")]"
                    }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                } label: {
                    Label("Copy Results", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

private struct ManualCalibrationPanel: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manual Calibration").font(.headline)

            if !ctl.manualCalibrationActive && !ctl.pitchMappingTestActive && !ctl.yawMappingTestActive && !ctl.pitchSpeedTestActive {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            ctl.startManualCalibration()
                        } label: {
                            Label("Manual", systemImage: "square.and.pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!ctl.isReady)

                        Button {
                            ctl.startPitchMappingTest()
                        } label: {
                            Label("Pitch Test", systemImage: "waveform.badge.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!ctl.isReady)
                    }

                    HStack(spacing: 8) {
                        Button {
                            ctl.startYawMappingTest()
                        } label: {
                            Label("Yaw Test", systemImage: "waveform.badge.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!ctl.isReady)

                        Button {
                            ctl.startPitchSpeedTest()
                        } label: {
                            Label("Pitch Speed", systemImage: "speedometer")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!ctl.isReady)
                    }
                }
                .font(.caption.weight(.semibold))
            } else if !ctl.manualCalibrationActive && ctl.pitchMappingTestActive {
                VStack(alignment: .center, spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Testando mapeamento de pitch...")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !ctl.pitchMappingTestResults.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Resultados parciais:")
                                .font(.caption.weight(.semibold))
                            ForEach(Array(ctl.pitchMappingTestResults.enumerated()), id: \.offset) { _, result in
                                HStack(spacing: 8) {
                                    Text("Enviado \(String(format: "%+.0f", result.sent))°")
                                        .font(.caption)
                                    Text("→")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Recebido \(String(format: "%+.1f", result.received))°")
                                        .font(.caption)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            } else if ctl.yawMappingTestActive {
                VStack(alignment: .center, spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Testando mapeamento de yaw...")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !ctl.yawMappingTestResults.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Resultados parciais:")
                                .font(.caption.weight(.semibold))
                            ForEach(Array(ctl.yawMappingTestResults.enumerated()), id: \.offset) { _, result in
                                HStack(spacing: 8) {
                                    Text("Enviado \(String(format: "%+.0f", result.sent))°")
                                        .font(.caption)
                                    Text("→")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Recebido \(String(format: "%+.1f", result.received))°")
                                        .font(.caption)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            } else if ctl.pitchSpeedTestActive {
                VStack(alignment: .center, spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Testando controle de velocidade em pitch...")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !ctl.pitchSpeedTestResults.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Resultados parciais:")
                                .font(.caption.weight(.semibold))
                            ForEach(Array(ctl.pitchSpeedTestResults.enumerated()), id: \.offset) { _, result in
                                HStack(spacing: 8) {
                                    Text("\(result.direction)")
                                        .font(.caption)
                                        .frame(width: 40, alignment: .leading)
                                    Text("Δ\(String(format: "%+.1f", result.movement))°")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(abs(result.movement) > 5 ? .green : .orange)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            } else if ctl.manualCalibrationActive {
                Button {
                    ctl.startManualCalibration()
                } label: {
                    Label("Start Manual", systemImage: "square.and.pencil")
                }
                .disabled(!ctl.isReady)
            } else {
                VStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .center, spacing: 4) {
                        Text("Posição \(ctl.manualCalibrationStep + 1)/\(ctl.manualCalibrationLabels.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(ctl.manualCalibrationLabels[min(ctl.manualCalibrationStep, ctl.manualCalibrationLabels.count - 1)])
                            .font(.headline)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("P")
                                .font(.caption.weight(.semibold))
                                .frame(width: 16)
                            Text(String(format: "%+.1f°", ctl.pitch))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        HStack {
                            Text("Y")
                                .font(.caption.weight(.semibold))
                                .frame(width: 16)
                            Text(String(format: "%+.1f°", ctl.yaw))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        HStack {
                            Text("R")
                                .font(.caption.weight(.semibold))
                                .frame(width: 16)
                            Text(String(format: "%+.1f°", ctl.roll))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .font(.caption)

                    HStack(spacing: 8) {
                        if ctl.manualCalibrationStep == 0 {
                            Button {
                                ctl.captureManualCalibrationPoint()
                            } label: {
                                Label("Ready", systemImage: "checkmark.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            Button {
                                ctl.captureManualCalibrationPoint()
                            } label: {
                                Label("Next", systemImage: "arrow.right.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            if !ctl.manualCalibrationData.isEmpty {
                Divider()
                Text("Captured Points").font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(ctl.manualCalibrationData.enumerated()), id: \.offset) { i, point in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(i + 1)] \(point.label)")
                                    .font(.caption.weight(.semibold))
                                HStack(spacing: 12) {
                                    Text("P=\(String(format: "%+.1f°", point.pitch))")
                                        .font(.system(size: 8, design: .monospaced))
                                    Text("Y=\(String(format: "%+.1f°", point.yaw))")
                                        .font(.system(size: 8, design: .monospaced))
                                    Text("R=\(String(format: "%+.1f°", point.roll))")
                                        .font(.system(size: 8, design: .monospaced))
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                }
                .frame(height: 150)

                Button {
                    let report = ctl.manualCalibrationData.enumerated().map { i, p in
                        "[\(i + 1)] \(p.label): P=\(String(format: "%+.1f", p.pitch))° Y=\(String(format: "%+.1f", p.yaw))° R=\(String(format: "%+.1f", p.roll))°"
                    }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                } label: {
                    Label("Copy Data", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

private struct SettingsPanel: View {
    @EnvironmentObject var ctl: GimbalController
    @EnvironmentObject var settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gimbal").font(.headline)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(Int(settings.joystickSpeedDPS)) °/s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.joystickSpeedDPS, in: 1...30, step: 1)
            }

            Picker("Axis", selection: $settings.axisMode) {
                ForEach(AxisMode.allCases) { a in Text(a.rawValue).tag(a) }
            }

            Toggle("Invert pan",  isOn: $settings.invertPan)
            Toggle("Invert tilt", isOn: $settings.invertTilt)
            Toggle("Sport multiplier", isOn: $settings.sportMode)

            Divider()
            Text("M button").font(.headline)
            Picker("Action", selection: $settings.mButtonAction) {
                ForEach(MButtonAction.allCases) { a in Text(a.rawValue).tag(a) }
            }

            Divider()
            Button("Calibrate gimbal") { ctl.calibrate() }
                .disabled(!ctl.isReady)
        }
    }
}

// MARK: - Main detail (camera preview + controls)

private struct MainDetail: View {
    @EnvironmentObject var ctl: GimbalController
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var settings: SettingsModel
    @State private var showLog = false

    var body: some View {
        ZStack {
            cameraBackground

            VStack(spacing: 0) {
                // Top HUD
                HStack(alignment: .top) {
                    Spacer()
                    TelemetryHUD()
                        .padding(12)
                }

                Spacer()

                // Bottom-left joystick widget
                HStack(alignment: .bottom) {
                    JoystickWidget()
                        .padding(16)
                    Spacer()
                }

                // Angle control sliders
                MovementBar()

                // Bottom bar
                BottomBar()
            }
        }
        .toolbar { toolbarContent }
        .background(.black)
        .sheet(isPresented: $showLog) {
            LogPane()
                .environmentObject(ctl)
                .frame(minWidth: 540, minHeight: 340)
        }
        .onAppear {
            if !cameraManager.isRunning { cameraManager.start() }
        }
    }

    @ViewBuilder
    private var cameraBackground: some View {
        if cameraManager.isRunning {
            CameraPreviewView(session: cameraManager.session,
                              trackingBounds: ctl.trackingBounds)
                .ignoresSafeArea()
            if settings.showGrid {
                GridOverlay().ignoresSafeArea()
            }
        } else {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5, 0.5], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ], colors: [
                .black, .indigo, .black,
                .indigo, .purple, .indigo,
                .black, .indigo, .black
            ])
            .ignoresSafeArea()

            Text("No camera available")
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .status) {
            StatusChip()
        }
        ToolbarItem(placement: .primaryAction) {
            if cameraManager.isRecording {
                RecordingIndicator()
            }
        }
        ToolbarItem(placement: .automatic) {
            Button {
                showLog.toggle()
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .help("Show BLE log")
        }
    }
}

// MARK: - Toolbar chips

private struct StatusChip: View {
    @EnvironmentObject var ctl: GimbalController
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                // Pulsing halo visible only when ready
                if case .ready = ctl.connectionState {
                    Circle()
                        .stroke(Color.green.opacity(pulse ? 0 : 0.5), lineWidth: 1.5)
                        .frame(width: pulse ? 20 : 8, height: pulse ? 20 : 8)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false),
                                   value: pulse)
                }
                Circle().fill(statusColor).frame(width: 8, height: 8)
            }
            .frame(width: 20, height: 20)

            if let dev = ctl.selected {
                Text(dev.name).font(.subheadline.weight(.medium))
            } else {
                Text(ctl.connectionState.label).font(.subheadline)
            }
            if let bat = ctl.battery {
                Label("\(bat)%", systemImage: batteryIcon(bat))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(in: Capsule())
        .onAppear { pulse = true }
        .onChange(of: ctl.connectionState) { _, _ in pulse = false; pulse = true }
    }

    private var statusColor: Color {
        switch ctl.connectionState {
        case .ready:                                    return .green
        case .connected, .pairing, .discoveringServices: return .yellow
        case .scanning, .connecting:                    return .blue
        case .failed:                                   return .red
        case .idle:                                     return .gray
        }
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.25"
        default:    return "battery.0"
        }
    }
}

private struct RecordingIndicator: View {
    @State private var blink = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(blink ? Color.red : .red.opacity(0.3)).frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: blink)
            Text("REC").font(.caption.weight(.bold)).foregroundStyle(.red)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .glassEffect(in: Capsule())
        .onAppear { blink = true }
    }
}

// MARK: - Gimbal Minimap

// Clickable/draggable 2D map of the gimbal's reachable angle space.
// X axis = Yaw (−160°…+160°), Y axis = Pitch (−90°…+45°, up is positive).
// Cyan dot = live position from telemetry. White crosshair = tap/drag target.
private struct GimbalMinimapView: View {
    let pitch: Double    // live gimbal pitch  −90…+45
    let yaw: Double      // live gimbal yaw  −160…+160
    let history: [(pitch: Double, yaw: Double)]  // recent positions for trail
    let debugTarget: (pitch: Double, yaw: Double)?  // last confirmed target (orange dot)
    let isReady: Bool
    var onSelect: (Double, Double) -> Void   // (targetPitch, targetYaw)

    @State private var dragPt: CGPoint? = nil

    // Canvas size. Aspect mirrors angular spans: 320° yaw / 135° pitch ≈ 2.37
    private let mapW: CGFloat = 150
    private let mapH: CGFloat = 63

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let cx = w * 0.5
            let cy = h * CGFloat(45.0 / 135.0)

            // Soft limit-zone shading — orange-red gradient near the edges (≈15% inset)
            let edgeFade: CGFloat = 0.14
            // Left (yaw −160°) and right (yaw +160°) margins
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w * edgeFade, height: h)),
                     with: .color(.orange.opacity(0.08)))
            ctx.fill(Path(CGRect(x: w * (1 - edgeFade), y: 0, width: w * edgeFade, height: h)),
                     with: .color(.orange.opacity(0.08)))
            // Top (pitch +45°) and bottom (pitch −90°) margins
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h * edgeFade)),
                     with: .color(.orange.opacity(0.06)))
            ctx.fill(Path(CGRect(x: 0, y: h * (1 - edgeFade), width: w, height: h * edgeFade)),
                     with: .color(.orange.opacity(0.06)))

            // Center-reference crosshair (faint)
            var grid = Path()
            grid.move(to: CGPoint(x: cx, y: 0));  grid.addLine(to: CGPoint(x: cx, y: h))
            grid.move(to: CGPoint(x: 0,  y: cy)); grid.addLine(to: CGPoint(x: w,  y: cy))
            ctx.stroke(grid, with: .color(.white.opacity(0.18)), lineWidth: 0.5)

            // Corner labels (very faint — orientation cues)
            ctx.draw(Text("+45°").font(.system(size: 6)).foregroundStyle(Color.white.opacity(0.28)),
                     at: CGPoint(x: cx + 3, y: 1), anchor: .topLeading)
            ctx.draw(Text("−90°").font(.system(size: 6)).foregroundStyle(Color.white.opacity(0.28)),
                     at: CGPoint(x: cx + 3, y: h - 1), anchor: .bottomLeading)
            ctx.draw(Text("−160°").font(.system(size: 6)).foregroundStyle(Color.white.opacity(0.28)),
                     at: CGPoint(x: 2, y: cy - 1), anchor: .bottomLeading)
            ctx.draw(Text("+160°").font(.system(size: 6)).foregroundStyle(Color.white.opacity(0.28)),
                     at: CGPoint(x: w - 2, y: cy - 1), anchor: .bottomTrailing)

            // Position trail — fading dots from oldest (dim) to newest (bright)
            let count = history.count
            for (i, pos) in history.enumerated() {
                guard i < count - 1 else { continue }  // skip last — that's the live dot
                let alpha = Double(i) / Double(max(count - 1, 1)) * 0.55
                let tp = toPoint(pos.pitch, pos.yaw, w: w, h: h)
                let tr = CGFloat(1.5 + Double(i) / Double(max(count - 1, 1)) * 1.5)
                ctx.fill(Path(ellipseIn: CGRect(x: tp.x - tr, y: tp.y - tr,
                                               width: tr*2, height: tr*2)),
                         with: .color(.cyan.opacity(alpha)))
            }

            // Confirmed debug target — orange dot + ring (persists between drags)
            if let dt = debugTarget {
                let dtp = toPoint(dt.pitch, dt.yaw, w: w, h: h)
                ctx.fill(Path(ellipseIn: CGRect(x: dtp.x - 3.5, y: dtp.y - 3.5, width: 7, height: 7)),
                         with: .color(.orange))
                ctx.stroke(Path(ellipseIn: CGRect(x: dtp.x - 6, y: dtp.y - 6, width: 12, height: 12)),
                           with: .color(.orange.opacity(0.55)), lineWidth: 1)
            }

            // Drag crosshair (transient — white, shows while finger/mouse is down)
            if let tp = dragPt {
                let arm: CGFloat = 7
                var cross = Path()
                cross.move(to: CGPoint(x: tp.x - arm, y: tp.y))
                cross.addLine(to: CGPoint(x: tp.x + arm, y: tp.y))
                cross.move(to: CGPoint(x: tp.x, y: tp.y - arm))
                cross.addLine(to: CGPoint(x: tp.x, y: tp.y + arm))
                ctx.stroke(cross, with: .color(.white.opacity(0.8)), lineWidth: 1)
                ctx.fill(Path(ellipseIn: CGRect(x: tp.x - 2.5, y: tp.y - 2.5, width: 5, height: 5)),
                         with: .color(.white.opacity(0.6)))
            }

            // Current position — cyan dot with soft halo
            let cp = toPoint(pitch, yaw, w: w, h: h)
            let r: CGFloat = 4.5
            ctx.fill(Path(ellipseIn: CGRect(x: cp.x - r, y: cp.y - r, width: r*2, height: r*2)),
                     with: .color(.cyan))
            ctx.stroke(Path(ellipseIn: CGRect(x: cp.x - r - 1.5, y: cp.y - r - 1.5,
                                              width: (r+1.5)*2, height: (r+1.5)*2)),
                       with: .color(.cyan.opacity(0.35)), lineWidth: 1)
        }
        .frame(width: mapW, height: mapH)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.2), lineWidth: 0.5) }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { val in
                    let pt = CGPoint(x: val.location.x.clamped(0, mapW),
                                    y: val.location.y.clamped(0, mapH))
                    dragPt = pt
                    guard isReady else { return }
                    let (tp, ty) = toAngles(pt)
                    onSelect(tp, ty)
                }
                .onEnded { _ in dragPt = nil }
        )
    }

    private func toPoint(_ p: Double, _ y: Double, w: CGFloat, h: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat((y + 160) / 320) * w,
                y: CGFloat((45 - p) / 135) * h)
    }

    private func toAngles(_ pt: CGPoint) -> (Double, Double) {
        let p = (45 - Double(pt.y / mapH) * 135).clamped(-90, 45)
        let y = (-160 + Double(pt.x / mapW) * 320).clamped(-160, 160)
        return (p, y)
    }
}

// MARK: - Telemetry HUD

private struct TelemetryHUD: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Clickable position minimap with movement trail and debug target
            GimbalMinimapView(pitch: ctl.pitch, yaw: ctl.yaw,
                              history: ctl.positionHistory,
                              debugTarget: ctl.debugAngleTarget,
                              isReady: ctl.isReady) { tp, ty in
                ctl.moveToAngle(pitchDeg: tp, yawDeg: ty)
            }

            Divider().background(.white.opacity(0.3))
            axisRow(icon: "arrow.up.arrow.down",    label: "Tilt", value: ctl.pitch, color: .cyan,   range: -90...45)
            axisRow(icon: "arrow.left.arrow.right", label: "Pan",  value: ctl.yaw,   color: .orange, range: -160...160)
            axisRow(icon: "arrow.clockwise",        label: "Roll", value: ctl.roll,  color: .green,  range: -45...45)
            Divider().background(.white.opacity(0.3))
            HStack(spacing: 8) {
                if let bat = ctl.battery {
                    Label("\(bat)%", systemImage: batteryIcon(bat))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(bat < 20 ? Color.red : bat < 40 ? Color.orange : Color.white.opacity(0.8))
                }
                Circle().fill(ctl.isReady ? .green : .gray).frame(width: 5, height: 5)
                Text(ctl.connectionState.label)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
    }

    private func axisRow(icon: String, label: String, value: Double, color: Color,
                         range: ClosedRange<Double> = -90...90) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .frame(width: 12)
                .foregroundStyle(.white.opacity(0.55))
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .frame(width: 24, alignment: .leading)
            // Mini track — shows position within range
            AxisTrack(value: value, range: range, color: color)
                .frame(width: 48, height: 4)
            Text(String(format: "%+5.1f°", value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.25"
        default:    return "battery.0"
        }
    }
}

// MARK: - Axis track indicator

// Thin progress-bar style track showing the current angle position within its range.
// The filled portion is centred (0° = middle) so positive and negative deflection is visible.
private struct AxisTrack: View {
    let value: Double
    let range: ClosedRange<Double>
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let total = range.upperBound - range.lowerBound
            // Normalise 0..1 across full range
            let t = (value - range.lowerBound) / total
            // Centre line x in view coordinates
            let zeroX = CGFloat((-range.lowerBound) / total) * w
            let posX  = CGFloat(t) * w

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(.white.opacity(0.10))
                    .frame(height: h)

                // Filled segment from zero to current position
                let fillLeft  = min(zeroX, posX)
                let fillWidth = abs(posX - zeroX)
                Capsule()
                    .fill(color.opacity(0.80))
                    .frame(width: max(fillWidth, 2), height: h)
                    .offset(x: fillLeft)

                // Zero-centre tick
                Rectangle()
                    .fill(.white.opacity(0.30))
                    .frame(width: 1, height: h * 1.5)
                    .offset(x: zeroX - 0.5)

                // Current position dot
                Circle()
                    .fill(color)
                    .frame(width: h * 2.2, height: h * 2.2)
                    .offset(x: posX - h * 1.1)
            }
            .clipped()
        }
    }
}

// MARK: - Movement bar (angle control)

// Sliders set a TARGET angle sent on release.
// The HUD (top-right) shows the current live angle from telemetry.
// Press ↺ to snap the sliders to the gimbal's current position.
private struct MovementBar: View {
    @EnvironmentObject var ctl: GimbalController
    @State private var targetPitch: Double = 0
    @State private var targetYaw: Double = 0

    var body: some View {
        HStack(spacing: 14) {
            sliderGroup(
                icon: "arrow.up.arrow.down", label: "Tilt",
                value: $targetPitch, range: -90...45,
                current: ctl.pitch
            )

            Divider().frame(height: 20)

            sliderGroup(
                icon: "arrow.left.arrow.right", label: "Pan",
                value: $targetYaw, range: -160...160,
                current: ctl.yaw
            )

            Divider().frame(height: 20)

            // Snap sliders to live telemetry position
            Button {
                targetPitch = ctl.pitch
                targetYaw   = ctl.yaw
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Sync sliders to current gimbal position")

            Button { targetPitch = 0; targetYaw = 0; ctl.recenter() } label: {
                Image(systemName: "scope")
            }
            .help("Center gimbal")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(in: RoundedRectangle(cornerRadius: 0))
        .opacity(ctl.isReady ? 1.0 : 0.5)
        .disabled(!ctl.isReady)
    }

    private func sliderGroup(icon: String, label: String,
                             value: Binding<Double>, range: ClosedRange<Double>,
                             current: Double) -> some View {
        HStack(spacing: 8) {
            Label(label, systemImage: icon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            Slider(value: value, in: range, step: 1) { editing in
                if !editing {
                    ctl.setAngle(pitchDeg: targetPitch, yawDeg: targetYaw)
                }
            }
            .frame(maxWidth: 160)

            // Target value (what slider is set to)
            Text(String(format: "%+.0f°", value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 36, alignment: .trailing)

            // Live current angle from telemetry
            Text(String(format: "(%+.1f°)", current))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
        }
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @EnvironmentObject var ctl: GimbalController
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var settings: SettingsModel

    var body: some View {
        HStack(spacing: 12) {
            // Capture mode buttons
            captureButtons

            Divider().frame(height: 24)

            // Tracking
            Button {
                ctl.toggleTracking()
            } label: {
                Label(ctl.isTracking ? "Tracking" : "Track",
                      systemImage: ctl.isTracking ? "person.fill.viewfinder" : "person.and.arrow.left.and.arrow.right")
                    .foregroundStyle(ctl.isTracking ? .green : .primary)
            }

            Toggle(isOn: Binding(
                get: { settings.trackingFaceOnly },
                set: { settings.trackingFaceOnly = $0; ctl.setTrackingTarget(faceOnly: $0) }
            )) {
                Text(settings.trackingFaceOnly ? "Face" : "Body").font(.caption)
            }
            .toggleStyle(.button)

            Divider().frame(height: 24)

            // Mode
            Picker("", selection: Binding(get: { ctl.mode }, set: { ctl.setMode($0) })) {
                ForEach(GimbalController.Mode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)
            .disabled(!ctl.isReady)

            // Recenter / Stop
            Button { ctl.recenter() } label: {
                Image(systemName: "scope")
            }
            .disabled(!ctl.isReady)

            Button { ctl.stopMotion() } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(!ctl.isReady)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 0))
    }

    @ViewBuilder
    private var captureButtons: some View {
        let cam = cameraManager

        switch cam.captureMode {
        case .photo:
            CaptureButton(
                isActive: false,
                activeColor: .white,
                icon: "camera.fill",
                action: { cam.capturePhoto() }
            )
            .disabled(!cam.isRunning)

        case .video:
            CaptureButton(
                isActive: cam.isRecording,
                activeColor: .red,
                icon: cam.isRecording ? "stop.fill" : "record.circle.fill",
                action: { cam.toggleRecording() }
            )
            .disabled(!cam.isRunning)

        case .timelapse:
            CaptureButton(
                isActive: cam.isTimelapsing,
                activeColor: .orange,
                icon: cam.isTimelapsing ? "stop.fill" : "timer",
                action: { cam.isTimelapsing ? cam.stopTimelapse() : cam.startTimelapse() }
            )
            .disabled(!cam.isRunning)
        }
    }
}

// Prominent circular capture button with press-scale animation.
private struct CaptureButton: View {
    let isActive: Bool
    let activeColor: Color
    let icon: String
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isActive ? activeColor : Color.white.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Circle()
                            .stroke(isActive ? activeColor.opacity(0.5) : Color.white.opacity(0.35),
                                    lineWidth: 2)
                            .scaleEffect(isActive ? 1.25 : 1.0)
                            .opacity(isActive ? 0.6 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                       value: isActive)
                    }
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isActive ? .white : .white.opacity(0.9))
            }
            .scaleEffect(pressed ? 0.88 : 1.0)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.65), value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false }
        )
    }
}

// MARK: - Joystick widget

private struct JoystickWidget: View {
    @EnvironmentObject var ctl: GimbalController
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    private let size: CGFloat = 96
    private let knobSize: CGFloat = 34

    var body: some View {
        ZStack {
            // Base — subtle glass-style dark background
            Circle()
                .fill(RadialGradient(
                    colors: [Color(white: 0.20), Color(white: 0.04)],
                    center: .center, startRadius: 0, endRadius: size / 2
                ))
                .frame(width: size, height: size)
                .overlay {
                    Circle()
                        .stroke(
                            isDragging
                                ? Color.cyan.opacity(0.55)
                                : Color.white.opacity(0.28),
                            lineWidth: isDragging ? 1.5 : 1
                        )
                        .animation(.easeInOut(duration: 0.15), value: isDragging)
                }

            // Deflection zone rings
            Circle()
                .stroke(.white.opacity(0.07), lineWidth: 0.75)
                .frame(width: size * 0.72, height: size * 0.72)
            Circle()
                .stroke(.white.opacity(0.05), lineWidth: 0.75)
                .frame(width: size * 0.36, height: size * 0.36)

            // Crosshair + directional vector (drawn in Canvas for efficiency)
            joystickCanvas

            // Knob — glows cyan when dragging, white highlight from top-left
            Circle()
                .fill(RadialGradient(
                    colors: isDragging
                        ? [Color(white: 0.95), Color.cyan.opacity(0.55)]
                        : [Color(white: 0.98), Color(white: 0.68)],
                    center: UnitPoint(x: 0.36, y: 0.30),
                    startRadius: 0, endRadius: knobSize * 0.85
                ))
                .frame(width: knobSize, height: knobSize)
                .shadow(
                    color: isDragging ? .cyan.opacity(0.7) : .black.opacity(0.60),
                    radius: isDragging ? 14 : 4,
                    y: isDragging ? 0 : 2
                )
                .scaleEffect(isDragging ? 0.88 : 1.0)
                .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.70), value: isDragging)
                .offset(clampedOffset)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation
                    let maxR = (size - knobSize) / 2
                    let nx = (dragOffset.width  / maxR).clamped(-1, 1)
                    let ny = (-dragOffset.height / maxR).clamped(-1, 1)
                    ctl.setJoystickDriveRate(pitchRate: Double(ny), yawRate: Double(nx))
                }
                .onEnded { _ in
                    isDragging = false
                    dragOffset = .zero
                    ctl.setJoystickDriveRate(pitchRate: 0, yawRate: 0)
                }
        )
    }

    // Crosshair guide lines + live directional vector from center to knob position.
    private var joystickCanvas: some View {
        Canvas { ctx, sz in
            let mid  = sz.width / 2
            let arm  = sz.width / 4

            // Static crosshair
            var cross = Path()
            cross.move(to: CGPoint(x: mid, y: mid - arm))
            cross.addLine(to: CGPoint(x: mid, y: mid + arm))
            cross.move(to: CGPoint(x: mid - arm, y: mid))
            cross.addLine(to: CGPoint(x: mid + arm, y: mid))
            ctx.stroke(cross, with: .color(.white.opacity(0.16)), lineWidth: 0.75)

            // Directional vector — shown only while dragging
            let maxR = (sz.width - knobSize) / 2
            let ox = clampedOffset.width.clamped(-maxR, maxR)
            let oy = clampedOffset.height.clamped(-maxR, maxR)
            let mag = sqrt(ox*ox + oy*oy)
            guard mag > 4 else { return }

            var vec = Path()
            vec.move(to: CGPoint(x: mid, y: mid))
            vec.addLine(to: CGPoint(x: mid + ox, y: mid + oy))
            let intensity = min(1.0, mag / maxR)
            ctx.stroke(vec,
                       with: .color(Color.cyan.opacity(Double(intensity) * 0.65)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(width: size, height: size)
    }

    private var clampedOffset: CGSize {
        let maxR = (size - knobSize) / 2
        return CGSize(width:  dragOffset.width.clamped(-maxR, maxR),
                      height: dragOffset.height.clamped(-maxR, maxR))
    }
}

// MARK: - Grid overlay

private struct GridOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var path = Path()
            path.move(to: CGPoint(x: w / 3, y: 0))
            path.addLine(to: CGPoint(x: w / 3, y: h))
            path.move(to: CGPoint(x: 2 * w / 3, y: 0))
            path.addLine(to: CGPoint(x: 2 * w / 3, y: h))
            path.move(to: CGPoint(x: 0, y: h / 3))
            path.addLine(to: CGPoint(x: w, y: h / 3))
            path.move(to: CGPoint(x: 0, y: 2 * h / 3))
            path.addLine(to: CGPoint(x: w, y: 2 * h / 3))
            ctx.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1)
        }
    }
}

// MARK: - Log pane (retained for debug access via sheet or separate panel)

struct LogPane: View {
    @EnvironmentObject var ctl: GimbalController
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: LogTab = .all
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    enum LogTab: String, CaseIterable, Identifiable {
        case all = "All", actions = "Actions", commands = "Commands"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("BLE Diagnostics").font(.headline)
                Spacer()
                Toggle("Hide frequent", isOn: $ctl.hideFrequentLogs)
                    .font(.caption)
                Spacer()
                Button {
                    let text = filteredLogs.map { entry in
                        "[\(Self.formatter.string(from: entry.timestamp))] \(directionPrefix(entry.direction)) \(entry.text)"
                    }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy filtered logs")

                Button("Clear") { ctl.clearLog() }.buttonStyle(.borderless)

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Picker("View", selection: $selectedTab) {
                ForEach(LogTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredLogs) { entry in
                            LogRow(entry: entry, showAction: selectedTab == .actions).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .onChange(of: filteredLogs.count) { _, _ in
                    if let last = filteredLogs.last {
                        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private var filteredLogs: [GimbalController.LogEntry] {
        switch selectedTab {
        case .all:
            return ctl.log
        case .actions:
            return ctl.log.filter { $0.action != nil }
        case .commands:
            return ctl.log.filter { $0.direction == .tx || $0.direction == .err }
        }
    }

    private func directionPrefix(_ d: GimbalController.LogEntry.Direction) -> String {
        switch d {
        case .info: return " • "
        case .tx:   return " → "
        case .rx:   return " ← "
        case .err:  return " ⚠ "
        }
    }
}

private struct LogRow: View {
    let entry: GimbalController.LogEntry
    let showAction: Bool
    @State private var expanded = false
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                Text(Self.formatter.string(from: entry.timestamp))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(prefix)
                    .foregroundStyle(color)
                    .frame(width: 18, alignment: .leading)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                if let action = entry.action, showAction {
                    Text(action)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }
                Text(entry.text)
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer()
                if entry.payload != nil {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.gray)
                }
            }

            if expanded, let payload = entry.payload {
                HStack(spacing: 8) {
                    Text("Payload:")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(hex(payload))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.cyan)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 2)
    }

    private var prefix: String {
        switch entry.direction {
        case .info: return "•"
        case .tx:   return "→"
        case .rx:   return "←"
        case .err:  return "⚠"
        }
    }

    private var color: Color {
        switch entry.direction {
        case .info: return .secondary
        case .tx:   return .blue
        case .rx:   return .green
        case .err:  return .red
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// MARK: - View helpers

private extension View {
    func onKeyEvents(down: @escaping (String) -> Void, up: @escaping (String) -> Void) -> some View {
        background(KeyEventView(onKeyDown: down, onKeyUp: up))
    }
}

// NSViewRepresentable shim to capture key events in SwiftUI.
private struct KeyEventView: NSViewRepresentable {
    var onKeyDown: ((String) -> Void)?
    var onKeyUp: ((String) -> Void)?

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let v = KeyCaptureNSView()
        v.onKeyDown = onKeyDown
        v.onKeyUp = onKeyUp
        return v
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.onKeyUp = onKeyUp
    }
}

final class KeyCaptureNSView: NSView {
    var onKeyDown: ((String) -> Void)?
    var onKeyUp: ((String) -> Void)?

    private static let arrowKeys: [UInt16: String] = [
        126: String(UnicodeScalar(NSUpArrowFunctionKey)!),
        125: String(UnicodeScalar(NSDownArrowFunctionKey)!),
        123: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        124: String(UnicodeScalar(NSRightArrowFunctionKey)!)
    ]

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return }
        onKeyDown?(Self.arrowKeys[event.keyCode] ?? key)
    }

    override func keyUp(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return }
        onKeyUp?(Self.arrowKeys[event.keyCode] ?? key)
    }
}


#Preview {
    let ctl = GimbalController()
    ContentView()
        .environmentObject(ctl)
        .environmentObject(ctl.cameraManager)
        .environmentObject(ctl.settings)
}
