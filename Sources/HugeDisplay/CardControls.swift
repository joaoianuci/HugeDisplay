import SwiftUI

/// Small capsule label used for Built-in / Main / HiDPI.
struct Badge: View {
    /// A key (not a `String`) so `Text` looks it up in the main bundle's Localizable.strings.
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// Label + control row with a fixed label column so pickers line up across a card.
/// The label may wrap to two lines: translated titles ("Frecuencia de actualización") are long.
struct ControlRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 84, alignment: .leading)
            content
        }
    }
}
