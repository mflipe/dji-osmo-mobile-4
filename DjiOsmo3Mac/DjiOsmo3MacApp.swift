import SwiftUI

@main
struct DjiOsmo3MacApp: App {
    @StateObject private var controller = GimbalController()

    var body: some Scene {
        Window("Osmo Mobile 3", id: "main") {
            ContentView()
                .environmentObject(controller)
        }
        .windowStyle(.plain)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Gimbal") {
                Button("Recenter") { controller.recenter() }
                    .keyboardShortcut("0", modifiers: [])
                    .disabled(!controller.isReady)
                Button("Stop motion") { controller.stopMotion() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!controller.isReady)
                Divider()
                Button("Toggle tracking") { controller.toggleTracking() }
                    .keyboardShortcut("t", modifiers: [.command])
                    .disabled(!controller.isReady)
            }
        }
    }
}
