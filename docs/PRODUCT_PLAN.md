# Plano de Produto — Suporte Inteligente de Câmera para macOS

> Complementa o `PLAN.md` (redesign + webcam + paridade com o Mimo) com a visão de produto de longo prazo: transformar o OM3/OM4 em um **suporte inteligente de câmera para macOS**, não apenas um controle remoto de gimbal.

## 1. Visão do produto

O gimbal deixa de ser um acessório de celular e vira um periférico de Mac: uma câmera de sistema com enquadramento automático, presets de posição e modos de apresentação/reunião — competindo com produtos como Belkin Auto-Tracking Stand Pro (~US$180), Insta360 Link 2 (~US$200) e DJI OM8 com DockKit (~US$110), a custo zero de hardware adicional para quem já tem um OM3/OM4.

| Produto | Preço | Diferencial |
|---|---|---|
| Belkin Stand Pro (DockKit) | ~US$180 | Tracking nativo iOS, sem suporte macOS |
| Insta360 Link 2 | ~US$200 | Webcam 4K com gimbal, AI tracking |
| DJI OM8 (DockKit) | ~US$110 | Gimbal de celular com tracking nativo |
| **Este projeto** | **R$0** | OM3/OM4 + Mac que o usuário já possui |

## 2. Revisão do código — gaps conhecidos

| Severidade | Gap |
|---|---|
| 🔴 | Pitch não responde (offset de coordenadas na telemetria — ver §3) |
| 🔴 | Sem CMIO Camera Extension — o preview não aparece como câmera do sistema |
| 🟡 | Botões físicos: firmware OM3 não transmite via BLE (exceto joystick 0x57); cmd IDs por descobrir |
| 🟡 | Zoom só no preview local |
| 🟡 | Heartbeat (0x50) e feature control (0x54) não confirmados no fluxo atual |
| 🟡 | Acoplamento forte ao OM3 (sem abstração p/ OM4) |
| 🟢 | Sem testes; bundle ID `com.example.*` |

## 3. Achado principal — offset de pitch

O mapa técnico do projeto documenta que, com pitch comandado em 0°, a telemetria lê **≈ -179,9°** (e yaw 0° lê ≈ -91°) — exatamente o sintoma do bug de pitch do app. Hipótese: **offset constante por eixo entre o frame de comando e o frame de telemetria** (com wraparound em ±180°), e não um eixo morto.

Estratégias de validação (F0):
1. **Offset**: capturar offset por eixo após recenter e normalizar telemetria (`AxisOffsetModel`).
2. **Modo relativo**: comandar deltas com `RotationMode.relative (0x04)`, ignorando o frame absoluto.
3. **Sessão**: heartbeat `0x50` (payload `01 04 05`) + feature control `0x54` antes do controle avançado.

## 4. Pilares do produto

1. **Câmera do sistema** — CMIO Camera Extension ("Osmo Smart Camera") visível em Zoom/Meet/FaceTime.
2. **Tracking confiável em 2 eixos** — Vision + PID já existente, com pitch destravado.
3. **Suporte de mesa inteligente** — presets, recenter, auto-sleep, modos de reunião/apresentação.
4. **Hardware plural** — abstração `GimbalProfile` para OM3/OM4 (e futuros).

## 5. Roadmap

### F0 — Destravar o pitch (1–2 semanas)
- Experimento de offset + modo relativo `0x04` (ver `docs/F0_PITCH_EXPERIMENT.md`)
- Heartbeat `0x50` + feature control `0x54`
- Normalizar telemetria com offset por eixo

### F1 — Câmera do sistema
- CMIO Camera Extension + crop digital
- Descoberta de cmd IDs de botões (candidatos: `0x57`, `0x1C`, `0x19`)
- Bundle ID próprio + assinatura/notarização

### F2 — Inteligência
- Framing modes (rosto, corpo, mesa), presets + MenuBarExtra
- Modo apresentação/reunião, gestos (VNDetectHumanHandPoseRequest)
- Timelapse por waypoints (`0x25`, máx. 5 keyframes), auto-sleep

### F3 — Maturidade
- `GimbalProfile` (OM3/OM4), modo sem gimbal
- AppleScript/Shortcuts, testes DUML + CI, distribuição

## 6. Riscos

- Protocolo DUML não documentado oficialmente; firmware pode variar entre revisões
- CMIO Extension exige assinatura e instalação aprovada pelo usuário
- Botões físicos podem ser inacessíveis via BLE no OM3 (firmware interno)
- Marca "DJI" não pode ser usada no nome do app

## 7. Critérios de sucesso

- Pitch responde a comandos com telemetria coerente (erro < 2°)
- App aparece como câmera em apps de vídeo sem configuração extra
- Tracking mantém o rosto centrado em movimento normal de reunião
- Zero crashes em sessões de 1h+

## Referências externas

- CMIO Camera Extensions: https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o
- DockKit (referência de UX de tracking): https://developer.apple.com/documentation/DockKit
- OM Research (protocolo BLE/DUML do OM4): https://github.com/alkersan/om-research
- lib-osmo-ble: https://github.com/yigitkonur/lib-osmo-ble
- reverse-engineering-dji: https://github.com/xaionaro/reverse-engineering-dji
