import SwiftUI

@main
struct DjiOsmo3MacApp: App {
    @StateObject private var controller = GimbalController()

    var body: some Scene {
        Window("Osmo Mobile 3 Control", id: "main") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 720, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}
