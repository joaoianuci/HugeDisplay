import Combine
import HugeDisplayCore
import ServiceManagement
import SwiftUI

/// Wires concrete services together. Views talk only to this object.
@MainActor
final class AppModel: ObservableObject {
    /// Single instance so the NSApplicationDelegate (termination hook) can reach the model.
    static let shared = AppModel()

    let displays = DisplayManager()
    let modes: ModeServicing
    let toggle: DisplayToggleService
    let brightness: BrightnessService
    let color: ColorServicing
    let pip: PIPService

    @Published var lastError: String?
    @Published private(set) var launchAtLogin = false

    /// Per-display UI state, created lazily and pruned when displays disappear.
    private var cards: [CGDirectDisplayID: DisplayCardModel] = [:]
    private var observers: Set<AnyCancellable> = []

    init() {
        modes = ModeService()
        toggle = DisplayToggleService(manager: displays)
        brightness = BrightnessService()
        color = ColorService()
        pip = PIPService()
        // A previous run that crashed or was killed may have left displays disabled.
        if toggle.hasPendingRestore { toggle.restoreAll() }

        // Display IDs and gamma tables reset on reconfiguration and wake; brightness caches must follow.
        displays.$displays
            .dropFirst()
            .removeDuplicates { $0.map(\.id) == $1.map(\.id) }
            .sink { [weak self] _ in self?.brightness.displaysChanged() }
            .store(in: &observers)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.brightness.displaysChanged() }
            .store(in: &observers)
    }

    // MARK: - Actions

    func run(_ action: () throws -> Void) {
        do {
            try action()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        displays.refresh()
    }

    func report(_ error: Error) {
        lastError = error.localizedDescription
    }

    // MARK: - Per-display state

    func cardModel(for id: CGDirectDisplayID) -> DisplayCardModel {
        if let existing = cards[id] { return existing }
        let created = DisplayCardModel(id: id, app: self)
        cards[id] = created
        created.reload()
        return created
    }

    /// Called on menu appear and whenever the display list changes. No timers: purely event driven.
    func reloadAll() {
        let live = Set(displays.displays.map(\.id))
        for id in Array(cards.keys) where !live.contains(id) { cards[id] = nil }
        for display in displays.displays where display.isEnabled {
            cardModel(for: display.id).reload()
        }
        refreshLaunchAtLogin()
    }

    func menuDidAppear() {
        displays.refresh()
        reloadAll()
    }

    // MARK: - Launch at login

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    // MARK: - Lifecycle

    func willTerminate() {
        // Disabled displays must never outlive the app that can bring them back.
        toggle.restoreAll()
        brightness.restoreSoftwareDimming()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon even when run unbundled via `swift run`.
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in await AppModel.shared.pip.restoreLastSession() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.willTerminate() }
    }
}
