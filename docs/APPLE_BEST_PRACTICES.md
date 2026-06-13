# Guia — Melhores Práticas Apple: HIG, Liquid Glass e Customer-Ready

> Versão em repositório do guia mantido no Notion. Objetivo: app otimizado e pronto para usuários finais (customer-ready), alinhado ao macOS 26.

## 1. Liquid Glass (WWDC25)

- Componentes padrão (toolbar, sidebar, controles) adotam Liquid Glass **automaticamente** ao recompilar com Xcode 26 — prefira componentes padrão a custom views.
- `glassEffect(_:in:)` com parcimônia: só em overlays flutuantes (HUD de telemetria, controles sobre o preview de vídeo). **Não** aplicar no painel de log.
- Tinting seletivo; `ToolbarSpacer` para agrupar ações na toolbar.
- Reduced Transparency / Increased Contrast / Reduce Motion são respeitados automaticamente pelos componentes padrão.

**Ações no projeto:** recompilar com Xcode 26; migrar VStack/HStack custom para componentes padrão; glass apenas nos overlays do preview. Helper reutilizável incluído: `LiquidGlass.swift` (`.osmoGlass()` / `.osmoGlassCapsule()` com fallback `< macOS 26`).

## 2. HIG macOS

- Múltiplas janelas/cenas em vez de uma janela monolítica; `Settings` scene para preferências; menu bar completo com atalhos.
- Empty states claros (sem dispositivo, sem câmera, sem permissão).

**Ações:** quebrar `ContentView.swift` (~80 KB) em cenas menores; `MenuBarExtra` para controle rápido (incluído: `QuickControlMenu.swift`); cena `Settings` (incluída: `AppSettingsView.swift`); onboarding BLE guiado.

## 3. Performance SwiftUI

⚠️ **Ponto crítico:** `GimbalController` é um `ObservableObject` único com dezenas de `@Published` + telemetria a ~25 Hz → invalida a árvore inteira de views a cada frame.

- Separar em `TelemetryModel` / `ConnectionModel` / `SettingsModel` com a macro `@Observable` (tracking por propriedade).
- Throttle da telemetria para a UI (10–15 Hz), mantendo taxa cheia no loop PID.
- Ring buffer no log (evitar array crescente re-renderizado).
- Perfilar com o SwiftUI Instrument (Instruments 26).
- Pipeline de vídeo via Metal/CoreImage, nunca por re-render SwiftUI.

## 4. Acessibilidade

- VoiceOver em todos os controles (testar com Cmd+F5); Full Keyboard Access; contraste AA.
- Accessibility Nutrition Labels na App Store ("Supports VoiceOver").

## 5. Checklist customer-ready

- [ ] Bundle ID próprio (`com.example.*` é **bloqueador**)
- [ ] Assinatura + notarização
- [ ] `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`
- [ ] Privacy Nutrition Label: tracking 100% local, nenhum dado sai do Mac
- [ ] Política de privacidade publicada
- [ ] Zero crashes em fluxo principal; modo demo p/ reviewer sem OM3 + vídeo nas Notes for Review
- [ ] **Não** usar "DJI" no nome do app (marca registrada)
- [ ] Ícone via Icon Composer
- [ ] Testes automatizados (ver `Tests/`)

## 6. Ordem de ataque (amarrada ao roadmap)

| Fase | Item deste guia |
|---|---|
| F0 | Testes do codec DUML (`Tests/`); separar TelemetryModel (destrava throttle) |
| F1 | Bundle ID + assinatura; usage descriptions; recompilar Xcode 26 |
| F2 | MenuBarExtra; empty states; acessibilidade; Liquid Glass nos overlays |
| F3 | Nutrition Labels; notarização; modo demo; distribuição |

## Referências

- developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
- WWDC25: 219 (Meet Liquid Glass), 356 (New design system), 323 (SwiftUI new design), 256 (What's new in SwiftUI), 306 (Optimize SwiftUI performance with Instruments), 229 (Make your Mac app more accessible)
- developer.apple.com/design/human-interface-guidelines/designing-for-macos
- developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance
- developer.apple.com/app-store/review/guidelines/
