# F0 — Experimento do pitch (offset de telemetria)

## Hipótese

O pitch **não está morto**. O frame de coordenadas dos comandos absolutos (`0x14`, modo `0x05`) e o frame da telemetria (`getPos 0x02` / `positionPush 0x05`) divergem por um **offset constante por eixo**, com wraparound em ±180°:

| Eixo | Comando 0° | Telemetria lida (OM3 de referência) |
|---|---|---|
| Pitch | 0° | ≈ **-179,9°** |
| Yaw   | 0° | ≈ **-91°** |

Esso explica os logs deste repo com pitch oscilando em ±179,9° "sem responder": o controlador compara o alvo com uma leitura em outro frame e satura.

## Arquivos desta PR

| Arquivo | O que faz |
|---|---|
| `DjiOsmo3Mac/TelemetryNormalization.swift` | `TelemetryNormalization` (normalize/wraparound) + `AxisOffsetModel` (captura e aplica offset por eixo) |
| `DjiOsmo3Mac/PitchExperiment.swift` | `GimbalPayloadBuilder.setAngleRelative` (modo 0x04) + `heartbeat()` (0x50) + `PitchExperimentPlan.steps()` |
| `Tests/main.swift` | 50+ testes unitários: CRC, encode/decode, payload layouts, normalização, wraparound, stream parser |
| `Tests/run_tests.sh` | `bash Tests/run_tests.sh` — sem Xcode test target |

## Estratégias implementadas

- **A — Absoluto + normalização:** manter `setAngle` (modo `0x05`) e corrigir a telemetria com `AxisOffsetModel` antes de alimentar o PID.
- **B — Relativo:** `setAngleRelative` (modo `0x04`) — bypassa o frame absoluto, move por delta a partir da posição física atual.
- **Heartbeat:** `heartbeat()` (`0x50`, payload `01 04 05`, a cada ~2s) para descartar session gating. `0x54` ficou fora — payload precisa ser confirmado no fork om-research antes.

> Esta PR **não altera** `GimbalController.swift` nem `ContentView.swift` — só adiciona arquivos novos. Seguro fazer merge sem build.

## Antes do teste: rodar os testes unitários

```bash
bash Tests/run_tests.sh
```

Devem todos passar offline (sem gimbal). Cobrem: CRC contra implementação independente, roundtrip de frame, layouts de payload (yaw-first, inversão de pitch, modos 0x04/0x05/0x80, clamps), normalização angular e wraparound em ±180°.

## Protocolo de teste manual (com o OM3)

Os passos estão codificados em `PitchExperimentPlan.steps()`. Envie cada payload pelo caminho BLE existente (`cmdSet = 0x04`, flag `0x40`), aguarde `settleSeconds` e anote a telemetria crua P/R/Y:

| # | Passo | Observe |
|---|---|---|
| 1 | Heartbeat `0x50` | Erro de resposta? (repetir a cada ~2s) |
| 2 | Recenter absoluto 0/0/0 | Anotar P/Y de referência (hipótese: ≈ -179,9 / -91) |
| 3 | Absoluto pitch +30° | Moveu fisicamente? Telemetria corrigida ≈ +30? |
| 4 | Absoluto pitch -30° | Outro lado? ≈ -30? |
| 5 | Relativo pitch +20° (0x04) | Moveu ~20° do atual? (se 3-4 falharam e este funciona → Estratégia B) |
| 6 | Relativo pitch -20° (0x04) | Voltou ~20°? |
| 7 | Recenter final | Telemetria voltou à referência do passo 2? |

### Interpretação

| Resultado | Conclusão | Próximo passo |
|---|---|---|
| 3–4 movem e offset bate | Estratégia A confirmada | Integrar `AxisOffsetModel` no loop PID do `GimbalController` |
| Só 5–6 movem | Frame absoluto inútil p/ pitch | Migrar tracking para deltas relativos |
| Nada s/ heartbeat; com → move | Session gating | Integrar heartbeat permanente no `GimbalController` |
| Nada em nenhum caso | Hipótese refutada | Log RX completo; investigar `0x54`/firmware |

> Registrar resultados também no plano de validação (Notion).

## Integração no GimbalController (fora desta PR, de propósito)

Depois do experimento confirmar a estratégia vencedora:
1. Adicionar `AxisOffsetModel` para pitch e yaw em `GimbalController`.
2. Capturar offset ao final de `recenter()` (aguardar settle ~2s, ler telemetria).
3. Aplicar `commandFrameAngle` antes de comparar com o target no loop PID.
4. Ou migrar `setAngle`/PID para deltas relativos (Estratégia B).

**Nota Xcode:** se o projeto não usar folder references sincronizadas, adicionar os novos `.swift` ao target manualmente (drag & drop → ✓ target membership).
