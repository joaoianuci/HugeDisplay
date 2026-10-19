import HugeDisplayCore
import SwiftUI

struct DisplayCard: View {
    let display: Display
    @ObservedObject var state: DisplayCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            DisplayHeader(display: display)
            if display.isEnabled {
                BrightnessRow(state: state)
                ModeRows(display: display, state: state)
                ColorRow(state: state)
                PIPRow(state: state)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(display.isEnabled ? 1 : 0.7)
    }
}

// MARK: - Header

struct DisplayHeader: View {
    let display: Display
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var manager: DisplayManager

    private var isLastActive: Bool { display.isEnabled && manager.activeCount <= 1 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                .font(.system(size: 18))
                .foregroundStyle(display.isEnabled ? .primary : .tertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(display.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if display.isBuiltin { Badge(text: "Built-in") }
                    if display.isMain { Badge(text: "Main") }
                    if display.currentMode?.isHiDPI == true { Badge(text: "HiDPI") }
                    if !display.isEnabled { Badge(text: "Off") }
                }
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(
                get: { display.isEnabled },
                set: { newValue in model.run { try model.toggle.setEnabled(newValue, display: display.id) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(isLastActive)
            .help(isLastActive ? "At least one display must stay active" : (display.isEnabled ? "Turn display off" : "Turn display on"))
        }
    }
}

// MARK: - Brightness

struct BrightnessRow: View {
    @ObservedObject var state: DisplayCardModel

    var body: some View {
        if state.brightnessBackend != .none {
            HStack(spacing: 6) {
                Image(systemName: "sun.min").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { state.brightness }, set: { state.setBrightness($0) }),
                    in: 0...1,
                    onEditingChanged: { state.brightnessEditing($0) }
                )
                Image(systemName: "sun.max").font(.caption).foregroundStyle(.secondary)
                Text("\(Int((state.brightness * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .help(backendHelp)
        }
    }

    private var backendHelp: String {
        switch state.brightnessBackend {
        case .builtin: "Brightness (Apple)"
        case .ddc: "Brightness (DDC/CI)"
        case .software: "Brightness (software dimming)"
        case .none: ""
        }
    }
}

// MARK: - Resolution + refresh rate

struct ModeRows: View {
    let display: Display
    @ObservedObject var state: DisplayCardModel

    private var current: DisplayModeOption? { display.currentMode }

    private var resolutions: [ResolutionChoice] {
        ModeChoices.resolutions(from: state.modes, current: current)
    }

    private var rates: [DisplayModeOption] {
        guard let current else { return [] }
        return ModeChoices.rates(in: state.modes, for: ResolutionChoice(current))
    }

    var body: some View {
        if !state.modes.isEmpty, let current {
            ControlRow(title: "Resolution") {
                Picker("Resolution", selection: Binding<ResolutionChoice>(
                    get: { ResolutionChoice(current) },
                    set: { choice in
                        if let mode = ModeChoices.mode(for: choice, preferredRate: current.refreshRate, in: state.modes) {
                            state.apply(mode)
                        }
                    }
                )) {
                    ForEach(resolutions) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            if !rates.isEmpty {
                ControlRow(title: "Refresh rate") {
                    Picker("Refresh rate", selection: Binding<String>(
                        get: {
                            rates.first { ModeChoices.rateKey($0.refreshRate) == ModeChoices.rateKey(current.refreshRate) }?.id ?? ""
                        },
                        set: { id in
                            if let mode = rates.first(where: { $0.id == id }) { state.apply(mode) }
                        }
                    )) {
                        if !rates.contains(where: { ModeChoices.rateKey($0.refreshRate) == ModeChoices.rateKey(current.refreshRate) }) {
                            Text(ModeChoices.rateLabel(current.refreshRate)).tag("")
                        }
                        ForEach(rates) { Text(ModeChoices.rateLabel($0.refreshRate)).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(rates.count < 2)
                }
            }
        }
    }
}

// MARK: - Colour

struct ColorRow: View {
    @ObservedObject var state: DisplayCardModel

    var body: some View {
        if !state.presets.isEmpty {
            ControlRow(title: "Color") {
                Picker("Color preset", selection: Binding<String>(
                    get: { state.currentPreset?.id ?? "" },
                    set: { id in
                        if let preset = state.presets.first(where: { $0.id == id }) { state.apply(preset) }
                    }
                )) {
                    if state.currentPreset == nil { Text("—").tag("") }
                    ForEach(state.presets) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - PIP

struct PIPRow: View {
    @ObservedObject var state: DisplayCardModel

    var body: some View {
        HStack {
            if state.hasPipPermission {
                Button {
                    state.togglePip()
                } label: {
                    Label(state.pipShowing ? "Hide PIP" : "Show PIP",
                          systemImage: state.pipShowing ? "pip.exit" : "pip.enter")
                }
                .disabled(state.pipBusy)
                if state.pipShowing {
                    Toggle("Click-through", isOn: Binding(get: { state.pipClickThrough }, set: { state.setPipClickThrough($0) }))
                        .toggleStyle(.checkbox)
                }
            } else {
                Button {
                    state.requestPipPermission()
                } label: {
                    Label("Grant Screen Recording", systemImage: "record.circle")
                }
            }
            Spacer()
        }
        .controlSize(.small)
    }
}
