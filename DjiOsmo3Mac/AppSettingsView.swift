import SwiftUI

// MARK: - Settings scene (Guia Apple §2 / F2)
//
// Cena de preferências do app. Foca nos recursos novos do plano (offset F0,
// throttle de telemetria da UI, modo demo). As preferências existentes de
// joystick/eixos continuam na ContentView.
struct AppSettingsView: View {
    @EnvironmentObject private var telemetryOffset: TelemetryOffsetModel

    @AppStorage("applyTelemetryOffset") private var applyTelemetryOffset = false
    @AppStorage("telemetryUIHz") private var telemetryUIHz = 12.0
    @AppStorage("demoMode") private var demoMode = false

    var body: some View {
        TabView {
            Form {
                Section("Offset de telemetria (F0)") {
                    Toggle("Aplicar correção de offset", isOn: $applyTelemetryOffset)
                        .onChange(of: applyTelemetryOffset) { _, newValue in
                            telemetryOffset.enabled = newValue
                        }
                    Button("Capturar offset no centro") {
                        telemetryOffset.captureOffsetAtCenter()
                    }
                    LabeledContent("Offset pitch",
                                   value: telemetryOffset.pitchOffsetDegrees.map { String(format: "%+.1f°", $0) } ?? "—")
                    LabeledContent("Offset yaw",
                                   value: telemetryOffset.yawOffsetDegrees.map { String(format: "%+.1f°", $0) } ?? "—")
                    LabeledContent("Pitch (cru → corrigido)",
                                   value: String(format: "%+.1f° → %+.1f°", telemetryOffset.rawPitch, telemetryOffset.correctedPitch))
                    LabeledContent("Yaw (cru → corrigido)",
                                   value: String(format: "%+.1f° → %+.1f°", telemetryOffset.rawYaw, telemetryOffset.correctedYaw))
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Telemetria", systemImage: "scope") }

            Form {
                Section("Performance") {
                    Slider(value: $telemetryUIHz, in: 5...30, step: 1) {
                        Text("UI telemetry Hz")
                    }
                    Text("Taxa de atualização da telemetria na UI. O loop PID mantém taxa cheia.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Demonstração") {
                    Toggle("Modo demo (sem gimbal)", isOn: $demoMode)
                    Text("Gera telemetria simulada para demonstrar a UI sem hardware.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Avançado", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 480, height: 380)
        .onAppear { telemetryOffset.enabled = applyTelemetryOffset }
    }
}
