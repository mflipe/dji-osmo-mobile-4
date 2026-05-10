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
    }
}

// MARK: - Sidebar

enum SidebarItem: String, CaseIterable, Identifiable {
    case devices  = "Devices"
    case camera   = "Camera"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .devices:  return "wave.3.right"
        case .camera:   return "camera"
        case .settings: return "slider.horizontal.3"
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
                case .devices:  DevicePanel()
                case .camera:   CameraPanel()
                case .settings: SettingsPanel()
                case .none:     EmptyView()
                }
            }
            .padding(10)
        }
    }
}

// MARK: - Sidebar panels

private struct DevicePanel: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            .frame(minHeight: 120, maxHeight: 200)

            Divider()
            Toggle("Auto-pair", isOn: $ctl.autoPair)
            HStack {
                Text("PIN").frame(width: 40)
                TextField("", text: $ctl.pin).textFieldStyle(.roundedBorder)
            }
            Button("Re-pair") { ctl.startPairing() }
                .disabled(!isConnected)
        }
    }

    private var isConnected: Bool {
        switch ctl.connectionState {
        case .connected, .pairing, .ready: return true
        default: return false
        }
    }
}

private struct CameraPanel: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera").font(.headline)

            Picker("Device", selection: Binding(
                get: { ctl.cameraManager.selectedCamera },
                set: { if let cam = $0 { ctl.cameraManager.switchCamera(cam) } }
            )) {
                ForEach(ctl.cameraManager.availableCameras, id: \.uniqueID) { cam in
                    Text(cam.localizedName).tag(Optional(cam))
                }
            }

            Picker("Mode", selection: $ctl.cameraManager.captureMode) {
                ForEach(CaptureMode.allCases) { m in
                    Label(m.rawValue, systemImage: m.systemImage).tag(m)
                }
            }

            if ctl.cameraManager.captureMode == .timelapse {
                HStack {
                    Text("Interval").font(.caption)
                    Slider(value: $ctl.cameraManager.timelapseInterval, in: 0.5...30, step: 0.5)
                    Text("\(String(format: "%.1f", ctl.cameraManager.timelapseInterval))s")
                        .font(.caption).monospacedDigit()
                }
            }

            Toggle("Grid overlay", isOn: $ctl.settings.showGrid)
        }
    }
}

private struct SettingsPanel: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gimbal").font(.headline)

            Picker("Speed", selection: $ctl.settings.joystickSpeed) {
                ForEach(JoystickSpeed.allCases) { s in Text(s.rawValue).tag(s) }
            }

            Picker("Axis", selection: $ctl.settings.axisMode) {
                ForEach(AxisMode.allCases) { a in Text(a.rawValue).tag(a) }
            }

            Toggle("Invert pan",  isOn: $ctl.settings.invertPan)
            Toggle("Invert tilt", isOn: $ctl.settings.invertTilt)
            Toggle("Sport multiplier", isOn: $ctl.settings.sportMode)

            Divider()
            Text("M button").font(.headline)
            Picker("Action", selection: $ctl.settings.mButtonAction) {
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

                // Bottom bar
                BottomBar()
            }
        }
        .toolbar { toolbarContent }
        .background(.black)
        .onAppear {
            if !ctl.cameraManager.isRunning { ctl.cameraManager.start() }
        }
    }

    @ViewBuilder
    private var cameraBackground: some View {
        if ctl.cameraManager.isRunning {
            CameraPreviewView(cameraManager: ctl.cameraManager,
                              trackingBounds: ctl.trackingBounds)
                .ignoresSafeArea()
            if ctl.settings.showGrid {
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
            if ctl.cameraManager.isRecording {
                RecordingIndicator()
            }
        }
    }
}

// MARK: - Toolbar chips

private struct StatusChip: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
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

// MARK: - Telemetry HUD

private struct TelemetryHUD: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            axisRow("P", ctl.pitch, color: .cyan)
            axisRow("R", ctl.roll,  color: .green)
            axisRow("Y", ctl.yaw,   color: .orange)
            Divider().background(.white.opacity(0.3))
            HStack(spacing: 8) {
                if let bat = ctl.battery {
                    Label("\(bat)%", systemImage: "battery.50").font(.caption2)
                }
                Circle().fill(ctl.isReady ? .green : .gray).frame(width: 6, height: 6)
                Text(ctl.connectionState.label).font(.caption2)
            }
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
    }

    private func axisRow(_ axis: String, _ value: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(axis).font(.caption2.weight(.semibold)).frame(width: 12)
            Text(String(format: "%+7.1f°", value))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @EnvironmentObject var ctl: GimbalController

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
                get: { ctl.settings.trackingFaceOnly },
                set: { ctl.settings.trackingFaceOnly = $0; ctl.setTrackingTarget(faceOnly: $0) }
            )) {
                Text(ctl.settings.trackingFaceOnly ? "Face" : "Body").font(.caption)
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
        let cam = ctl.cameraManager

        switch cam.captureMode {
        case .photo:
            Button { cam.capturePhoto() } label: {
                Image(systemName: "camera.circle.fill").font(.title2)
            }
            .disabled(!cam.isRunning)

        case .video:
            Button { cam.toggleRecording() } label: {
                Image(systemName: cam.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(cam.isRecording ? .red : .primary)
            }
            .disabled(!cam.isRunning)

        case .timelapse:
            Button {
                if cam.isTimelapsing { cam.stopTimelapse() } else { cam.startTimelapse() }
            } label: {
                Image(systemName: cam.isTimelapsing ? "stop.circle.fill" : "timer.circle")
                    .font(.title2)
                    .foregroundStyle(cam.isTimelapsing ? .orange : .primary)
            }
            .disabled(!cam.isRunning)
        }
    }
}

// MARK: - Joystick widget

private struct JoystickWidget: View {
    @EnvironmentObject var ctl: GimbalController
    @State private var dragOffset: CGSize = .zero
    private let size: CGFloat = 80
    private let knobSize: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: size, height: size)

            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: knobSize, height: knobSize)
                .offset(clampedOffset)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragOffset = value.translation
                    let max = (size - knobSize) / 2
                    let nx = Double(dragOffset.width / max)
                    let ny = Double(-dragOffset.height / max)
                    let speed = ctl.settings.joystickSpeed.degreesPerSecond
                    if ctl.isReady {
                        ctl.setSpeed(pitchDeg: ny * speed, yawDeg: nx * speed)
                    }
                }
                .onEnded { _ in
                    dragOffset = .zero
                    ctl.stopMotion()
                }
        )
        .opacity(0.85)
    }

    private var clampedOffset: CGSize {
        let max = (size - knobSize) / 2
        let x = dragOffset.width.clamped(-max, max)
        let y = dragOffset.height.clamped(-max, max)
        return CGSize(width: x, height: y)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Clear") { ctl.clearLog() }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(ctl.log) { entry in
                            LogRow(entry: entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                .onChange(of: ctl.log.count) { _, _ in
                    if let last = ctl.log.last {
                        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

private struct LogRow: View {
    let entry: GimbalController.LogEntry
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.formatter.string(from: entry.timestamp)).foregroundStyle(.secondary)
            Text(prefix).foregroundStyle(color).frame(width: 22, alignment: .leading)
            Text(entry.text).textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var prefix: String {
        switch entry.direction {
        case .info: return "•"
        case .tx:   return "TX"
        case .rx:   return "RX"
        case .err:  return "!"
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
    ContentView().environmentObject(GimbalController())
}
