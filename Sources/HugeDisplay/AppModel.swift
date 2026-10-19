import Combine
import HugeDisplayCore
import SwiftUI

/// Wires concrete services together. Views talk only to this object.
@MainActor
final class AppModel: ObservableObject {
    let displays = DisplayManager()
    let modes: ModeServicing
    let toggle: DisplayToggleServicing
    let brightness: BrightnessServicing
    let color: ColorServicing
    let pip: PIPServicing

    @Published var lastError: String?

    init() {
        modes = ModeService()
        toggle = DisplayToggleService(manager: displays)
        brightness = BrightnessService()
        color = ColorService()
        pip = PIPService()
    }

    func run(_ action: () throws -> Void) {
        do {
            try action()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        displays.refresh()
    }
}
