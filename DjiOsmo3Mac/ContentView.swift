import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()

            HStack(alignment: .top, spacing: 0) {
                LeftColumn()
                    .frame(width: 280)
                    .padding(12)

                Divider()

                RightColumn()
                    .padding(12)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            LogPane()
                .frame(height: 160)
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        HStack(spacing: 14) {
            statusDot
            Text(ctl.connectionState.label)
                .font(.headline)
            if let dev = ctl.selected {
                Text("• \(dev.name)").foregroundStyle(.secondary)
            }
            if let bat = ctl.battery {
                Label("\(bat)%", systemImage: "battery.50")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("BLE: \(bleLabel)").foregroundStyle(.secondary).font(.caption)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    private var statusColor: Color {
        switch ctl.connectionState {
        case .ready: return .green
        case .connected, .pairing, .discoveringServices: return .yellow
        case .scanning, .connecting: return .blue
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var bleLabel: String {
        switch ctl.bleState {
        case .poweredOn: return "ready"
        case .poweredOff: return "off"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "?"
        }
    }
}

// MARK: - Left column (scan / connect)

private struct LeftColumn: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Devices").font(.headline)

            HStack {
                Button {
                    if case .scanning = ctl.connectionState { ctl.stopScan() }
                    else { ctl.startScan() }
                } label: {
                    if case .scanning = ctl.connectionState {
                        Label("Stop scan", systemImage: "stop.circle")
                    } else {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                }
                .disabled(ctl.bleState != .poweredOn)
                Spacer()
            }

            List(ctl.devices) { dev in
                Button {
                    ctl.connect(dev)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(dev.name).font(.system(.body, design: .rounded))
                            Text("RSSI \(dev.rssi) dBm")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if ctl.selected?.id == dev.id { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.bordered)
            .frame(minHeight: 160)

            Divider()

            Text("Pairing").font(.headline)
            Toggle("Auto-pair on connect", isOn: $ctl.autoPair)
            HStack {
                Text("PIN").frame(width: 60, alignment: .leading)
                TextField("", text: $ctl.pin).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("ID").frame(width: 60, alignment: .leading)
                TextField("", text: $ctl.identifier).textFieldStyle(.roundedBorder).font(.caption)
            }
            Button("Re-pair") { ctl.startPairing() }
                .disabled(!isConnected)

            Spacer()

            Button(role: .destructive) { ctl.disconnect() } label: {
                Label("Disconnect", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
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

// MARK: - Right column (control + telemetry)

private struct RightColumn: View {
    @EnvironmentObject var ctl: GimbalController
    @State private var pitchSlider: Double = 0
    @State private var yawSlider: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Mode selector
            VStack(alignment: .leading, spacing: 6) {
                Text("Mode").font(.headline)
                Picker("", selection: Binding(
                    get: { ctl.mode },
                    set: { ctl.setMode($0) }
                )) {
                    ForEach(GimbalController.Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!isReady)
            }

            // Recenter
            HStack {
                Button {
                    ctl.recenter()
                    pitchSlider = 0
                    yawSlider = 0
                } label: {
                    Label("Recenter", systemImage: "scope").frame(maxWidth: .infinity)
                }
                .disabled(!isReady)

                Button {
                    ctl.stopMotion()
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .disabled(!isReady)
            }

            Divider()

            // Sliders
            Text("Angle Control").font(.headline)
            slider(title: "Pitch", value: $pitchSlider, range: -90...30, unit: "°")
                .onChange(of: pitchSlider) { _, new in
                    if isReady { ctl.setAngle(pitchDeg: new, yawDeg: yawSlider) }
                }

            slider(title: "Yaw", value: $yawSlider, range: -180...180, unit: "°")
                .onChange(of: yawSlider) { _, new in
                    if isReady { ctl.setAngle(pitchDeg: pitchSlider, yawDeg: new) }
                }

            Divider()

            // Telemetry
            Text("Telemetry").font(.headline)
            HStack(spacing: 10) {
                axisCard("Pitch", ctl.pitch, color: .blue)
                axisCard("Roll",  ctl.roll,  color: .green)
                axisCard("Yaw",   ctl.yaw,   color: .orange)
            }

            Spacer()
        }
    }

    private func slider(title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        unit: String) -> some View {
        HStack {
            Text(title).frame(width: 50, alignment: .leading)
            Slider(value: value, in: range, step: 1)
                .disabled(!isReady)
            Text("\(Int(value.wrappedValue))\(unit)")
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func axisCard(_ title: String, _ value: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f°", value))
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var isReady: Bool {
        if case .ready = ctl.connectionState { return true }
        if case .connected = ctl.connectionState { return true }
        return false
    }
}

// MARK: - Log

private struct LogPane: View {
    @EnvironmentObject var ctl: GimbalController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Clear") { ctl.clearLog() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(ctl.log) { entry in
                            LogRow(entry: entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: ctl.log.count) { _, _ in
                    if let last = ctl.log.last {
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
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
            Text(Self.formatter.string(from: entry.timestamp))
                .foregroundStyle(.secondary)
            Text(prefix)
                .foregroundStyle(color)
                .frame(width: 22, alignment: .leading)
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

#Preview {
    ContentView().environmentObject(GimbalController())
}
