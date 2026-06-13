import SwiftUI
import AppKit

// MARK: - MenuBarExtra content (Guia Apple §2 / F2)
//
// Controle rápido na barra de menus: status do gimbal, telemetria e ações
// essenciais (recentralizar, tracking, parar). Usa apenas API já existente no
// GimbalController.
struct QuickControlMenu: View {
    @EnvironmentObject private var controller: GimbalController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.isReady ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(controller.isReady ? "Gimbal conectado" : "Gimbal desconectado")
                    .font(.headline)
            }

            Text(String(format: "Pitch %+.0f°   Yaw %+.0f°", controller.pitch, controller.yaw))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Divider()

            Button { controller.recenter() } label: {
                Label("Recentralizar", systemImage: "scope")
            }
            .disabled(!controller.isReady)

            Button { controller.toggleTracking() } label: {
                Label("Alternar tracking", systemImage: "viewfinder")
            }
            .disabled(!controller.isReady)

            Button { controller.stopMotion() } label: {
                Label("Parar movimento", systemImage: "stop.fill")
            }
            .disabled(!controller.isReady)

            Divider()

            HStack {
                SettingsLink { Text("Ajustes…") }
                Spacer()
                Button("Sair") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 260)
        .buttonStyle(.borderless)
    }
}
