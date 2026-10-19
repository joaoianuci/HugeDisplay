import AppKit
import HugeDisplayCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manager.displays.isEmpty {
                Text("No displays found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            ForEach(manager.displays) { display in
                DisplayCard(display: display, state: model.cardModel(for: display.id))
            }
            FooterView()
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { model.menuDidAppear() }
        // The window can be re-shown without re-creating the view; key-window is the reliable signal.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.menuDidAppear()
        }
        .onChange(of: manager.displays) { _, _ in model.reloadAll() }
    }
}
