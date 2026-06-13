import SwiftUI

// MARK: - Liquid Glass helpers (Guia Apple §1)
//
// Modifiers reutilizáveis para overlays flutuantes sobre o preview de vídeo
// (HUD de telemetria, controles de joystick). Usam `glassEffect` no macOS 26+
// e caem para `.ultraThinMaterial` em versões anteriores. NÃO usar no painel de
// log nem em superfícies de conteúdo densas.

extension View {
    /// Vidro com cantos arredondados, para painéis/HUD flutuantes.
    @ViewBuilder
    func osmoGlass(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }

    /// Vidro em cápsula, para pills/controles compactos flutuantes.
    @ViewBuilder
    func osmoGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
