import HugeDisplayCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(manager.displays) { display in
                DisplayRow(display: display)
                Divider()
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("HugeDisplay").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

/// Placeholder row; replaced by the UI module.
struct DisplayRow: View {
    let display: Display

    var body: some View {
        VStack(alignment: .leading) {
            Text(display.name).font(.headline)
            if let m = display.currentMode {
                Text("\(m.width)×\(m.height) @ \(Int(m.refreshRate))Hz\(m.isHiDPI ? " HiDPI" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
