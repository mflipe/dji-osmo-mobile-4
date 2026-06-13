# Plano de Produto — Suporte Inteligente de Câmera para macOS

> Versão em repositório do plano mantido no Notion. Complementa o `PLAN.md` (foco em paridade com o Mimo): este documento define a visão de produto além do celular — transformar o OM3/OM4 em um suporte inteligente de câmera para macOS.

## 1. Visão do produto

O gimbal DJI Osmo Mobile não deve ficar limitado ao celular: com este app ele vira um **suporte inteligente de celular/câmera para macOS** — webcam com enquadramento automático, tracking de rosto/corpo, presets de posição e controle total via Mac.

### Oportunidade de mercado

| Produto | Preço | Observação |
|---|---|---|
| Belkin Auto-Tracking Stand Pro (DockKit) | ~US$ 180 | Só iPhone, sem macOS |
| Insta360 Link 2 | ~US$ 200 | Webcam gimbal dedicada |
| DJI OM8 (com DockKit) | ~US$ 110 | Tracking só no iPhone |
| **Este projeto (OM3/OM4 + Mac)** | **~R$ 0** | Hardware já existente |

## 2. Revisão do código (estado atual)

**Pontos fortes:** DUML wire format completo (CRC8/16 verificados), pareamento BLE funcional, telemetria P/R/Y, PID de tracking (Vision), arquitetura em camadas limpa na base (DUMLProtocol → BLEManager → GimbalController).

**Gaps priorizados:**

| Severidade | Gap |
|---|---|
| 🔴 | Pitch não responde (ver hipótese de offset abaixo) |
| 🔴 | Sem câmera virtual do sistema (CMIO Camera Extension) |
| 🟡 | Botões físicos: cmd IDs placeholders (não transmitidos via BLE no OM3, exceto joystick 0x57) |
| 🟡 | Zoom só no preview local |
| 🟡 | Heartbeat (0x50) / feature control (0x54) não confirmados no fluxo |
| 🟡 | Acoplamento forte ao OM3 (sem abstração p/ OM4) |
| 🟢 | Sem testes; bundle ID `com.example` |

**Achado-chave (cruzamento com a pesquisa DUML):** no OM3 de referência, comandar pitch 0° produz leitura de telemetria ≈ **-179,9°** e yaw 0° lê ≈ **-91°** — offset constante por eixo entre o frame de comando e o de telemetria. É exatamente o sintoma do bug de pitch deste repo. Hipóteses: (a) normalizar telemetria com offset por eixo; (b) usar modo relativo `0x04`. Ver `docs/F0_PITCH_EXPERIMENT.md` (PR do experimento F0).

## 3. Pilares do produto

1. **Câmera do sistema** — CMIO Camera Extension ("Osmo Smart Camera") visível em Zoom/Meet/FaceTime.
2. **Tracking confiável em 2 eixos** — pitch + yaw com PID estável.
3. **Suporte de mesa inteligente** — presets, modos de reunião/apresentação, gestos.
4. **Hardware plural** — OM3 e OM4 (e além) via abstração `GimbalProfile`.

## 4. Roadmap

### F0 — Destravar o pitch (1–2 semanas)
- Capturar offset por eixo (recenter → ler telemetria → `AxisOffsetModel`).
- Testar modo relativo `0x04` como alternativa ao absoluto `0x05`.
- Enviar heartbeat `0x50` (payload `01 04 05`) + feature control `0x54`.
- Normalizar telemetria; registrar resultados no plano de validação.

### F1 — Câmera do sistema
- CMIO Camera Extension + crop digital.
- Descobrir cmd IDs de eventos (candidatos: `0x57`, `0x1C`, `0x19`).
- Bundle ID próprio + assinatura/notarização.

### F2 — Suporte inteligente
- Framing modes (rosto, busto, mesa), presets + MenuBarExtra.
- Modo apresentação/reunião; gestos via `VNDetectHumanHandPoseRequest`.
- Timelapse por waypoints (`0x25`, máx. 5 keyframes); auto-sleep.

### F3 — Maturidade
- Abstração `GimbalProfile` + suporte OM4; modo sem gimbal.
- AppleScript/Atalhos; testes DUML + CI; distribuição.

## 5. Riscos

- Protocolo DUML não documentado oficialmente (mitigação: om-research, lib-osmo-ble, logs próprios).
- CMIO Extension exige assinatura/perfil corretos.
- Firmware pode variar entre unidades OM3.
- Marca "DJI" no nome do app é risco legal — usar nome próprio.

## 6. Critérios de sucesso

- Pitch e yaw respondem a comandos absolutos e relativos com telemetria coerente.
- App aparece como câmera em apps de vídeo sem hack.
- Tracking mantém o sujeito enquadrado em movimento normal de reunião.
- Build assinado, notarizado e instalável por terceiros.

## Referências

- CMIO Camera Extension — developer.apple.com/documentation/coremediaio
- DockKit (WWDC23 10304, WWDC24 10164) — developer.apple.com/documentation/DockKit
- OM Research — github.com/alkersan/om-research (heartbeat 0x50 `01 04 05`, feature control 0x54, timelapse 0x25, joystick 0x57)
- lib-osmo-ble — github.com/yigitkonur/lib-osmo-ble
- reverse-engineering-dji — github.com/xaionaro/reverse-engineering-dji
