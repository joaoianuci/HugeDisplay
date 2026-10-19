import CoreGraphics
import HugeDisplayCore
import SwiftUI

/// UI state for one display card. Reads services on demand (menu open / display change),
/// never on a timer, and throttles brightness writes because DDC is slow.
@MainActor
final class DisplayCardModel: ObservableObject {
    let id: CGDirectDisplayID
    private unowned let app: AppModel

    @Published private(set) var brightnessBackend: BrightnessBackend = .none
    @Published private(set) var brightness: Double = 0.5
    @Published private(set) var modes: [DisplayModeOption] = []
    @Published private(set) var presets: [ColorPreset] = []
    @Published private(set) var currentPreset: ColorPreset?
    @Published private(set) var pipShowing = false
    @Published private(set) var pipBusy = false
    @Published private(set) var hasPipPermission = true
    @Published private(set) var pipClickThrough = false

    // Brightness throttling (~30 writes/s max, last value always applied).
    private static let minInterval: Duration = .milliseconds(33)
    private var pending: Double?
    private var lastSend: ContinuousClock.Instant = .now - .seconds(1)
    private var trailing: Task<Void, Never>?
    private var isDragging = false

    init(id: CGDirectDisplayID, app: AppModel) {
        self.id = id
        self.app = app
    }

    func reload() {
        // DDC probes/reads take 35-150 ms, so they never run on the main thread.
        Task {
            brightnessBackend = await app.brightness.refreshBackend(for: id)
            let value = await app.brightness.refreshBrightness(for: id)
            if brightnessBackend != .none, !isDragging, pending == nil, let value {
                brightness = value
            }
        }
        modes = app.modes.modes(for: id)
        presets = app.color.presets(for: id)
        currentPreset = app.color.currentPreset(for: id)
        hasPipPermission = app.pip.hasPermission
        pipShowing = app.pip.isShowing(source: id)
        pipClickThrough = app.pip.isClickThrough(source: id)
    }

    // MARK: - Brightness

    func setBrightness(_ value: Double) {
        brightness = value
        pending = value
        let elapsed = ContinuousClock.now - lastSend
        if elapsed >= Self.minInterval {
            flushBrightness()
        } else if trailing == nil {
            let wait = Self.minInterval - elapsed
            trailing = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                self?.flushBrightness()
            }
        }
    }

    func brightnessEditing(_ editing: Bool) {
        isDragging = editing
        if !editing { flushBrightness() }
    }

    private func flushBrightness() {
        trailing?.cancel()
        trailing = nil
        guard let value = pending else { return }
        pending = nil
        lastSend = .now
        do {
            try app.brightness.setBrightness(value, for: id)
        } catch {
            app.report(error)
        }
    }

    // MARK: - Modes / colour

    func apply(_ mode: DisplayModeOption) {
        app.run { try app.modes.apply(mode, to: id) }
        modes = app.modes.modes(for: id)
    }

    func apply(_ preset: ColorPreset) {
        app.run { try app.color.apply(preset, to: id) }
        currentPreset = app.color.currentPreset(for: id)
    }

    // MARK: - PIP

    /// Click-through panels can't receive their own context menu, so the menu bar owns this switch.
    func setPipClickThrough(_ on: Bool) {
        app.pip.setClickThrough(on, source: id)
        pipClickThrough = app.pip.isClickThrough(source: id)
    }

    func requestPipPermission() {
        app.pip.requestPermission()
        hasPipPermission = app.pip.hasPermission
    }

    func togglePip() {
        guard !pipBusy else { return }
        if app.pip.isShowing(source: id) {
            app.pip.close(source: id)
            pipShowing = app.pip.isShowing(source: id)
            return
        }
        pipBusy = true
        Task {
            do {
                try await app.pip.show(source: id)
                app.lastError = nil
            } catch {
                app.report(error)
            }
            pipShowing = app.pip.isShowing(source: id)
            hasPipPermission = app.pip.hasPermission
            pipBusy = false
        }
    }
}
