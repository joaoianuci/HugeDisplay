# HugeDisplay: display modes + enable/disable (findings)

Probes: enum.swift (enumeration, dlsym), objc.swift (CGVirtualDisplay class check). All read-only. Nothing was called that changes config.

## Confirmed on this machine (macOS 27.0.1, M5)
- Online == active == [3, 1]. Display 3 = LG HDR WFHD (vendor 7789=0x1E6D, model 30484, builtin=0, main, unit 2, bounds 2560x1080 at 0,0, 797x340mm). Display 1 = Color LCD (vendor 1552=0x610, model 41059, builtin=1, bounds -1470,0 1470x956).
- No mirroring (CGDisplayIsInMirrorSet=0, MirrorsDisplay=0) and NO virtual display present (only 2 online). BetterDisplay prefs: systemVirtual=0, thirdPartyVirtual=0, virtualScreenLinked=0 for both. So the "HiDPI 5120x2160" is NOT a virtual display / mirror.
- The LG HiDPI mode is a mode the OS itself lists: `2560x1080 px5120x2160 HiDPI 75Hz, ioModeID=75, ioFlags=0x200003`, and 1280x540 px2560x1080 HiDPI (ids 12/14/16, flags 0x2000003). BetterDisplay pref `smoothScaling@v7789m30484 = 1` ("smooth scaling") is enabled; the override dir /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-1e6d exists but is EMPTY. So HiDPI here comes from the system's flexible/"smooth" scaling modes (BetterDisplay toggles it; mechanism unknown, not an override plist now). Mode id 48 (2560x1080 1x 75Hz, flags 0x2000007) is the native/default (BetterDisplay: nativeModeNumber=48, defaultModeNumber=48).
- Enumeration cost: CGDisplayCopyAllDisplayModes with kCGDisplayShowDuplicateLowResolutionModes: LG 91 modes in 0.10 ms; built-in 14 modes in 0.03 ms. Without the option: ~0.05 ms. Negligible, safe to call on every menu open.
- Option key `kCGDisplayShowDuplicateLowResolutionModes` adds ~40 extra entries for LG, all gui=false (isUsableForDesktopGUI false, ioFlags 0x1, low-res 400x300 etc., duplicates). Filter on `isUsableForDesktopGUI()` for the UI list. Without the option you get the modes the System Settings shows (usable ones; the 1x/HiDPI "duplicates" at same logical size are flagged by pixelWidth).
- HiDPI test: `mode.pixelWidth > mode.width`. Refresh `mode.refreshRate` (75/60/50 for LG). Distinct modes share width/height, so identity = `ioDisplayModeID` (stable within a session; BetterDisplay stores it as modeNumber) — better to match by (w,h,pixelW,pixelH,refresh) when persisting.
- Built-in modes (HiDPI): 960x600 ... 1470x956 (current, id 6, flags 0x7=default), 1710x1112; 1x modes up to 2560x1664 (id 13 native, flags 0x2000003).
- BetterDisplay's own IDs: persistedDisplayID@Display:2=1, @Display:3=3 -> CGDirectDisplayIDs are stable here (1, 3). BetterDisplay stores per-display prefs keyed by "v<vendor>m<model>" (e.g. v7789m30484).
- User-configured BetterDisplay features visible in prefs: smooth scaling on LG; PIP (display 3 PIP window); mode menu filters (21:9, 75Hz, 10bit, LoDPI/HiDPI); software brightness + DDC hardware brightness/volume (DDCController) on LG; combined brightness; contrast/saturation filter controllers; "dithering"; color profile switching (current sRGB for LG); config protection; no manual resolutions (manualResolutions=0, list empty); no virtual screens; no mirror; menu-bar rows (resolution, refresh rate, mirror, rotation, disconnect, ...) default.
- dlsym (RTLD_DEFAULT): CGSConfigureDisplayEnabled, SLSConfigureDisplayEnabled, CGSGetDisplayList, SLSGetDisplayList, SLSGetActiveDisplayList, SLSGetOnlineDisplayList, CGSGetOnlineDisplayList, CGSServiceForDisplayNumber all RESOLVE. dyld_info on SkyLight exports `_SLSConfigureDisplayEnabled @0x198F60`, plus _SLSConfigureDisplayMode/Origin/Resolution/MirrorOfDisplay/Mirrored/FadeEffect. (CGS* names are present too, resolve through CoreGraphics/SkyLight re-exports; nm -gU printed nothing because of dyld shared cache, use dyld_info.) Not called.
- Private classes exist on this OS: CGVirtualDisplay (initWithDescriptor:, applySettings:, displayID, hiDPI, modes, vendorID, productID, serialNum, name, sizeInMillimeters, maxPixelsWide/High, terminationHandler, queue, rotation, whitePoint, primaries), CGVirtualDisplayDescriptor (setName:, setVendorID:, setProductID:, setSerialNum:, setMaxPixelsWide:/High:, setSizeInMillimeters:, setQueue:, setTerminationHandler:, setRedPrimary: ..., setWhitePoint:), CGVirtualDisplaySettings (setHiDPI:, setModes:, setRotation:, setRefreshDeadline:, setIsReference:), CGVirtualDisplayMode (initWithWidth:height:refreshRate:, ...transferFunction:). `CGDisplayIsVirtualDevice` does NOT exist; detect virtual by IOKit/vendor (virtual displays from CGVirtualDisplay carry the vendorID you set; BetterDisplay's use its own) or by `CGDisplayVendorNumber == 0xF0F0/0x0` and no builtin EDID; also name via CGDisplayCreateUUIDFromDisplayID + IORegistry (IODisplayConnect absent).

## Enable/disable (from docs/open source; NOT executed)
Signature (resolve via dlsym; no headers):
```swift
typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /*RTLD_DEFAULT*/, "CGSConfigureDisplayEnabled") // or "SLSConfigureDisplayEnabled"
let fn = unsafeBitCast(sym, to: ConfigureEnabled.self)
var cfg: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&cfg)
let e = fn(cfg, id, false)               // false = disable, true = enable
CGCompleteDisplayConfiguration(cfg, .forSession)   // or .forAppOnly
```
- Used by clamOpen, ScreenOff, MacMonitorUtils, macDisplayCtl, InternalDisplayOff, better-osd PR #22, FBD, etc. (found via web search). All wrap it in Begin/Complete configuration. ForAppOnly reverts when process dies (safer); ForSession persists until logout/reboot.
- Re-enable: same call with true, using the SAME CGDirectDisplayID. After disable the display is dropped from the active list (CGGetActiveDisplayList) but stays in CGGetOnlineDisplayList, so ID and CGDisplayIsOnline remain valid -> that is how you re-enable. Cache the id (and UUID via CGDisplayCreateUUIDFromDisplayID) before disabling; on reboot/replug IDs may change, so key by UUID/vendor+model+serial. Note: for displays that were fully soft-disconnected (Apple Silicon) online list may also lose them; BetterDisplay keeps "persistedDisplayID". Unverified here.
- Caveats from projects: some M3 base built-in displays can need a restart/lid cycle to recover; virtual/third-party displays may not reconnect; Apple may change the symbol (guard with dlsym nil check, fail safe). Apple Silicon has a deeper soft-disconnect path (release framebuffer) used by BetterDisplay "Disconnect"; mechanism not confirmed.
- Safety to implement: (1) refuse if activeDisplayCount <= 1 or target is the only active display; (2) refuse disabling built-in unless an external is active (and has been for N seconds); (3) default to .forAppOnly/forSession, never .permanently; (4) auto-revert timer (e.g. 15 s confirm sheet like System Settings; on no confirm call enable(true)); (5) re-enable all disabled IDs on app quit/SIGTERM/atexit and on launch (persist disabled IDs in UserDefaults), plus CGDisplayRegisterReconfigurationCallback to detect external unplug -> re-enable internal automatically; (6) verify via CGGetActiveDisplayList afterwards.

## Set mode (public APIs, standard)
```swift
func setMode(_ id: CGDirectDisplayID, _ mode: CGDisplayMode, permanent: Bool=false) -> CGError {
  var cfg: CGDisplayConfigRef?
  guard CGBeginDisplayConfiguration(&cfg) == .success else { return .failure }
  CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
  return CGCompleteDisplayConfiguration(cfg, permanent ? .permanently : .forSession)
}
```
- forSession persists until logout; .permanently saves to the user's prefs (what System Settings does). forAppOnly reverts on app exit. Use CGCancelDisplayConfiguration on failure. Modes must come from CGDisplayCopyAllDisplayModes (with the duplicate option to include all variants of same size, e.g. 60 vs 75 Hz). Setting a HiDPI mode just means picking one with pixelWidth > width. Mode change takes ~hundreds of ms and flashes; run off main thread is fine but completion is synchronous.
- Mirroring public API: CGConfigureDisplayMirrorOfDisplay(cfg, slave, master).

## Unlock HiDPI on non-Retina (needed only if system doesn't list the mode)
On this machine the OS already lists 5120x2160 HiDPI for the LG, so the virtual display path is NOT required for the current user's setup (at least while smooth scaling stays enabled; what exactly enabled it is unknown, possibly BetterDisplay's helper/pref or a system flexible-scaling feature; verify by quitting BetterDisplay and re-enumerating — not done because user is working). Fallback (pasky/hidpi-mirror, sammcj/force-hidpi, vdisplay, MacRumors thread): create a virtual display whose preferred mode is 2x desired, hardware-mirror the physical display to it.
```swift
// ObjC runtime (no headers); use a bridging header declaring the interfaces, or perform via NSClassFromString + KVC/perform.
let desc = CGVirtualDisplayDescriptor()
desc.setDispatchQueue(.main); desc.name = "HugeDisplay 2560x1080"
desc.maxPixelsWide = 5120; desc.maxPixelsHigh = 2160
desc.sizeInMillimeters = CGSize(width: 798, height: 341)
desc.vendorID = 0x1234; desc.productID = 0x0001; desc.serialNum = 1
desc.terminationHandler = { _, _ in }
let vd = CGVirtualDisplay(descriptor: desc)       // vd.displayID
let s = CGVirtualDisplaySettings(); s.hiDPI = 1
s.modes = [CGVirtualDisplayMode(width: 5120, height: 2160, refreshRate: 75)]   // preferred mode FIRST
vd.applySettings(s)
// then:
var cfg: CGDisplayConfigRef?; CGBeginDisplayConfiguration(&cfg)
CGConfigureDisplayMirrorOfDisplay(cfg, physicalID, vd.displayID)  // physical mirrors the virtual
CGCompleteDisplayConfiguration(cfg, .forSession)
```
- Virtual display lives only as long as the CGVirtualDisplay object is retained (keep it in a long-lived property); destroying it removes it, so un-mirror first. Programmatic mode changes on virtual displays are reported flaky; list the desired mode first. Risks: private API, display sleep issues, extra GPU cost (scaling), HDR/DDC/brightness don't pass through to the mirrored physical display, app is needed running to keep it alive (or a login helper).
- Swift: needs an Objective-C bridging header declaring @interface CGVirtualDisplayDescriptor etc. (copy from hidpi-mirror) since the types are unexposed.

## Risks / open items
- Private symbol drift on macOS 27: guard dlsym, feature-flag disable.
- Not verified here (would need mutating config): that CGSConfigureDisplayEnabled works on M5/macOS 27, how disabled displays appear in online/active lists, and what enables the system 5120x2160 mode.
- App should call CGDisplayRegisterReconfigurationCallback to refresh UI.
- Sources: github.com/mesat/clamOpen, GevorgSogomonian/ScreenOff, nhuphucnguyen/MacMonitorUtils, FisiFla/FBD issue 1 (M3 recovery), pasky/hidpi-mirror, sammcj/force-hidpi, pacifistazero/vdisplay, smcleod.net 2026/03 M4/M5 HiDPI limitation.
