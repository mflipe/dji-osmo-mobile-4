# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Native macOS app (SwiftUI + CoreBluetooth, no external dependencies) that
controls a DJI Osmo Mobile 3 gimbal over BLE using the DJI **DUML** protocol.
Single-window, macOS 26+, Xcode 26+.

## Commands

```bash
# Open in Xcode
open DjiOsmo3Mac.xcodeproj

# Quick syntax / type-check from command line (Xcode SDK not required for the
# pure-Foundation files; SwiftUI files need a full Xcode install to typecheck
# fully — without Xcode the only error is the #Preview macro plugin).
swiftc -parse DjiOsmo3Mac/*.swift
swiftc -typecheck DjiOsmo3Mac/DUMLProtocol.swift DjiOsmo3Mac/BLEManager.swift DjiOsmo3Mac/GimbalController.swift

# Build via xcodebuild (requires Xcode, not Command Line Tools)
xcodebuild -project DjiOsmo3Mac.xcodeproj -scheme DjiOsmo3Mac -configuration Debug build
```

There is no automated test target. The DUML codec was verified by ad-hoc
`swift` scripts comparing against a canonical left-shifting CRC reference —
re-run those scripts if you touch CRC parameters or frame layout.

## Architecture

The app is five Swift files in a strict layering. Read them in this order:

1. **`DUMLProtocol.swift`** — pure Foundation. Wire format, CRC, framing.
   - `DUML` enum: `Address`, `Flag`, `CmdSet`, `GimbalCmd`, `WifiCmd`,
     `GimbalMode`, BLE UUIDs, defaults. `target(from:to:)` builds the LE-encoded
     `sender | (receiver << 8)` field.
   - `DUMLCRC` — table-driven, **right-shift with reflected polynomial**. The
     pre-reflected init values (`0x77`, `0x3692`) are *not* the catalog values
     (`0xEE`, `0x496C`) — they are mathematically equivalent under
     `refIn=refOut=true`. Do not "fix" this back to the catalog values; that
     would silently break every CRC.
   - `DUMLFrame` — `encode()` / `decode()`. Wire layout:
     `[0x55][len_lo][ver<<2|len_hi][crc8][target:2 LE][seq:2 BE][flags][cmdSet][cmdId][payload][crc16:2 LE]`.
     **`seq` is the only big-endian field** — getting this wrong was a
     documented bug in `node-osmo`.
   - `DUMLStreamParser` — reassembles frames from BLE notification chunks,
     resyncs on `0x55`, drops bad-CRC candidates.

2. **`BLEManager.swift`** — CoreBluetooth `CBCentralManager` wrapper.
   - Discovers service `FFF0` and characteristics `FFF3` / `FFF4` / `FFF5`.
   - `writeDUML(_:)` always writes to **FFF5** with `writeWithoutResponse`,
     chunked to `maximumWriteValueLength(for: .withoutResponse)` (defaults to
     20 if MTU not negotiated). Never write DUML to FFF3 — firmware ignores it.
   - `writePairingTrigger()` writes `[0x01, 0x00]` to FFF4 (with response),
     falling back to FFF3 if FFF4 is missing.
   - Subscribes notifications on every notify-capable characteristic in FFF0;
     different DJI devices push DUML on different ones (Pocket 3 → FFF4).
   - Talks to the controller via the `BLEManagerDelegate` protocol.

3. **`GimbalController.swift`** — `@MainActor ObservableObject`. Owns the
   `BLEManager`, builds DUML frames, parses telemetry, exposes `@Published`
   state to SwiftUI. The `Mode` enum maps "Sport" → `GimbalMode.fpv` on the
   wire (the OM3 uses FPV mode for what the UI calls Sport).
   `BLEManagerDelegate` callbacks are `nonisolated` and bounce onto
   `@MainActor` via `Task { @MainActor in … }`.

4. **`ContentView.swift`** + **`DjiOsmo3MacApp.swift`** — SwiftUI. The view
   layer reads `connectionState` to gate controls; commands are sent only when
   `.connected` or `.ready`.

## Things to know before changing things

- **Pairing is best-effort.** OM3 has no WiFi subsystem (unlike the Pocket 3
  the protocol references were verified against), so `SetPairingPIN` may not
  apply. The controller falls back to `.ready` after a 4 s timeout — don't
  remove that timer without a replacement signal.
- **Reference implementations target Pocket 3, not OM3.** Command IDs in
  `DUML.GimbalCmd` come from `lib-osmo-ble` (Pocket 3 verified). Some IDs may
  differ on OM3. If a command appears to be silently ignored, instrument with
  the on-screen log first — telemetry pushes (`0x04` / `0x05`) confirm the
  link is healthy even when motor commands are dropped.
- **Sandbox + entitlements.** `DjiOsmo3Mac.entitlements` enables
  `com.apple.security.app-sandbox` and `com.apple.security.device.bluetooth`;
  `Info.plist` carries `NSBluetoothAlwaysUsageDescription`. Removing any of
  these silently breaks BLE on first launch.
- **Bundle ID is `com.example.DjiOsmo3Mac`.** Change it before signing for
  distribution.

## References embedded in the code

- `lib-osmo-ble` (yigitkonur) — primary protocol source; PROTOCOL.md mirrors
  what's encoded in `DUMLProtocol.swift`.
- `node-osmo` (datagutt) — earlier TS implementation; the seq-endianness fix
  is applied here.
- `xaionaro/reverse-engineering-dji` — Wireshark dissector used as ground
  truth for the wire format.
