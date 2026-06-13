# F0 — Experimento do Pitch (offset de telemetria)

## Hipótese

O pitch **não está morto**. O frame de coordenadas dos comandos absolutos (`0x14`, modo `0x05`) e o frame da telemetria (`0x02`/`0x05`) divergem por um **offset constante por eixo**:

| Eixo | Comando 0° | Telemetria lida (OM3 de referência) |
|---|---|---|
| Pitch | 0° | ≈ **-179,9°** |
| Yaw | 0° | ≈ **-91°** |

Isso explica os logs deste repo com pitch oscilando em ±179,9° "sem responder": o controle compara o alvo com uma leitura em outro frame e satura.

## Estratégias implementadas nesta PR

- **A — Absoluto + normalização:** continuar usando `setAngle` (modo `0x05`) e corrigir a telemetria com `AxisOffsetModel` (`DjiOsmo3Mac/TelemetryNormalization.swift`).
- **B — Relativo:** `GimbalPayloadBuilder.setAngleRelative` (modo `0x04`), que ignora o frame absoluto.
- **Heartbeat:** `GimbalPayloadBuilder.heartbeat()` (`0x50`, payload `01 04 05`, a cada ~2s) para descartar gating de sessão. O feature control (`0x54`) ficou de fora por payload ainda não confirmado — confirmar no fork OM Research antes de implementar.

## Antes do teste manual: rodar os testes unitários

```bash
bash Tests/run_tests.sh
```

Cobrem: CRC8/16 contra implementação independente, encode/decode de frame (seq big-endian, CRCs), resync do stream parser, layouts dos payloads (yaw-first, inversão de pitch, clamps, modos 0x04/0x05/0x80) e a matemática de offset/wraparound.

## Protocolo de teste manual (com o OM3)

Os passos estão codificados em `PitchExperimentPlan.steps()` — envie cada payload pelo caminho BLE existente (cmdSet `0x04`, flag request), aguarde `settleSeconds` e anote a telemetria **crua** P/R/Y:

| # | Passo | O que anotar |
|---|---|---|
| 1 | Heartbeat `0x50` | Erro? (repetir a cada ~2s durante todo o teste) |
| 2 | Recenter absoluto 0/0/0 | P/Y de referência (esperado ≈ -179,9 / -91) |
| 3 | Absoluto pitch +30° | Moveu fisicamente? Telemetria corrigida ≈ +30? |
| 4 | Absoluto pitch -30° | Moveu para o outro lado? ≈ -30? |
| 5 | Relativo pitch +20° (`0x04`) | Moveu? (se 3-4 falharam e este funcionou → Estratégia B) |
| 6 | Relativo pitch -20° (`0x04`) | Voltou ~20°? |
| 7 | Recenter final | Telemetria voltou à referência do passo 2? |

### Interpretação

| Resultado | Conclusão | Próximo passo |
|---|---|---|
| 3-4 movem e offset bate | Hipótese confirmada (Estratégia A) | Aplicar `AxisOffsetModel` no loop de controle/tracking |
| Só 5-6 movem | Frame absoluto inutilizável p/ pitch (Estratégia B) | Migrar tracking p/ deltas relativos |
| Nada move, sem heartbeat → nada; com heartbeat → move | Gating de sessão | Integrar heartbeat permanente no GimbalController |
| Nada move em nenhum caso | Hipótese refutada | Capturar log RX completo e investigar 0x54/firmware |

> Registrar os resultados também no plano de validação (Notion).

## Integração (fora desta PR, de propósito)

Esta PR **não** altera `GimbalController.swift`/`ContentView.swift` — só adiciona arquivos novos, para ser segura sem build. Após o experimento confirmar a estratégia vencedora, a integração no loop de controle vem em PR separada.

**Nota Xcode:** se o projeto não usar folder references sincronizadas, adicione os novos arquivos `DjiOsmo3Mac/*.swift` ao target manualmente (drag & drop no Xcode).
