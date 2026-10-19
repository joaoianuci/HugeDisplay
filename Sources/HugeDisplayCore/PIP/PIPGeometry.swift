import CoreGraphics
import Foundation

/// A rectangle expressed as fractions (0...1) of a screen frame. Survives resolution and arrangement changes.
struct PIPFraction: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// Persisted per-source-display PIP state.
struct PIPSettings: Codable, Equatable, Sendable {
    var frame: PIPFraction?
    /// Display the panel was on when the frame was saved (the fractions are relative to it).
    var hostScreen: DisplayKey?
    var opacity: Double = 1
    var clickThrough: Bool = false
}

/// Pure geometry helpers, kept free of AppKit state so they are unit-testable.
enum PIPGeometry {
    static let minPanelWidth: CGFloat = 160
    static let allowedOpacities: [Double] = [1, 0.75, 0.5]

    static func fraction(of frame: CGRect, in screen: CGRect) -> PIPFraction? {
        guard screen.width > 0, screen.height > 0 else { return nil }
        return PIPFraction(
            x: Double((frame.minX - screen.minX) / screen.width),
            y: Double((frame.minY - screen.minY) / screen.height),
            width: Double(frame.width / screen.width),
            height: Double(frame.height / screen.height)
        )
    }

    static func frame(from fraction: PIPFraction, in screen: CGRect) -> CGRect {
        CGRect(
            x: screen.minX + CGFloat(fraction.x) * screen.width,
            y: screen.minY + CGFloat(fraction.y) * screen.height,
            width: CGFloat(fraction.width) * screen.width,
            height: CGFloat(fraction.height) * screen.height
        )
    }

    /// Forces `frame` to the given aspect ratio (width kept unless it does not fit), within `bounds`,
    /// with at least `minWidth` width, and slides it fully inside `bounds`.
    static func fit(_ frame: CGRect, aspect: CGSize, in bounds: CGRect, minWidth: CGFloat = minPanelWidth) -> CGRect {
        guard aspect.width > 0, aspect.height > 0, bounds.width > 0, bounds.height > 0 else { return frame }
        let ratio = aspect.width / aspect.height
        var width = min(max(frame.width, minWidth), bounds.width)
        var height = width / ratio
        if height > bounds.height {
            height = bounds.height
            width = height * ratio
        }
        let x = min(max(frame.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(frame.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// First-run placement: bottom-right corner of `bounds`, 30% of its width.
    static func defaultFrame(aspect: CGSize, in bounds: CGRect, margin: CGFloat = 24) -> CGRect {
        guard aspect.width > 0, aspect.height > 0 else {
            return CGRect(x: bounds.minX + margin, y: bounds.minY + margin, width: 320, height: 180)
        }
        let width = max(minPanelWidth, bounds.width * 0.3)
        let height = width * aspect.height / aspect.width
        let raw = CGRect(x: bounds.maxX - width - margin, y: bounds.minY + margin, width: width, height: height)
        return fit(raw, aspect: aspect, in: bounds)
    }

    /// Stream output size in pixels: panel size times backing scale, never larger than the source.
    /// Keeps the panel's aspect ratio when capping.
    static func captureSize(panelSize: CGSize, scale: CGFloat, sourcePixels: CGSize) -> (width: Int, height: Int) {
        let w = max(1, panelSize.width * max(scale, 1))
        let h = max(1, panelSize.height * max(scale, 1))
        var factor: CGFloat = 1
        if sourcePixels.width > 0 { factor = min(factor, sourcePixels.width / w) }
        if sourcePixels.height > 0 { factor = min(factor, sourcePixels.height / h) }
        return (max(2, Int((w * factor).rounded())), max(2, Int((h * factor).rounded())))
    }

    /// Snaps arbitrary values to the supported opacity steps (100/75/50%).
    static func snapOpacity(_ value: Double) -> Double {
        allowedOpacities.min { abs($0 - value) < abs($1 - value) } ?? 1
    }
}
