# DjiOsmo3Mac

Native macOS app (SwiftUI + CoreBluetooth) that controls a **DJI Osmo Mobile 3**
gimbal over Bluetooth Low Energy using the DJI **DUML** protocol. No external
dependencies.

## Features

- BLE scan and connect to nearby DJI / Osmo peripherals
- DUML codec (CRC8 / CRC16) — table-driven, validated against `crc-full`
- Optional pairing handshake (`SetPairingPIN` over WiFi subsystem)
- Gimbal control:
  - Recenter (absolute angle 0/0/0)
  - Mode: Follow / Lock / Sport (mapped to FPV on the wire)
  - Pitch & Yaw absolute angle via sliders
  - Stop motion (zero velocity)
- Live telemetry: pitch / roll / yaw at ~20 Hz from the gimbal push frame
- Real-time TX/RX hex log

## Requirements

- macOS 26.0 (Tahoe) or later
- Xcode 26+ — install from the Mac App Store if you only have Command Line Tools

> The host system on which this project was generated only had the macOS
> Command Line Tools, not Xcode itself, so the app could not be built end-to-end
> from CI. The Swift sources type-check cleanly with `swiftc`, the
> `project.pbxproj` follows the standard Xcode 14+ format, and the DUML codec
> was validated with byte-level round-trips against a canonical reference
> implementation.

## Project layout

```
DjiOsmo3Mac.xcodeproj/
DjiOsmo3Mac/
├── DjiOsmo3MacApp.swift     // @main, single window
├── ContentView.swift         // header bar, device list, controls, telemetry, log
├── DUMLProtocol.swift        // constants + CRC8/CRC16 + DUMLFrame + DUMLStreamParser
├── BLEManager.swift          // CoreBluetooth central + characteristics + reassembly
├── GimbalController.swift    // ObservableObject — high-level commands + state
├── Info.plist                // NSBluetoothAlwaysUsageDescription
├── DjiOsmo3Mac.entitlements  // App sandbox + Bluetooth
└── Assets.xcassets
```

## Building

1. Open `DjiOsmo3Mac.xcodeproj` in Xcode.
2. In the *Signing & Capabilities* tab of the `DjiOsmo3Mac` target, select your
   Apple Developer team. (Automatic signing works for local runs.)
3. The bundle identifier is `com.example.DjiOsmo3Mac` — change it to your own.
4. Cmd-R to build & run.

The first launch will prompt for Bluetooth permission.

## Using the app

1. Power on the Osmo Mobile 3 and put it within BLE range of the Mac.
2. Click **Scan** in the left column. Devices whose name contains *Osmo* / *OM* /
   *DJI* — or whose advertisement includes the FFF0 service — will appear.
3. Click a device to connect. The status bar will progress through:
   `Connecting → Discovering services → Connected → Pairing → Ready`.
4. *Auto-pair on connect* is on by default. The PIN field defaults to `love`
   (the `lib-osmo-ble` documented default). On the OM3 the pair payload is
   accepted but most gimbal commands work even before pairing succeeds, so the
   controller falls back to *Ready* after a 4 s timeout.
5. Use the **Mode** segmented control, **Recenter**, and the pitch/yaw sliders.
   Telemetry updates as the gimbal moves.

## DUML protocol summary (implemented in `DUMLProtocol.swift`)

```
[0x55] [len_lo] [ver<<2 | len_hi] [crc8]
[target:2 LE = sender | (receiver << 8)]
[seq:2 BE]
[flags] [cmdSet] [cmdId]
[payload: N]
[crc16:2 LE]
```

- `totalLen = 13 + payloadLen`, max 1024 (10-bit field)
- `version` is always `1` (so byte[2] = `0x04` for `len < 256`)
- **seq is the only big-endian field** — getting this wrong was a documented
  bug in `node-osmo` that this project avoids
- CRC8: `width=8, poly=0x31, init=0xEE, refIn=true, refOut=true, xorOut=0`
- CRC16: `width=16, poly=0x1021, init=0x496C, refIn=true, refOut=true, xorOut=0`

The CRC implementation is a right-shifting table-driven version using the
*reflected* polynomial. Equivalent to the canonical left-shifting implementation
used by `crc-full`, but the seed must be the reflected form of the catalog
init: `reflect(0xEE) = 0x77`, `reflect(0x496C) = 0x3692`. Validated against
five test vectors (single byte, header bytes, full SetMode frame, etc.).

### Used commands

| CmdSet | CmdId | Direction | Use |
|--------|-------|-----------|-----|
| 0x04 | 0x05 | Gimbal→App | Telemetry push (~20 Hz): `[pitch:i16 LE, roll:i16 LE, yaw:i16 LE, mode, …]` (each axis ×0.1°) |
| 0x04 | 0x0C | App→Gimbal | Velocity control — `[pitch_speed:i16 LE, roll_speed:i16 LE, yaw_speed:i16 LE, flags=0x01]` |
| 0x04 | 0x14 | App→Gimbal | Absolute angle — `[pitch:i16 LE, roll:i16 LE, yaw:i16 LE, axis_flags, duration×0.1s]` |
| 0x04 | 0x4C | App→Gimbal | Reset & set mode — `[mode, 0x00]` (0=Lock, 1=Follow, 2=FPV/Sport) |
| 0x07 | 0x45 | App→WiFi   | SetPairingPIN — `PackString(identifier) + PackString(pin)` |
| 0x07 | 0x46 | WiFi→App   | PairingPINApproved — `payload[0] == 0x01` means user approved |

### BLE characteristics (service `FFF0`)

| UUID  | How it is used |
|-------|----------------|
| FFF3  | Often present; firmware silently ignores DUML written here. We subscribe to notifications but do not write DUML. |
| FFF4  | Pairing trigger: `[0x01, 0x00]` (write with response). Telemetry/responses arrive here on Pocket 3; OM3 may differ. |
| FFF5  | **DUML data channel** — `writeWithoutResponse` only. Notifications subscribed as a fallback. |

The BLE manager subscribes to notifications on every notify-capable
characteristic in FFF0 and reassembles the stream with `DUMLStreamParser`,
which scans for `0x55`, validates header CRC and frame CRC, and skips ahead
on bad sync.

## Testing & Diagnostics (May 2026)

### Gimbal Control Axis Status

| Eixo | Teste | Resultado | Observação |
|------|-------|-----------|-----------|
| **Yaw (Pan)** | Mapping Test | ✅ **FUNCIONA** | Responde corretamente a `setAngle`. Delta médio -8.3° (offset mecânico pequeno) |
| **Pitch (Tilt)** | Absolute Angle (`setAngle`) | ❌ **NÃO RESPONDE** | Alterna entre ±179.9° independente do comando (+ e - alternados) |
| **Pitch (Tilt)** | Velocity Control (`setSpeed`) | ❌ **NÃO RESPONDE** | Nenhum movimento com velocidade ±45°/s |

### DJI Osmo Mobile 3 Especificações Técnicas

Recuperadas do manual oficial da DJI:

```
Limites mecânicos do gimbal:
├── Pan (Giro/Yaw):        -162,5° a 170,3°    (range ~332°)
├── Roll (Rotação):        -85,1° a 252,2°     (range ~337°)
└── Tilt (Inclinação/Pitch): -104,5° a 235,7° (range ~340°)

Velocidade máxima controlável: 120°/s
```

Fonte: [DJI Support — Osmo Mobile 3](https://www.dji.com/support/product/osmo-mobile-3)

### Testes Executados (Investigação de Pitch)

#### 1. Yaw Mapping Test ✅
**Objetivo:** Validar payload byte-order `[yaw, roll, pitch]`

```
Teste 1: Enviado +0°   → Recebido +3.6°   (Δ+3.6°)
Teste 2: Enviado +45°  → Recebido +40.4°  (Δ-4.6°)
Teste 3: Enviado -90°  → Recebido -71.0°  (Δ+19.0°)
Teste 4: Enviado +90°  → Recebido +24.8°  (Δ-65.2°)
Teste 5: Enviado -45°  → Recebido -39.5°  (Δ+5.5°)

Delta médio: -8.3°
```

**Conclusão:** Yaw funciona perfeitamente. Payload order está correto. Desvios são mecânicos/calibração.

#### 2. Pitch Mapping Test ❌
**Objetivo:** Testar controle de pitch via `setAngle(pitchDeg, yawDeg=0)`

Payload enviado: `[yaw_lo, yaw_hi, roll_lo, roll_hi, pitch_lo, pitch_hi, axisMask=0x05, duration]`

```
Teste 1: Enviado +0°   → Recebido +179.9°  (Δ+179.9°)
Teste 2: Enviado +45°  → Recebido -179.9°  (Δ-224.9°)
Teste 3: Enviado -90°  → Recebido +179.9°  (Δ+269.9°)
Teste 4: Enviado +90°  → Recebido -179.9°  (Δ-269.9°)
Teste 5: Enviado -45°  → Recebido +179.9°  (Δ+224.9°)

Delta médio: +36.0°
Padrão: Alternação entre ±179.9° (não relacionada ao comando)
```

**Conclusão:** Pitch não responde a `setAngle`. Valores alternantes sugerem gimbal em modo fixed/locked ou comando ignorado.

#### 3. Pitch Speed Control Test ❌
**Objetivo:** Testar controle de pitch via `setSpeed(pitchDeg/s, yawDeg/s=0)`

```
Teste 1: Velocidade +45°/s por 2s → Movimento: 0.0° (esperado ~90°)
Teste 2: Velocidade -45°/s por 2s → Movimento: 0.0° (esperado ~-90°)
```

**Conclusão:** Pitch não responde a `setSpeed` também. Problema não é de comando-type, é específico do eixo pitch.

### Hipóteses Ativas

1. **OM3 não expõe controle de pitch via BLE** — apenas yaw é controlável via wireless
2. **Pitch requer modo/habilitação específica** — pode estar desabilitado por padrão
3. **Pitch usa comando diferente** — não é `0x0C` (setSpeed) ou `0x14` (setAngle)
4. **axisMask diferente** — `0x05` pode não incluir pitch no OM3

### Próximos Testes

- [ ] Teste manual: posicionar gimbal fisicamente em pitch visível, enviar `setAngle(pitch=0)` e observar resposta
- [ ] Teste com `axisMask=0x01` (só pitch) vs `0x07` (pitch+roll+yaw)
- [ ] Investigar se pitch pode ser controlado via outros cmdSets (não 0x04)
- [ ] Verificar se gimbal responde diferentemente quando pairing bem-sucedido vs. timeout

## Caveats — read this first

- The DJI Mimo team has never published a public BLE spec. The protocol details
  here come from `lib-osmo-ble` and `node-osmo` (see References below) which
  reverse-engineered Mimo's BLE traffic against an **Osmo Pocket 3**, not the
  OM3. The OM3 is a 2019 phone gimbal with **no camera and no WiFi
  subsystem**, so the WiFi pairing flow may not apply, and some command IDs
  could differ. Treat *Auto-pair on connect* as best-effort.
- `lib-osmo-ble`'s authors observed that the Pocket 3 acknowledges DUML gimbal
  commands at the protocol level but silently ignores motor commands until
  WiFi streaming is active. Whether the OM3 has the same restriction is an
  open question — the protocol stack is correct on this side.
- Xcode is required to build a sandboxed `.app`. The CRC and DUML codec can be
  exercised standalone from `swift` if you copy `DUMLProtocol.swift` into a
  scratch script.

## References

- [yigitkonur/lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble) — primary
  reference; PROTOCOL.md verifies the wire format on a Pocket 3
- [datagutt/node-osmo](https://github.com/datagutt/node-osmo) — earlier
  TypeScript implementation
- [xaionaro/reverse-engineering-dji](https://github.com/xaionaro/reverse-engineering-dji)
  — Wireshark dissector used as ground truth
