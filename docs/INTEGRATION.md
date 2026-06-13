# Consolidação + aplicação do plano — guia de integração

A branch `feature/complete-plan` consolida as PRs **#2** (experimento F0 de pitch) e **#3** (docs) e adiciona a aplicação do Plano de Produto + Guia Apple em código.

> ⚠️ Conforme combinado: esta PR prioriza cobertura do plano (F0→F3). Alguns itens são **scaffolds/aditivos** que exigem passos manuais no Xcode e provavelmente quebram o build até serem ligados. Foi uma decisão consciente para você clonar, ligar e testar no hardware.

## O que está incluído

### Docs
- `docs/PRODUCT_PLAN.md`, `docs/APPLE_BEST_PRACTICES.md` (vindas da #3).
- `docs/F0_PITCH_EXPERIMENT.md` (da #2).

### F0 — experimento (da #2)
- `TelemetryNormalization.swift`, `PitchExperiment.swift`, `GimbalPayloadBuilderRelative.swift` + testes em `Tests/`.

### F0 — integração (novo, desacoplado)
- `TelemetryOffsetModel.swift`: `@MainActor ObservableObject` que **assina `GimbalController.frameEvents`**, decodifica `getPos` (0x02) / `positionPush` (0x05) e publica `rawPitch/rawYaw` + `correctedPitch/correctedYaw`. Captura de offset por eixo via `captureOffsetAtCenter()` (chamar ~1 s após `recenter()`).
- Usa **apenas** os helpers puros de `TelemetryNormalization` — de propósito, para **não** depender de nenhum dos dois tipos `AxisOffsetModel` (veja "Conflitos conhecidos").

### F2 — HIG / janelas
- `QuickControlMenu.swift` + cena `MenuBarExtra` no app (status, recenter, tracking, stop).
- `AppSettingsView.swift` + cena `Settings` (offset F0, throttle de UI, modo demo).

### Apple / Liquid Glass
- `LiquidGlass.swift`: `.osmoGlass(cornerRadius:)` e `.osmoGlassCapsule()` — usam `glassEffect` em macOS 26+ e caem para `.ultraThinMaterial` antes disso.

### F3 — modo demo
- `DemoMode.swift` (`DemoModeController`): gera telemetria pitch/yaw simulada a ~15 Hz para demonstrar a UI sem gimbal (útil p/ review na App Store).

### F1 — câmera do sistema (scaffold)
- `CameraExtension/CameraExtensionProvider.swift`: esqueleto CMIO. **NÃO** adicionar ao target do app.

## Passos manuais (obrigatórios)

1. **Adicionar arquivos novos ao target `DjiOsmo3Mac`** no Xcode (TelemetryOffsetModel, LiquidGlass, DemoMode, QuickControlMenu, AppSettingsView), caso o projeto não use grupos sincronizados por pasta.
2. **Fechar o loop de controle (decisão sua, ~1 linha):** `TelemetryOffsetModel` publica `correctedPitch/correctedYaw`, mas o `GimbalController` ainda dirige com a telemetria crua. Para aplicar a correção no PID/minimap, consuma `telemetryOffset.correctedPitch/Yaw` onde hoje se lê `controller.pitch/yaw`, **ou** mova a lógica de offset para dentro de `GimbalController.handleFrame`. Mantido desacoplado para não reescrever o arquivo de ~48 KB às cegas.
3. **Ligar o modo demo:** observar `@AppStorage("demoMode")` e alimentar a UI com `DemoModeController` quando não houver gimbal.
4. **Liquid Glass na UI:** aplicar `.osmoGlass()` nos overlays do `ContentView` (HUD de telemetria, joystick).

## Conflitos conhecidos

- **Dois tipos `AxisOffsetModel`:** existe uma `class` em `AxisOffsetModel.swift` e uma `struct` em `TelemetryNormalization.swift`. Se ambos forem adicionados ao **mesmo** target, haverá erro de redeclaração. Escolha um (a `struct` é a usada pelos testes) ou renomeie o outro. O `TelemetryOffsetModel` novo não depende de nenhum dos dois.

## Remanescente do roadmap (precisa de build/hardware)

- **F1 — CMIO Camera Extension:** requer um novo target de System Extension (não dá para criar só com arquivos). Ver scaffold.
- **F1 — Bundle ID:** trocar `com.example.*` em `project.pbxproj` (Build Settings) — editar no Xcode.
- **Perf `@Observable`:** migrar `GimbalController` para `@Observable` e separar `TelemetryModel`/`ConnectionModel` — refator grande, com build incremental.
