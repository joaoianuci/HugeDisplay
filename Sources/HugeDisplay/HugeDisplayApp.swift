import HugeDisplayCore
import SwiftUI

@main
struct HugeDisplayApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(model.displays)
        } label: {
            Image(systemName: "display.2")
        }
        .menuBarExtraStyle(.window)
    }
}
