import Foundation
import Combine

/// F0 — Integração do experimento de offset de pitch/yaw.
///
/// Componente **desacoplado**: assina `GimbalController.frameEvents`, decodifica
/// a telemetria (`getPos` 0x02 / `positionPush` 0x05) e publica os ângulos crus
/// e corrigidos pelo offset por eixo capturado no centro. Não modifica o
/// `GimbalController` (~48 KB). Para fechar o loop de controle, consuma
/// `correctedPitch`/`correctedYaw` onde hoje se lê `controller.pitch/yaw`
/// (ver `docs/INTEGRATION.md`).
///
/// Usa apenas os helpers puros de `TelemetryNormalization` para evitar a colisão
/// entre as duas declarações `AxisOffsetModel` do projeto.
@MainActor
final class TelemetryOffsetModel: ObservableObject {

    @Published var enabled: Bool = false { didSet { recompute() } }

    @Published private(set) var rawPitch: Double = 0
    @Published private(set) var rawYaw: Double = 0
    @Published private(set) var correctedPitch: Double = 0
    @Published private(set) var correctedYaw: Double = 0
    @Published private(set) var pitchOffsetDegrees: Double?
    @Published private(set) var yawOffsetDegrees: Double?

    private var cancellable: AnyCancellable?

    init(controller: GimbalController) {
        cancellable = controller.frameEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in self?.ingest(frame) }
    }

    /// Captura o offset por eixo assumindo gimbal comandado para o centro (0°).
    /// Chamar ~1 s após `recenter()`.
    func captureOffsetAtCenter() {
        pitchOffsetDegrees = TelemetryNormalization.angularDifference(rawPitch, 0)
        yawOffsetDegrees   = TelemetryNormalization.angularDifference(rawYaw, 0)
        recompute()
    }

    func reset() {
        pitchOffsetDegrees = nil
        yawOffsetDegrees = nil
        recompute()
    }

    private func ingest(_ frame: DUMLFrame) {
        guard frame.cmdSet == DUML.CmdSet.gimbal else { return }
        let p = frame.payload
        switch frame.cmdId {
        case DUML.GimbalCmd.getPos where p.count >= 7:
            // [flags pitch_lo pitch_hi roll_lo roll_hi yaw_lo yaw_hi ...]
            rawPitch = TelemetryNormalization.decodeAngleDeciDegrees(lo: p[1], hi: p[2])
            rawYaw   = TelemetryNormalization.decodeAngleDeciDegrees(lo: p[5], hi: p[6])
            recompute()
        case DUML.GimbalCmd.positionPush where p.count >= 6:
            // [pitch_lo pitch_hi roll_lo roll_hi yaw_lo yaw_hi ...]
            rawPitch = TelemetryNormalization.decodeAngleDeciDegrees(lo: p[0], hi: p[1])
            rawYaw   = TelemetryNormalization.decodeAngleDeciDegrees(lo: p[4], hi: p[5])
            recompute()
        default:
            break
        }
    }

    private func recompute() {
        correctedPitch = corrected(rawPitch, offset: pitchOffsetDegrees)
        correctedYaw   = corrected(rawYaw, offset: yawOffsetDegrees)
    }

    private func corrected(_ raw: Double, offset: Double?) -> Double {
        guard enabled, let offset else { return raw }
        return TelemetryNormalization.normalizeDegrees(raw - offset)
    }
}
