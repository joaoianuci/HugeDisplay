import AppKit
import CoreGraphics
import ScreenCaptureKit

extension NSScreen {
    var pipDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func pipScreen(for id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.pipDisplayID == id }
    }

    static func pipScreen(for key: DisplayKey) -> NSScreen? {
        screens.first { screen in screen.pipDisplayID.map { DisplayKey($0) == key } ?? false }
    }
}

/// One open PIP: the panel, its stream, and the persisted per-display settings.
@MainActor
final class PIPSession: NSObject, NSWindowDelegate {
    let display: CGDirectDisplayID
    let key: DisplayKey
    private(set) var settings: PIPSettings

    var onSettingsChanged: ((DisplayKey, PIPSettings) -> Void)?
    /// Called when the stream dies on its own (display gone, permission revoked). The owner should close the session.
    var onFailure: ((CGDirectDisplayID, Error) -> Void)?

    private let panel: PIPPanel
    private let view: PIPView
    private var stream: PIPStream!
    private var aspect: CGSize
    private var observers: [NSObjectProtocol] = []
    private var commitTask: Task<Void, Never>?
    private var isClosed = false

    private static let commitDelay: Duration = .milliseconds(150)

    init(display: CGDirectDisplayID, key: DisplayKey, filter: SCContentFilter, settings: PIPSettings) {
        self.display = display
        self.key = key
        self.settings = settings
        aspect = Self.sourceAspect(display)

        let frame = Self.initialFrame(display: display, settings: settings, aspect: aspect)
        panel = PIPPanel(frame: frame)
        view = PIPView(frame: NSRect(origin: .zero, size: frame.size))
        super.init()

        panel.contentView = view
        panel.contentAspectRatio = aspect
        panel.alphaValue = settings.opacity
        panel.ignoresMouseEvents = settings.clickThrough
        view.currentOpacity = settings.opacity
        view.isClickThrough = settings.clickThrough
        view.onSetOpacity = { [weak self] in self?.setOpacity($0) }
        view.onSetClickThrough = { [weak self] in self?.setClickThrough($0) }
        view.onClose = { [weak self] in
            guard let self else { return }
            self.onFailure?(self.display, CancellationError())
        }

        let size = captureSize()
        stream = PIPStream(
            filter: filter,
            width: size.width,
            height: size.height,
            onFrame: { [weak self] in self?.view.display($0) },
            onStop: { [weak self] error in
                guard let self else { return }
                self.onFailure?(self.display, error)
            }
        )

        panel.delegate = self
        observe()
        panel.orderFrontRegardless()
        stream.setActive(true)
    }

    func bringToFront() {
        panel.orderFrontRegardless()
        updateVisibility()
    }

    func setOpacity(_ value: Double) {
        let snapped = PIPGeometry.snapOpacity(value)
        settings.opacity = snapped
        panel.alphaValue = snapped
        view.currentOpacity = snapped
        persist()
    }

    func setClickThrough(_ on: Bool) {
        settings.clickThrough = on
        panel.ignoresMouseEvents = on
        view.isClickThrough = on
        persist()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        commitTask?.cancel()
        saveFrame()
        persist()
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        stream.shutdown()
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) { scheduleCommit() }
    func windowDidMove(_ notification: Notification) { scheduleCommit() }
    func windowDidChangeScreen(_ notification: Notification) { scheduleCommit() }
    func windowDidChangeBackingProperties(_ notification: Notification) { scheduleCommit() }

    // MARK: - Private

    private func observe() {
        let center = NotificationCenter.default
        let visibilityNames: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in visibilityNames {
            observers.append(center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sourceGeometryChanged() }
        })
    }

    /// Capture only while the panel can actually be seen; the layer keeps the last frame meanwhile.
    private func updateVisibility() {
        guard !isClosed else { return }
        let visible = panel.isVisible && !panel.isMiniaturized && panel.occlusionState.contains(.visible)
        stream.setActive(visible)
    }

    /// Debounced (~150 ms) so a live resize reconfigures the stream once, not per frame.
    private func scheduleCommit() {
        guard !isClosed else { return }
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.commitDelay)
            guard !Task.isCancelled, let self, !self.isClosed else { return }
            self.commit()
        }
    }

    private func commit() {
        let size = captureSize()
        stream.updateSize(width: size.width, height: size.height)
        saveFrame()
        persist()
    }

    /// Source mode or arrangement changed: refresh aspect ratio and capture size.
    private func sourceGeometryChanged() {
        guard !isClosed else { return }
        let newAspect = Self.sourceAspect(display)
        if newAspect != aspect {
            aspect = newAspect
            panel.contentAspectRatio = newAspect
            let bounds = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
            panel.setFrame(PIPGeometry.fit(panel.frame, aspect: newAspect, in: bounds), display: true)
        }
        scheduleCommit()
    }

    private func captureSize() -> (width: Int, height: Int) {
        PIPGeometry.captureSize(panelSize: panel.frame.size, scale: panel.backingScaleFactor, sourcePixels: Self.sourcePixels(display))
    }

    private func saveFrame() {
        guard let screen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) else { return }
        settings.frame = PIPGeometry.fraction(of: panel.frame, in: screen.frame)
        settings.hostScreen = screen.pipDisplayID.map(DisplayKey.init)
    }

    private func persist() {
        onSettingsChanged?(key, settings)
    }

    private static func sourcePixels(_ display: CGDirectDisplayID) -> CGSize {
        if let mode = CGDisplayCopyDisplayMode(display), mode.pixelWidth > 0, mode.pixelHeight > 0 {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        return CGSize(width: CGDisplayPixelsWide(display), height: CGDisplayPixelsHigh(display))
    }

    private static func sourceAspect(_ display: CGDirectDisplayID) -> CGSize {
        let pixels = sourcePixels(display)
        return pixels.width > 0 && pixels.height > 0 ? pixels : CGSize(width: 16, height: 9)
    }

    /// Restores the saved frame on its original screen when possible; otherwise places the PIP in a corner of
    /// a screen other than the source (or the source's own when it is the only one).
    private static func initialFrame(display: CGDirectDisplayID, settings: PIPSettings, aspect: CGSize) -> CGRect {
        if let fraction = settings.frame {
            let host = settings.hostScreen.flatMap { NSScreen.pipScreen(for: $0) } ?? NSScreen.main ?? NSScreen.screens.first
            if let host {
                let restored = PIPGeometry.frame(from: fraction, in: host.frame)
                return PIPGeometry.fit(restored, aspect: aspect, in: host.visibleFrame)
            }
        }
        let host = NSScreen.screens.first { $0.pipDisplayID != display } ?? NSScreen.pipScreen(for: display) ?? NSScreen.main
        let bounds = host?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        return PIPGeometry.defaultFrame(aspect: aspect, in: bounds)
    }
}
