# HugeDisplay research: BetterDisplay baseline + PIP design

## A. BetterDisplay baseline (PID 68548, up 1d18h, idle, no PIP visible)
Sampled `top -pid 68548 -l 13 -s 5` (~60s) + ps.
| Metric | Value |
|---|---|
| CPU % | avg ~0.03, peak 0.2 (essentially 0) |
| Memory (top MEM) | 91 MB (ps RSS 122 MB at first sample) |
| Threads | 11 |
| Power (energy impact) | avg ~0.04, peak 0.2 |
| Idle wakeups | ~30 in 60s (~0.5/s) |
| Listening ports | none (no sockets owned) |
| Bundle | 77 MB (Paddle, Sentry, Sparkle frameworks + BetterDisplayHelper) |
| Capture running? | No: CPU/power ~0, so no active stream at sample time |
Target to beat: <0.1% CPU idle, <50 MB RSS, <=8 threads, <0.5 wakeups/s, bundle <10 MB (no Paddle/Sentry).

## Features the user actually has configured (prefs, license fields skipped)
- Displays: built-in Color LCD (id 2, 1470x956 HiDPI 60Hz, native 2560x1664) and LG HDR WFHD (id 3, 2560x1080 75Hz, 10-bit, non-HiDPI default; HiDPI modes exist).
- PIP: only on LG (Display:3): `pipDisplayTagID=3`, `pipAlpha=1`, relative frame (originX .334, originY .319, w .330, h .360 of screen), `lastStartStopPIPDisplayTagID=3`, `lastStartStopPipID=1`. So it is a PIP of the LG display, one PIP, full opacity, position/size stored as screen fractions. (Currently not shown.)
- Brightness: DDC hardware brightness on LG (.63), Apple hardware brightness on built-in (.59), software brightness (=1, unused), "combined brightness" controllers (.69 / .81), DDC volume on LG (1).
- Color: saturation (1), contrast 0, quantization (1), compositor filters (comic/median/sepia/thermal/vibrance/xray all 0), blue light 0.5 (environment controller), color profile control, dithering toggle restored (`restoreFramebufferSettingEnableDithering`).
- Display mode menu with filters on LG (21:9, 75Hz, 10-bit, LoDPI+HiDPI); smooth scaling enabled (`smoothScaling=1`) for the LG vendor/model key.
- Menu: all `menuLevel*` entries default ("unset"); Sparkle auto-updates on.
- NOT configured: virtual displays/dummies, presets, mirroring, groups content, hotkeys, XDR presets, overrides (overridesEnabled=0), manual resolutions, AirPlay/Sidecar, streaming.
So MVP: DDC brightness/volume/contrast, mode+HiDPI list, color/filters, PIP of one display.

## B. PIP design
### Capture
- ScreenCaptureKit `SCStream` with `SCContentFilter(display:excludingWindows:)` (or `desktopIndependentWindow:` for one window). `sourceRect` for region (points, display coords). Matches BetterDisplay's single-display PIP.
- Config for low CPU:
```swift
let c = SCStreamConfiguration()
c.width  = Int(pipSize.width  * scale)     // match the PIP window in pixels; set to <= source size
c.height = Int(pipSize.height * scale)
c.scalesToFit = true                       // GPU scaling inside WindowServer
c.pixelFormat = kCVPixelFormatType_32BGRA  // direct IOSurface for CALayer; 420v (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) only if encoding
c.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 60 for smooth; 15 for idle PIP
c.queueDepth = 3                           // min 3 recommended, max 8
c.showsCursor = false                      // true if the PIP should show the pointer
c.capturesAudio = false
c.colorSpaceName = CGColorSpace.sRGB       // or displayP3; avoid HDR unless needed
```
- Update on resize with `stream.updateConfiguration(c)` (debounce ~100ms) rather than recreating the stream.
- SCStream only emits frames when content changes (status .idle otherwise), so a static desktop costs almost nothing. Filter on `SCStreamFrameInfo.status == .complete`.
- Exclude the PIP panel itself to avoid infinite mirror when capturing the same display: `excludingWindows: [pipSCWindow]` (look up via `SCShareableContent` by windowID = `panel.windowNumber`), or set `panel.sharingType = .none` (hidden from capture; also hides it from screenshots).
- Delegate `SCStreamDelegate.stream(_:didStopWithError:)` to restart on display reconfig (`NSApplication.didChangeScreenParametersNotification`).

### Render path (recommended: IOSurface to CALayer.contents)
```swift
func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of t: SCStreamOutputType) {
    guard t == .screen, let pb = CMSampleBufferGetImageBuffer(sb),
          let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
    // validate status == .complete first
    let obj = surf as AnyObject   // IOSurfaceRef is toll-free usable as layer contents
    DispatchQueue.main.async { layer.contents = obj }   // CATransaction.setDisableActions(true)
}
```
Keep `sb` retained until the layer swaps (store latest sample buffer) so SCK does not recycle the surface under it. Set `layer.contentsGravity = .resize`, `layer.magnificationFilter/minificationFilter = .linear`, `layer.isOpaque = true`, `layer.drawsAsynchronously = false`. Zero copy, no Metal pipeline, ~0 CPU beyond the callback.
Alternatives: AVSampleBufferDisplayLayer (`enqueue(sb)`) handles timing/HDR/colorspace tagging and is also zero-copy; use `controlTimebase` unset + `displayImmediately` flag for low latency. Choose it if HDR/EDR content matters. Metal only if shaders (filters, crop, rotate) are needed; avoid for MVP.

### Window
```swift
final class PipPanel: NSPanel {
  init(frame: NSRect) {
    super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
               backing: .buffered, defer: false)
    level = .floating                       // .screenSaver to float over fullscreen apps
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false; backgroundColor = .clear; hasShadow = true
    isMovableByWindowBackground = true
    hidesOnDeactivate = false; isReleasedWhenClosed = false
    contentAspectRatio = NSSize(width: 21, height: 9)   // aspect lock; set to source ratio, clear with resizeIncrements trick (set to 0 size to unlock: contentAspectRatio = .zero not allowed; use windowWillResize delegate instead)
    alphaValue = 1.0                        // opacity
  }
  override var canBecomeKey: Bool { false }
  func setClickThrough(_ on: Bool) { ignoresMouseEvents = on }  // toggle via menu/hotkey since a click-through window can't be clicked to un-toggle
}
```
- Aspect lock toggle: implement in `windowWillResize(_:to:)` returning size adjusted to ratio when enabled (cleaner than contentAspectRatio).
- Persist frame as fractions of the screen like BetterDisplay (originX/Y/width/height) plus opacity, display ID (use UUID via `CGDisplayCreateUUIDFromDisplayID`, not the volatile CGDirectDisplayID).
- Pause stream when panel is hidden/occluded (`NSWindow.occlusionState`) and drop to low fps when not visible; stop stream entirely on close.

### Content selection and permissions
- `SCShareableContent.current` + custom menu: no picker UI needed, more control; but triggers the screen-recording TCC prompt.
- `SCContentSharingPicker` (macOS 14+): system picker; user selection grants access for that session with no persistent Screen Recording permission for that selection, and the prompt/re-approval problem is reduced. Needs `configuration.allowedPickerModes`, `SCContentSharingPickerObserver`, `SCStream` created from the returned filter. Downside: user must pick each launch (the filter can't be silently restored), awkward for a menu-bar app's saved PIP.
- macOS 15 (Sequoia) introduced a periodic re-approval alert ("Allow For One Month"/"Open System Settings") for apps using SCK/legacy capture APIs, and the status-bar recording indicator; macOS 26 continues this and the monthly nag text moved into Privacy and Security. Apps using SCContentSharingPicker are exempt from the monthly prompt. Mitigation: use the picker for first-time selection and cache the choice per session; for saved PIPs accept the monthly prompt and show a friendly in-app explanation; keep a stable bundle ID and signing identity (ad-hoc signing makes TCC reset on every rebuild, so sign with a Developer ID / consistent development cert). I did not verify exact behaviour on macOS 27 (training knowledge); test it.
- Check state without prompting: `CGPreflightScreenCaptureAccess()`; request only on user action via `CGRequestScreenCaptureAccess()`.

### How BetterDisplay does it (inferred, not decompiled)
Prefs show a single display-bound PIP (`pip*@Display:3`) with relative frame and alpha, which is consistent with a floating borderless window fed by ScreenCaptureKit of the display; its idle process is 11 threads/91 MB with no stream. It also ships a helper (`BetterDisplayHelper`) and Paddle/Sentry/Sparkle.

### Benchmark probe
`/private/.../research/pip/probe.swift` (compiled `probe`) captures the main display at 960x405@30fps BGRA for 15s headless and prints frames/s and CPU%. Run result: `CGPreflightScreenCaptureAccess()` returned false for this host process, so the benchmark was SKIPPED (no prompt triggered). To run it, grant Screen Recording to the terminal/host app in System Settings, then `./probe`.

### Expected cost (estimates, unmeasured)
BGRA 960x405@30 IOSurface path: ~1-3% of one core in the callback plus WindowServer GPU work; zero when screen static.
