import Foundation

// MARK: - AxisOffsetModel
//
// Problema observado (documentado no mapa técnico / Notion):
//   Após recenter(), a telemetria lê pitch ≈ −179,9° e yaw ≈ −91°
//   em vez de 0°. O offset é consistente por sessão BLE.
//
// Este model implementa três estratégias para o experimento F0:
//
//   .absoluteWithOffset  — captura o offset uma vez (pós-recenter) e
//                          subtrai de toda leitura de telemetria subsequente.
//                          É a abordagem mais simples e não requer mudança
//                          no protocolo de comando.
//
//   .relativeCommands    — usa RotationMode.relative (0x04) em vez de
//                          .absolute (0x05). O gimbal aceita deltas, tornando
//                          o offset de coordenadas irrelevante para o PID.
//
//   .raw                 — sem normalização (modo padrão / debug).
//
// Uso:
//   1. Conectar + recenter().
//   2. Chamar captureOffset(pitch:roll:yaw:) com a telemetria logo após o
//      recenter assentar (≥ 1s).
//   3. Usar normalizedPitch/normalizedYaw no PID e no minimap.

@MainActor
final class AxisOffsetModel: ObservableObject {

    // MARK: Strategy

    enum Strategy: String, CaseIterable, Identifiable {
        case raw                = "Raw (sem normalização)"
        case absoluteWithOffset = "Absoluto + offset"
        case relativeCommands   = "Modo relativo (0x04)"
        var id: String { rawValue }
    }

    @Published var strategy: Strategy = .absoluteWithOffset

    // MARK: Captured offsets

    @Published private(set) var pitchOffset: Double = 0
    @Published private(set) var rollOffset:  Double = 0
    @Published private(set) var yawOffset:   Double = 0
    @Published private(set) var isCalibrated: Bool = false

    // MARK: Capture

    /// Call this once after `recenter()` has settled (≥ 1 s after command).
    /// Pass the raw telemetry values read from positionPush / getPos.
    func captureOffset(pitch: Double, roll: Double, yaw: Double) {
        pitchOffset = pitch
        rollOffset  = roll
        yawOffset   = yaw
        isCalibrated = true
    }

    func resetOffset() {
        pitchOffset  = 0
        rollOffset   = 0
        yawOffset    = 0
        isCalibrated = false
    }

    // MARK: Normalization

    /// Returns the calibrated pitch angle, wrapped to −180…+180°.
    func normalizedPitch(_ raw: Double) -> Double {
        guard strategy == .absoluteWithOffset, isCalibrated else { return raw }
        return Self.wrap180(raw - pitchOffset)
    }

    /// Returns the calibrated yaw angle, wrapped to −180…+180°.
    func normalizedYaw(_ raw: Double) -> Double {
        guard strategy == .absoluteWithOffset, isCalibrated else { return raw }
        return Self.wrap180(raw - yawOffset)
    }

    /// Returns the calibrated roll angle, wrapped to −180…+180°.
    func normalizedRoll(_ raw: Double) -> Double {
        guard strategy == .absoluteWithOffset, isCalibrated else { return raw }
        return Self.wrap180(raw - rollOffset)
    }

    // MARK: Command helpers

    /// Whether commands should use RotationMode.relative (0x04).
    var useRelativeMode: Bool { strategy == .relativeCommands }

    // MARK: Wrapped angle arithmetic

    /// Wraps an angle to the range −180 < θ ≤ +180.
    static func wrap180(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a > 180  { a -= 360 }
        if a <= -180 { a += 360 }
        return a
    }

    // MARK: Diagnostics

    var diagnosticSummary: String {
        guard isCalibrated else { return "Not calibrated" }
        return String(format: "Offset → P: %+.1f°  R: %+.1f°  Y: %+.1f°  strategy: %@",
                      pitchOffset, rollOffset, yawOffset, strategy.rawValue)
    }
}
