import Foundation
import SwiftUI

// MARK: - Supporting types

enum JoystickSpeed: String, CaseIterable, Identifiable {
    case slow   = "Slow"    // 30 °/s
    case medium = "Medium"  // 60 °/s
    case fast   = "Fast"    // 120 °/s

    var id: String { rawValue }

    var degreesPerSecond: Double {
        switch self {
        case .slow:   return 30
        case .medium: return 60
        case .fast:   return 120
        }
    }
}

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
    @AppStorage("joystickSpeed")    var joystickSpeed: JoystickSpeed = .medium
    @AppStorage("invertPan")        var invertPan: Bool = false
    @AppStorage("invertTilt")       var invertTilt: Bool = false
    @AppStorage("axisMode")         var axisMode: AxisMode = .free
    @AppStorage("mButtonAction")    var mButtonAction: MButtonAction = .toggleMode
    @AppStorage("sportMode")        var sportMode: Bool = false
    @AppStorage("trackingFaceOnly") var trackingFaceOnly: Bool = true
    @AppStorage("showGrid")         var showGrid: Bool = false
}

