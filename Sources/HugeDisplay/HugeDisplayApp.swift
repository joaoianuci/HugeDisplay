import HugeDisplayCore
import SwiftUI

@main
struct HugeDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

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
