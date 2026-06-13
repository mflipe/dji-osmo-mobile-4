import Foundation
import Combine

// MARK: - Demo mode (F3 / Guia Apple §5)
//
// Gera telemetria pitch/yaw simulada a ~15 Hz para demonstrar a UI sem um gimbal
// físico conectado — útil para o reviewer da App Store e para desenvolvimento.
// Standalone: não depende do GimbalController. Ligue observando
// @AppStorage("demoMode") e alimentando a UI com estes valores (ver INTEGRATION.md).
@MainActor
final class DemoModeController: ObservableObject {

    @Published private(set) var pitch: Double = 0
    @Published private(set) var yaw: Double = 0
    @Published private(set) var isRunning: Bool = false

    private var cancellable: AnyCancellable?
    private var t: Double = 0
    private let hz: Double = 15

    func start() {
        guard !isRunning else { return }
        isRunning = true
        t = 0
        cancellable = Timer.publish(every: 1.0 / hz, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func stop() {
        isRunning = false
        cancellable = nil
        pitch = 0
        yaw = 0
    }

    private func tick() {
        t += 1.0 / hz
        // Varredura suave e limitada, como um sujeito se movendo numa reunião.
        yaw   = 45 * sin(t * 0.40)
        pitch = 15 * sin(t * 0.25)
    }
}
