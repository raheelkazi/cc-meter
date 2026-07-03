import AppKit
import SwiftUI
import CCMeterCore

extension MeterColor {
    var nsColor: NSColor {
        switch self {
        case .green: return .systemGreen
        case .amber: return .systemOrange
        case .red: return .systemRed
        }
    }
    var swiftUIColor: Color { Color(nsColor) }
}
