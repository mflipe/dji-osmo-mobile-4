# Guia — Melhores Práticas Apple: HIG, Liquid Glass e Customer-Ready

> Consolida as práticas de desenvolvimento Apple (macOS 26 / Xcode 26) aplicadas a este projeto, com ações concretas por área. Fontes ao final.

## 1. Liquid Glass (novo design system, WWDC25)

- Componentes padrão (toolbar, sidebar, controles) adotam Liquid Glass **automaticamente** ao recompilar com Xcode 26 — migre para componentes padrão antes de customizar.
- Use `glassEffect(_:in:)` **com parcimônia** — apenas em camadas flutuantes sobre conteúdo (ex.: HUD de telemetria sobre o preview de vídeo).
- Tinting seletivo apenas para ações primárias; `ToolbarSpacer` para agrupar itens.
- Reduced Transparency / Increased Contrast / Reduce Motion são respeitados automaticamente pelos componentes padrão.

**Ações no projeto:** recompilar com Xcode 26; `NavigationSplitView` + toolbar padrão; `glassEffect` nos overlays do preview (HUD, controles flutuantes), **não** no painel de log.

## 2. Human Interface Guidelines — macOS

- Apps macOS devem suportar: múltiplas janelas, menu bar completo, atalhos de teclado, `Settings` scene, empty states informativos.
- **Ações no projeto:** quebrar `ContentView.swift` (~80 KB) em cenas; `MenuBarExtra` para controles rápidos; onboarding BLE guiado (estado de pareamento visível); empty states para "sem gimbal", "sem câmera", "sem permissão".

## 3. Performance SwiftUI

- Use o **SwiftUI Instrument** (Instruments 26) para achar updates causados por dependências amplas.
- ⚠️ Ponto crítico atual: `GimbalController` é um `ObservableObject` único com dezenas de `@Published` + telemetria a ~25 Hz → invalida a árvore de views inteira a cada frame.
- **Ações:** separar `TelemetryModel` / `ConnectionModel` / `SettingsModel` com a macro `@Observable`; throttle de UI a 10–15 Hz (mantendo taxa cheia no PID); ring buffer no log; pipeline de vídeo via Metal/CoreImage fora do ciclo SwiftUI.

## 4. Acessibilidade

- Accessibility Nutrition Labels ("Supports VoiceOver") na App Store.
- Full Keyboard Access; contraste mínimo; testar com VoiceOver (Cmd+F5).
- Labels de acessibilidade nos controles do gimbal (joystick on-screen, presets, modos).

## 5. Checklist customer-ready

- [ ] **Bundle ID `com.example.DjiOsmo3Mac` é bloqueador** — trocar por identificador próprio
- [ ] Assinatura Developer ID + **notarização**
- [ ] `NSCameraUsageDescription` / `NSMicrophoneUsageDescription` no Info.plist
- [ ] Privacy Nutrition Label: tracking é 100% local, nada sai do dispositivo
- [ ] Política de privacidade publicada
- [ ] Zero crashes; tratamento de desconexão BLE em qualquer estado
- [ ] Reviewer não terá um OM3: **modo demo** + vídeo nas Notes for Review
- [ ] Evitar "DJI" no nome do app (marca registrada)
- [ ] Ícone via Icon Composer
- [ ] Testes automatizados (ver `Tests/run_tests.sh`) + CI

## 6. Ordem de ataque (amarrada ao roadmap)

| Fase | Prioridade |
|---|---|
| F0 | Bundle ID próprio; separar models `@Observable`; testes do codec DUML |
| F1 | Recompilar Xcode 26 (Liquid Glass automático); usage descriptions; notarização |
| F2 | `glassEffect` nos overlays; MenuBarExtra; acessibilidade completa; modo demo |

## Fontes

- Adopting Liquid Glass: https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
- HIG: https://developer.apple.com/design/human-interface-guidelines (Designing for macOS)
- SwiftUI performance: https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance
- WWDC25: 219 (Meet Liquid Glass), 356 (new design system), 323 (SwiftUI + new design), 256 (What's new in SwiftUI), 306 (Optimize SwiftUI performance with Instruments), 229 (Make your Mac app more accessible)
- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- VoiceOver evaluation criteria: https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria/
