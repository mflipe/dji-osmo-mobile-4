# DJI Osmo Mobile 3 macOS 26 — Redesign + Webcam + Mimo Parity

## Context

O app atual tem BLE, pareamento, controle de ângulo/velocidade e telemetria funcionais. Faltam: câmera (preview, foto, vídeo), mapeamento dos botões físicos do OM3 via DUML, joystick por teclado, face/body tracking (Vision + PID), timelapse, e a UI no estilo Liquid Glass do macOS 26.

Decisões do usuário:
- Face tracking: Face (padrão) + toggle para corpo inteiro  
- Joystick: teclado WASD/setas + widget on-screen  
- Pós-implementação: `/simplify` para revisão de qualidade

---

## Estado Atual (o que já existe)

| Arquivo | O que já está pronto |
|---|---|
| `DUMLProtocol.swift` | Wire format, CRC8/16, `DUMLFrame`, `DUMLStreamParser`, `DUMLSequencer`, `DUML.GimbalCmd` (control/angle/speed/mode), `DUML.GimbalMode` |
| `BLEManager.swift` | Scan, connect, disconnect, FFF5 write chunked, pairing trigger, notifications |
| `GimbalController.swift` | `setMode()`, `setAngle()`, `setSpeed()`, `stopMotion()`, `recenter()`, telemetria P/R/Y, bateria, log, `ConnectionState`, `Mode` enum |
| `ContentView.swift` | Layout funcional (VStack/HStack), sem câmera, sem macOS 26 |
| `DjiOsmo3MacApp.swift` | Window básico, sem window style macOS 26 |
| `.entitlements` | Sandbox + Bluetooth. Faltam câmera/microfone |

---

## Arquivos a Modificar / Criar

| Arquivo | Ação |
|---|---|
| `DjiOsmo3Mac.entitlements` | Adicionar camera + microphone entitlements |
| `Info.plist` | Adicionar NSCameraUsageDescription, NSMicrophoneUsageDescription |
| `DUMLProtocol.swift` | Adicionar GimbalCmd button cmd ID placeholders (TBD via log) |
| `GimbalController.swift` | Handlers de botões físicos, integração com TrackingEngine, joystick teclado, timelapse |
| `ContentView.swift` | Reescrita completa (NavigationSplitView + Liquid Glass macOS 26) |
| `DjiOsmo3MacApp.swift` | `.windowStyle` + `.windowToolbarStyle` macOS 26 |
| `CameraManager.swift` | **Novo** — AVFoundation (preview, foto, vídeo, zoom, burst, timelapse) |
| `CameraPreviewView.swift` | **Novo** — NSViewRepresentable wrapping AVCaptureVideoPreviewLayer |
| `TrackingEngine.swift` | **Novo** — Vision face/body + PID → setSpeed() |
| `SettingsModel.swift` | **Novo** — @AppStorage para preferências persistidas |

---

## Priorização

### P0 — MVP indispensável

| Área | Funcionalidade | Implementação |
|---|---|---|
| Câmera | Preview ao vivo | AVFoundation + Continuity Camera |
| Câmera | Foto e vídeo | AVCapturePhotoOutput + AVCaptureMovieFileOutput |
| Câmera | Seleção de câmera | Picker com câmeras internas/externas/Continuity |
| Câmera | Zoom digital | AVCaptureDevice.videoZoomFactor |
| Botão físico | Obturador/gravação | DUML → capturePhoto() / toggleRecording() |
| Botão físico | Joystick (pan/tilt) | DUML notify → setSpeed() (já existe) |
| Botão físico | Acionador 2× | recenter() (já existe) |
| Botão físico | Slider de zoom | DUML notify → cameraManager.setZoom() |
| Joystick teclado | WASD/setas | KeyDown/KeyUp SwiftUI → setSpeed() |
| Status | Bateria + BLE | Já funcional, apenas reexposto no novo layout |

### P1 — Versão utilizável

1. Modos de estabilização picker (Follow/Lock/Sport) — `setMode()` já existe
2. Ajustes de velocidade e inversão de eixos (`SettingsModel`)
3. Tracking de rosto (`TrackingEngine` Vision + PID → `setSpeed()`)
4. Toggle face / corpo inteiro
5. Timelapse (intervalo + `AVCapturePhotoOutput`)
6. Calibração automática do gimbal
7. Preferências de mapeamento dos botões

### P2 — Versão avançada

1. ActiveTrack completo (corpo/cabeça/ombros via VNDetectHumanBodyPoseRequest)
2. Seleção manual de sujeito por arrastar no preview
3. Controle por gestos (palma / sinal da paz via VNDetectHumanHandPoseRequest)
4. Hyperlapse (timelapse + movimento suave de gimbal)
5. Panorâmica 3×3 e 180°
6. Câmera lenta (depende de FPS disponível)
7. Story templates (Rocket, Orbit, Dronie)

---

## Mapeamento dos Botões Físicos do OM3

> **IMPORTANTE:** Os cmd IDs abaixo são placeholders. Antes de implementar os handlers, conecte o OM3 e pressione cada botão enquanto observa o log RX no app — o `handleFrame()` já logra todos os frames desconhecidos. Anote os `cmdSet`/`cmdId` reais e atualize `DUML.GimbalCmd`.

### Botão Obturador/Gravação
| Ação | Função | Implementação |
|---|---|---|
| 1× press | Foto / toggle gravação | `cameraManager.capturePhoto()` / `toggleRecording()` |
| Hold em modo Foto | Burst | `cameraManager.startBurst()` |

### Joystick (pan/tilt)
| Movimento | Implementação |
|---|---|
| Vertical | `ctl.setSpeed(pitchDeg:)` |
| Horizontal | `ctl.setSpeed(yawDeg:)` |

### Slider de Zoom
| Ação | Implementação |
|---|---|
| T (tele) | `cameraManager.setZoom(+delta)` |
| W (wide) | `cameraManager.setZoom(-delta)` |

### Acionador (Trigger)
| Ação | Implementação |
|---|---|
| 2× press | `ctl.recenter()` (já existe) |
| 3× press | `cameraManager.switchToNextCamera()` |
| Hold | Lock tracking / gimbal |
| 1× com tracking ativo | `trackingEngine.toggle()` |

### Botão M
| Ação | Implementação |
|---|---|
| 1× press | Configurável via `SettingsModel.mButtonAction` |
| 2× press | Toggle orientação (portrait/landscape crop) |
| 3× press | Standby / pausar tracking |

---

## Modos de Captura

| Modo | Prioridade | Observação |
|---|---|---|
| Vídeo | P0 | AVCaptureMovieFileOutput |
| Foto | P0 | AVCapturePhotoOutput, timer, burst |
| Timelapse | P1 | Timer + capturePhoto em intervalo |
| Hyperlapse | P2 | Timelapse + movimento de gimbal |
| Panorâmica | P2 | Grid de ângulos + instruções |
| Câmera lenta | P2 | Depende de FPS disponível |

---

## Modos do Estabilizador

| Modo | DUML | UI label | Status |
|---|---|---|---|
| Rastreio | `GimbalMode.follow (1)` | "Follow" | Já existe em `GimbalController.Mode` |
| Inclinação Travada | `GimbalMode.lock (0)` | "Lock" | Já existe |
| FPV/Sport | `GimbalMode.fpv (2)` | "Sport" | Já existe |

`setMode()` já envia o frame DUML correto — apenas reexpor no novo layout.

---

## Arquitetura dos Novos Componentes

### CameraManager.swift

```swift
@MainActor final class CameraManager: NSObject, ObservableObject {
    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCamera: AVCaptureDevice?
    @Published var isRunning = false
    @Published var isRecording = false
    @Published var zoomFactor: CGFloat = 1.0
    @Published var captureMode: CaptureMode = .video  // .photo / .video / .timelapse

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    let videoDataOutput = AVCaptureVideoDataOutput()  // internal para TrackingEngine

    var frameHandler: ((CMSampleBuffer) -> Void)?  // TrackingEngine usa este hook

    func discoverCameras()
    func start(camera: AVCaptureDevice)
    func stop()
    func switchToNextCamera()
    func capturePhoto(timer: TimeInterval = 0)
    func startBurst() / stopBurst()
    func toggleRecording()
    func setZoom(_ factor: CGFloat)  // clampado a device.maxAvailableVideoZoomFactor
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer
}
```

### TrackingEngine.swift

```swift
final class TrackingEngine {
    enum Target { case face, body }
    var target: Target = .face
    var isActive = false

    // Vision: VNDetectFaceRectanglesRequest (face) ou VNDetectHumanBodyPoseRequest (body)
    // PID por eixo: kP=80/60, kI=0.5/0.3, kD=15/10, anti-windup ±30°/s
    // Retorna velocidades para GimbalController.setSpeed()
    func process(sampleBuffer: CMSampleBuffer) -> (pitch: Double, yaw: Double, bounds: CGRect?)?
    func toggle()
    func reset()  // zera integral PID
}
```

### SettingsModel.swift

```swift
@MainActor final class SettingsModel: ObservableObject {
    @AppStorage("joystickSpeed")  var joystickSpeed: JoystickSpeed = .medium  // 30/60/120 °/s
    @AppStorage("invertPan")      var invertPan: Bool = false
    @AppStorage("invertTilt")     var invertTilt: Bool = false
    @AppStorage("axisMode")       var axisMode: AxisMode = .free  // .free / .horizontal / .vertical
    @AppStorage("mButtonAction")  var mButtonAction: MButtonAction = .toggleMode
    @AppStorage("sportMode")      var sportMode: Bool = false  // multiplicador PID no tracking
    @AppStorage("trackingTarget") var trackingTarget: TrackingEngine.Target = .face
}
```

---

## Layout macOS 26 (Liquid Glass)

```
┌────────────────────────────────────────────────────────────────────┐
│ Toolbar (glass): [● status] [DeviceName] [🔋42%]  [⏺ REC 00:32] [⚙]│
├────────────┬───────────────────────────────────────────────────────┤
│ Sidebar    │                                                        │
│ (.glass    │   Camera Preview (AVCaptureVideoPreviewLayer)          │
│  260px     │                                                        │
│  colaps.)  │  [Subject bounding box / tracking reticle overlay]     │
│            │                                                        │
│ ▶ Devices  │  ┌─────────────────────────────────┐  (top-right)    │
│   [Scan]   │  │ Telemetry HUD (.glassEffect)    │                  │
│   List     │  │ P 12.3°   R 0.1°   Y -45.0°    │                  │
│            │  │ 🔋 gimbal  ● BLE Ready           │                  │
│ ▶ Camera   │  └─────────────────────────────────┘                  │
│   [Picker] │                                                        │
│   [Res/FPS]│  [Joystick widget — bottom-left, DragGesture]         │
│   [Grid]   │                                                        │
│            ├────────────────────────────────────────────────────────┤
│ ▶ Settings │ Bottom bar (.glassEffect, 64px):                       │
│   Gimbal   │ [📷 Photo] [⏺ Video] [⏱ Timelapse] [🔲 Burst]        │
│   Camera   │ [Follow ⏺ Face/Body] [Mode ▾] [⌖ Recenter] [◼ Stop]  │
│   Buttons  │                                                        │
└────────────┴───────────────────────────────────────────────────────┘
```

**macOS 26 APIs a usar:**
- `.glassEffect()` (novo — substitui `.background(.ultraThinMaterial)`)
- `NavigationSplitView` para sidebar colapsável
- `DjiOsmo3MacApp`: `.windowStyle(.plain)` + `.windowToolbarStyle(.unified(showsTitle: false))`
- `MeshGradient` como fallback quando câmera indisponível

---

## Fluxo de Dados

```
AVCaptureVideoDataOutput
        │
        ▼ frameHandler (CMSampleBuffer)
  TrackingEngine
  VNDetectFaceRectanglesRequest /
  VNDetectHumanBodyPoseRequest
        │
        ▼ (pitch, yaw) °/s
  GimbalController.setSpeed()  ←── Teclado WASD (onKeyDown)
        │                      ←── DUML joystick notify
        ▼
  BLEManager.writeDUML()
        │
        ▼
  OM3 Gimbal (BLE FFF5)
```

---

## Ordem de Implementação

| # | Step | Arquivos |
|---|---|---|
| 1 | Permissões camera + microphone | `.entitlements`, `Info.plist` |
| 2 | DUML button cmd placeholders | `DUMLProtocol.swift` |
| 3 | SettingsModel | `SettingsModel.swift` (novo) |
| 4 | CameraManager | `CameraManager.swift` (novo) |
| 5 | CameraPreviewView | `CameraPreviewView.swift` (novo) |
| 6 | TrackingEngine | `TrackingEngine.swift` (novo) |
| 7 | GimbalController — botões + tracking + joystick teclado | `GimbalController.swift` |
| 8 | ContentView redesign Liquid Glass | `ContentView.swift` |
| 9 | App entry point macOS 26 | `DjiOsmo3MacApp.swift` |

Pós-implementação: `/simplify` para revisão de qualidade.

---

## Descoberta de Cmd IDs dos Botões (pré-requisito para step 7)

Antes de codificar os handlers em `GimbalController.handleFrame()`:

1. Compilar e rodar o app com o layout atual (ou o redesenhado)
2. Conectar ao OM3
3. Pressionar cada botão físico (Obturador, M, Acionador, Joystick, Slider)
4. Observar as linhas `← cmdSet=XX cmdId=YY` no log RX
5. Anotar cada combinação e atualizar `DUML.GimbalCmd` com os IDs reais

O `handleFrame()` em `GimbalController.swift:329` já emite essas linhas para todos os frames não reconhecidos — nenhuma mudança de código é necessária para a descoberta.

---

## Verificação

```bash
# Type-check dos arquivos Foundation-only (sem SwiftUI)
swiftc -typecheck \
  DjiOsmo3Mac/DUMLProtocol.swift \
  DjiOsmo3Mac/BLEManager.swift \
  DjiOsmo3Mac/GimbalController.swift \
  DjiOsmo3Mac/TrackingEngine.swift \
  DjiOsmo3Mac/CameraManager.swift \
  DjiOsmo3Mac/SettingsModel.swift

# Build completo (requer Xcode instalado)
xcodebuild -project DjiOsmo3Mac.xcodeproj \
  -scheme DjiOsmo3Mac \
  -configuration Debug build

# Verificar entitlements no bundle resultante
codesign -d --entitlements - \
  ~/Library/Developer/Xcode/DerivedData/DjiOsmo3Mac-*/Build/Products/Debug/DjiOsmo3Mac.app
```

Testes funcionais no dispositivo:
- Preview da câmera aparece imediatamente ao conectar  
- Apertar obturador → foto salva / gravação inicia (depende de cmd ID descoberto)  
- WASD movimenta o gimbal via telemetria P/R/Y confirmada  
- Tracking de rosto mantém rosto centrado enquanto câmera move  
- Toggle Face/Body alterna `TrackingEngine.target`  
- Modo Follow/Lock/Sport refletido em `ctl.mode` e confirmado via telemetria
