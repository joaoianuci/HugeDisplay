import AppKit
import CoreMedia
import CoreVideo
import QuartzCore

/// Borderless floating panel that never takes focus.
final class PIPPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Hidden from screenshots and, as a second line of defence, from our own capture.
        sharingType = .none
        contentMinSize = NSSize(width: PIPGeometry.minPanelWidth, height: 40)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Layer-backed view that shows the newest captured frame by handing its IOSurface straight to the layer.
final class PIPView: NSView {
    var onSetOpacity: ((Double) -> Void)?
    var onSetClickThrough: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var currentOpacity: Double = 1
    var isClickThrough = false

    /// Keeps the newest sample buffer alive so SCK does not recycle the IOSurface under the layer.
    private var latestSample: CMSampleBuffer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) { nil }

    private func configureLayer() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let layer else { return }
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.drawsAsynchronously = false
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Main thread only.
    func display(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
        latestSample = sampleBuffer
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for value in PIPGeometry.allowedOpacities {
            let item = NSMenuItem(title: "\(Int((value * 100).rounded()))%", action: #selector(opacityChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(value - currentOpacity) < 0.01 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        let clickThrough = NSMenuItem(title: "Click-through (undo from the HugeDisplay menu)", action: #selector(clickThroughChosen(_:)), keyEquivalent: "")
        clickThrough.target = self
        clickThrough.state = isClickThrough ? .on : .off
        menu.addItem(clickThrough)

        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close", action: #selector(closeChosen(_:)), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func opacityChosen(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        onSetOpacity?(value)
    }

    @objc private func clickThroughChosen(_ sender: NSMenuItem) {
        onSetClickThrough?(!isClickThrough)
    }

    @objc private func closeChosen(_ sender: NSMenuItem) {
        onClose?()
    }
}
