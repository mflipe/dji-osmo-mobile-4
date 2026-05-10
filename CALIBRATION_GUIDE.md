# Calibração Ensaiada do Gimbal OM3

## O que é

Uma rotina automatizada que testa todos os limites do campo de ação do gimbal, coleta telemetria em tempo real e valida se os valores reportados correspondem aos esperados.

## Como usar

1. **Abra o app** e conecte ao gimbal (status deve estar "Ready")
2. **Clique na aba "Calibration"** na sidebar esquerda
3. **Pressione "Start Routine"**

A rotina irá:
- Executar 8 testes sequenciais (~20 segundos total)
- Enviar comando para cada ponto de teste
- Aguardar 2.5s para o gimbal se estabilizar
- Coletar valores de telemetria dos 3 eixos
- Validar contra valores esperados (tolerância ±2°)

## Pontos de Teste

| # | Nome | Target | Esperado |
|---|------|--------|----------|
| 1 | Center | P=0°, Y=0° | P=0°, Y=0° |
| 2 | Pitch Max | P=+45°, Y=0° | P=+45°, Y=0° |
| 3 | Pitch Min | P=-90°, Y=0° | P=-90°, Y=0° |
| 4 | Yaw Right | P=0°, Y=+160° | P=0°, Y=+160° |
| 5 | Yaw Left | P=0°, Y=-160° | P=0°, Y=-160° |
| 6 | Diagonal+ | P=+45°, Y=+160° | P=+45°, Y=+160° |
| 7 | Diagonal- | P=-90°, Y=-160° | P=-90°, Y=-160° |
| 8 | Return | P=0°, Y=0° | P=0°, Y=0° |

## Saída: Logs de Ação

Cada teste gera um log detalhado. Abra a aba **"BLE Log"** e vá para **"Actions"** para ver resumo:

```
📍 Test: Center → P=0° Y=0°
✓ PASS | P: exp=+0° actual=+0.3° (Δ0.3°) | Y: exp=+0° actual=-0.2° (Δ0.2°) | R: -0.1°

📍 Test: Pitch Max (+45°) → P=+45° Y=0°
✗ FAIL | P: exp=+45° actual=+42.1° (Δ2.9°) | Y: exp=+0° actual=+0.5° (Δ0.5°) | R: -0.3°
```

**Legenda:**
- `✓ PASS` — dentro da tolerância ±2°
- `✗ FAIL` — fora da tolerância (Δ mostra erro)
- `P:` — Pitch (inclinação)
- `Y:` — Yaw (rotação)
- `R:` — Roll (inclinação lateral)

## Saída: Painel de Resultados

Após a execução, a sidebar mostra uma tabela com:
- Nome do teste
- Valor atual coletado
- Valor esperado
- Status (✓/✗)

**Copie os resultados** clicando em "Copy Results" para processar offline.

## O que Procurar

### ✓ Tudo OK
Se todos os testes passarem (✓), o gimbal está calibrado corretamente e pode-se confiar nos valores de telemetria.

### ✗ Falhas Sistemáticas

**Padrão 1: Erro constante no Pitch**
```
Pitch Min (-90°): actual=-87.5° (expected -90°) → Δ-2.5° (FAIL)
Pitch Max (+45°): actual=+42.5° (expected +45°) → Δ-2.5° (FAIL)
```
💡 **Causa provável:** Offset de calibração no eixo pitch. A firmware ou sensor está deslocado.

**Padrão 2: Erro apenas em Yaw grande**
```
Yaw Right (+160°): actual=+150° (expected +160°) → Δ-10° (FAIL)
Yaw Left (-160°): actual=-145° (expected -160°) → Δ-15° (FAIL)
```
💡 **Causa provável:** Limite de motor ou gear. Gimbal não consegue alcançar extremo.

**Padrão 3: Valores sempre maiores**
```
Center (0°): actual=+2.3° (expected 0°) → Δ+2.3° (FAIL)
Pitch Max (+45°): actual=+47.8° (expected +45°) → Δ+2.8° (FAIL)
```
💡 **Causa provável:** Offset de calibração. Sensor reporta valores deslocados.

## Próximos Passos

1. **Copie os resultados** para um arquivo ou note os padrões
2. **Identifique o padrão de erro** (offset, limite, ruído)
3. **Verifique a configuração de firmware** — pode haver mapping incorreto dos eixos
4. **Se erros > 5°**: procure por problemas mecânicos (motor não move, gear travado)
5. **Se erros aleatórios**: pode ser ruído do sensor, tente novamente

## Arquivo de Log Completo

Para debug avançado:
1. Abra "BLE Log"
2. Filtre para **"Commands"** (vê apenas TX/RX)
3. Copie todos os logs durante a calibração
4. Procure padrões de comando/resposta que podem revelar o problema

## Exemplo de Saída Esperada (Gimbal OK)

```
📊 === CALIBRATION ROUTINE START ===

[1/8] Center
📍 Test: Center → P=0° Y=0°
✓ PASS | P: exp=+0° actual=-0.1° (Δ0.1°) | Y: exp=+0° actual=+0.2° (Δ0.2°) | R: +0.3°

[2/8] Pitch Max
📍 Test: Pitch Max (+45°) → P=+45° Y=0°
✓ PASS | P: exp=+45° actual=+44.9° (Δ0.1°) | Y: exp=+0° actual=+0.1° (Δ0.1°) | R: -0.2°

[3/8] Pitch Min
📍 Test: Pitch Min (-90°) → P=-90° Y=0°
✓ PASS | P: exp=-90° actual=-89.8° (Δ0.2°) | Y: exp=+0° actual=-0.3° (Δ0.3°) | R: +0.1°

[4/8] Yaw Right
📍 Test: Yaw Right (+160°) → P=0° Y=+160°
✓ PASS | P: exp=+0° actual=+0.2° (Δ0.2°) | Y: exp=+160° actual=+159.7° (Δ0.3°) | R: -0.1°

[5/8] Yaw Left
📍 Test: Yaw Left (-160°) → P=0° Y=-160°
✓ PASS | P: exp=+0° actual=-0.1° (Δ0.1°) | Y: exp=-160° actual=-159.9° (Δ0.1°) | R: +0.2°

[6/8] Diagonal +
📍 Test: Diagonal (+45°, +160°) → P=+45° Y=+160°
✓ PASS | P: exp=+45° actual=+45.1° (Δ0.1°) | Y: exp=+160° actual=+160.0° (Δ0.0°) | R: -0.3°

[7/8] Diagonal -
📍 Test: Diagonal (-90°, -160°) → P=-90° Y=-160°
✓ PASS | P: exp=-90° actual=-90.2° (Δ0.2°) | Y: exp=-160° actual=-159.8° (Δ0.2°) | R: +0.1°

[8/8] Return
📍 Test: Return Center → P=0° Y=0°
✓ PASS | P: exp=+0° actual=+0.0° (Δ0.0°) | Y: exp=+0° actual=+0.1° (Δ0.1°) | R: -0.2°

📊 === CALIBRATION ROUTINE COMPLETE ===
Result: 8/8 PASS ✓
```

---

## Troubleshooting

**Q: Calibração não inicia**
- Gimbal deve estar em estado "Ready" (conectado + pareado)
- Veja a aba "Devices" e confirme que está "Ready"

**Q: Valores de telemetria congelados**
- Gimbal pode não estar enviando telemetria
- Verifique log RX: procure por `getPos (0x02)` a cada segundo
- Se não houver: problema de comunicação BLE

**Q: Erros erráticos (variam a cada teste)**
- Sensor pode estar ruidoso
- Tente executar a calibração 2-3 vezes para confirmar padrão
- Se erros < 1° são normais para sensores de qualidade média

**Q: Gimbal para no meio da calibração**
- Motor pode estar travado ou sem torque suficiente
- Tente ligar/desligar o gimbal e repetir
- Procure por mensagens de erro no log

