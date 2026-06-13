# Experimento F0 — Correção do Offset de Pitch

## Problema

A telemetria do OM3 lê **pitch ≈ −179,9°** e **yaw ≈ −91°** quando o gimbal está na posição central (pós-recenter). Isso faz o PID de tracking e o minimap ficarem fora de sync, e faz `moveToAngle()` enviar comandos absurdos (`−180° + delta`).

## Hipótese

Existe um **offset constante por eixo** entre o frame de coordenadas dos comandos absolutos e o frame de telemetria positionPush/getPos. O offset persiste enquanto a sessão BLE estiver ativa e é reproduzível a cada conexão.

## Três estratégias implementadas

### 1. `absoluteWithOffset` (default)

- Após `recenter()` assentar (≥ 1 s), captura telemetria como offset: `pitchOffset ≈ −180°`, `yawOffset ≈ −91°`.
- Toda leitura de telemetria é normalizada: `normalizedPitch = wrap180(raw − pitchOffset)`.
- **Vantagem:** nenhuma mudança nos comandos de saída; compatível com o PID existente.
- **Risco:** se o offset variar entre sessões, a calibração precisa ser repetida.

### 2. `relativeCommands` (0x04)

- Usa `RotationMode.relative` em vez de `.absolute` via `GimbalPayloadBuilderRelative.setAngleRelative()`.
- O gimbal aceita deltas da posição atual — o offset de coordenadas torna-se irrelevante.
- **Vantagem:** robusto mesmo que o offset varie; ideal para PID de tracking.
- **Risco:** modo relativo pode não ser suportado no OM3 (confirmar via log `← cmdId=14`).

### 3. `raw`

Sem normalização — para comparação / debug.

## Como testar manualmente

1. Abrir o app com o OM3 pareado.
2. Selecionar a estratégia em **Settings → Gimbal → Offset Strategy**.
3. Clicar **Recenter** e aguardar 2 s.
4. Para `absoluteWithOffset`: clicar **Calibrar Offset** (ou esperar a captura automática).
5. No minimap, clicar em P=0° Y=0° e verificar se o gimbal vai para a posição central.
6. Ativar tracking facial e verificar se pitch acompanha o rosto.

## Checklist de validação

- [ ] Pitch responde a `moveToAngle(pitchDeg: 45, yawDeg: 0)` com erro < 2°
- [ ] Yaw responde a `moveToAngle(pitchDeg: 0, yawDeg: 90)` com erro < 2°
- [ ] Telemetria normalizada lê ≈ 0°/0°/0° após recenter (estratégia absoluteWithOffset)
- [ ] Tracking facial mantém rosto centrado em movimento vertical
- [ ] Modo relativo: resposta ao primeiro comando delta a partir do zero
- [ ] Offset é consistente entre duas desconexões/reconexões

## Arquivos adicionados nesta PR

| Arquivo | Descrição |
|---|---|
| `DjiOsmo3Mac/AxisOffsetModel.swift` | Captura de offset + normalização |
| `DjiOsmo3Mac/GimbalPayloadBuilderRelative.swift` | Builder p/ modo relativo 0x04 |
| `Tests/DUMLCodecTests.swift` | Testes do codec DUML (encode/decode/CRC) |
| `Tests/AxisOffsetModelTests.swift` | Testes do modelo de offset |
| `Tests/run_tests.sh` | Script de execução dos testes |
