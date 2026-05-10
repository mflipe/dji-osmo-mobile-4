import Foundation
import SwiftUI

enum AxisMode: String, CaseIterable, Identifiable {
    case free       = "Free"
    case horizontal = "Horizontal"
    case vertical   = "Vertical"

    var id: String { rawValue }
}

enum MButtonAction: String, CaseIterable, Identifiable {
    case toggleMode  = "Toggle Mode"
    case openPanel   = "Open Panel"

    var id: String { rawValue }
}

// MARK: - SettingsModel

@MainActor
final class SettingsModel: ObservableObject {
    /// Max angular speed for joystick/keyboard drive, in degrees per second. Hard-capped at 30.
    @AppStorage("joystickSpeedDPS") var joystickSpeedDPS: Double = 15
    @AppStorage("invertPan")        var invertPan: Bool = false
    @AppStorage("invertTilt")       var invertTilt: Bool = false
    @AppStorage("axisMode")         var axisMode: AxisMode = .free
    @AppStorage("mButtonAction")    var mButtonAction: MButtonAction = .toggleMode
    @AppStorage("sportMode")        var sportMode: Bool = false
    @AppStorage("trackingFaceOnly") var trackingFaceOnly: Bool = true
    @AppStorage("showGrid")         var showGrid: Bool = false
}

