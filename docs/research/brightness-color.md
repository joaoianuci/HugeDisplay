# HugeDisplay research: brightness + color presets (M5, macOS 27.0.1, Swift 6.4)

All probes in this dir are READ-ONLY (no Set*, no VCP write, no gamma/profile change). Run with `swiftc -O X.swift -o X && ./X`. Use `setvbuf(stdout,nil,_IONBF,0)` — a crash otherwise eats all output.

## Machine facts
- CGDirectDisplayID 1 = built-in "Color LCD" (2560x1664 native, 1470x956 HiDPI default, notch, MPDisplay name "Built-in Liquid Retina Display"; BetterDisplay: hasHDR=0, xdrPresetsSupported=0 -> not an XDR panel).
- CGDirectDisplayID 3 = "LG HDR WFHD" (vendor 0x1e6d, product 0x7714, 2560x1080 75Hz, 10bit). ColorSync factory modes are named "HDMI HD"/"HDMI SD" => connected via HDMI. Not mirrored (CGDisplayIsInMirrorSet = false), so IOAVService I2C goes straight to the monitor.
- Display IDs are not stable across reboots/replug: key by CGDisplayCreateUUIDFromDisplayID (built-in 37D8832A-..., LG DF561446-...). BetterDisplay itself also keys by vendor/model + UUID.

## 1. Built-in brightness: DisplayServices (private)
`dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)`. Resolved symbols (all present): DisplayServicesGetBrightness, SetBrightness, CanChangeBrightness, GetLinearBrightness, RegisterForBrightnessChangeNotifications, HasAmbientLightCompensation, AmbientLightCompensationEnabled, EnableAmbientLightCompensation, IsSmartDisplay, GetPowerMode, GetBrightnessIncrement, NeedsBrightnessSmoothing. (`DisplayServicesBrightnessChanged` NOT present on this OS.)

Signatures that worked:
```swift
typealias GetB = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32   // 0 = ok
typealias Pred = @convention(c) (UInt32) -> Bool
let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
let getB = unsafeBitCast(dlsym(ds,"DisplayServicesGetBrightness"), to: GetB.self)
let canB = unsafeBitCast(dlsym(ds,"DisplayServicesCanChangeBrightness"), to: Pred.self)
var v: Float = 0; let rc = getB(1, &v)      // built-in: rc=0, v=0.594 (matches BetterDisplay's stored 0.5941)
// SetBrightness(UInt32, Float) -> Int32 (not called)
```
Measured: built-in GetBrightness rc=0, 0.594, ~0.1-1 ms. CanChangeBrightness(builtin)=true; HasAmbientLightCompensation=true; IsSmartDisplay=true; GetLinearBrightness=0.321.
External (id 3): GetBrightness returns rc=1000 (error), CanChange=false, smart=false -> DisplayServices is built-in only.
RISK: `DisplayServicesAmbientLightCompensationEnabled(builtinID)` with `(UInt32)->Bool` SEGFAULTED (exit 139). Signature differs (likely out-param). Do not call until the signature is verified (disassemble) — and wrap such private calls so a crash cannot take the app down (or skip auto-brightness toggle in v1).
CoreDisplay_Display_GetUserBrightness / GetLinearBrightness (in /System/Library/Frameworks/CoreDisplay.framework) resolve but returned 1.0 for both displays: not reliable as a getter; stick with DisplayServices.
Auto-brightness is on for the built-in: setting brightness works but ambient compensation will keep moving it; BetterDisplay stores "hardwareBrightness-AppleController" (0.594) and "softwareBrightness-ColorController" separately.
Brightness-change notifications: DisplayServicesRegisterForBrightnessChangeNotifications (not exercised) to keep the slider in sync with F1/F2 keys and auto-brightness.

## 2. External brightness: DDC/CI over IOAVService — WORKS on this machine
Private (in IOKit, no extra dlopen needed) — declare with @_silgen_name:
```swift
@_silgen_name("IOAVServiceCreateWithService") func IOAVServiceCreateWithService(_ a: CFAllocator?, _ s: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")  func IOAVServiceReadI2C(_ s: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ n: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C") func IOAVServiceWriteI2C(_ s: CFTypeRef, _ chip: UInt32, _ dataAddr: UInt32, _ buf: UnsafeMutableRawPointer, _ n: UInt32) -> IOReturn
```
Discovery: `IOServiceMatching("DCPAVServiceProxy")` -> property "Location" == "External" (vs "Embedded" = built-in). Found exactly one External + one Embedded here. `AppleCLCD2` matching returned nothing in ioreg on this OS (MonitorControl also matches IOMobileFramebufferShim/AppleCLCD2 only to map service->CGDisplayID by EDID UUID/product/serial score; with 1 external a trivial mapping works, but with 2+ externals port the ioregMatchScore logic from Arm64DDC.swift - copy in ./ref/Arm64DDC.swift).

Protocol (from MonitorControl Arm64DDC.swift; chip addr 0x37, data addr 0x51):
- Get VCP packet = [0x82, 0x01, vcp, chk]; chk = 0x6E ^ xor(first 3 bytes). (single-byte payload => seed is only 0x37<<1; for multi-byte payloads e.g. Set VCP [0x84,0x03,vcp,hi,lo,chk] seed = 0x6E ^ 0x51.) My first attempt with an extra length byte ([0x83,0x02,0x01,vcp]) returned all-zero replies with rc=0 — framing, not hardware, was the cause.
- Write: IOAVServiceWriteI2C(svc, 0x37, 0x51, pkt). Wait. Read: IOAVServiceReadI2C(svc, 0x37, 0, &reply[11]).
- Reply: [0]=0x6E [1]=0x88 [2]=0x02 [3]=result(0 ok, 1 unsupported) [4]=vcp [5]=type [6..7]=max [8..9]=cur [10]=chk; reply chk = 0x50 ^ xor(bytes 0..9).
- MonitorControl defaults: 10 ms before each write, 2 write cycles, 50 ms before read, 20 ms between retries, 4 retries.
Working reference: ./probe_ddc.swift, ./probe_ddc2.swift (getVCP helper).

Results on the LG (via HDMI, BetterDisplay running concurrently):
| VCP | result |
|---|---|
| 0x10 brightness | cur=63 max=100 (BetterDisplay pref says 0.6268 = same) |
| 0x12 contrast | cur=70 max=100 |
| 0x14 color preset | cur=11 (0x0B = "User 1") max=11 |
| 0xDC display mode | UNSUPPORTED (reply result=01) |
| 0x16/18/1A RGB gain | 50/50/50 of 100 |
| 0x60 input | cur=0 max=18 (value looks odd; don't rely on it) |
| 0x62 volume | 99 of 100 |
| 0xD6 power | 1 of 5 |
| 0x87 sharpness | 50 of 100 |
| 0xDF VCP version | 0x0201 (2.1) |
| 0x72 gamma, 0x8A saturation | unsupported |
Latency (full read incl. sleeps):
- default (10 ms / 50 ms, x2 write): median ~88 ms; 3/8 failed once under that profile (first reads), first 5-try run needed 1 attempt each.
- 10/50 ms x1 write: median 73.9 ms, 30/30 ok.
- 3/25 ms x1 write: median 39.9 ms, 30/30 ok.
- 2/20 ms x1: median 34.5 ms, 0/8 failures. 5/30 x1: 47.5 ms, 0/8 failures.
So the monitor answers within ~25 ms; sleeps dominate. Writes (not tested) don't need the read sleep. DDC calls block the thread (usleep + syscalls into DCP) -> must run on a dedicated serial queue/actor, coalesce slider drags (e.g. send latest value at <=10-15 Hz), never on main.
BetterDisplay also does DDC on this display ("hardwareBrightness-DDCController@Display:3", "volume-DDCController"), so both apps would poll the same I2C bus; occasional failures are probably contention. Always wrap in retry (2-4) and treat failure as "unavailable right now".
Caveat: EDID over I2C also readable (IOAVServiceReadI2C(svc,0x50,0,..,128)): LG vendor bytes 1e 6d 14 77 -> I2C path is healthy.
DDC caveats for other setups: some LG/other HDMI ports or docks do not answer; DDC/CI can be disabled in the OSD; built-in display has no DDC (Embedded service must be skipped); virtual mirror/dummy displays (BetterDisplay virtual screens) have no DDC.

## 3. Software fallback dimming (document only, nothing applied)
- Gamma: `CGSetDisplayTransferByFormula(id, rMin,rMax,rGamma, gMin,gMax,gGamma, bMin,bMax,bGamma)` / `CGSetDisplayTransferByTable(id, n, r,g,b)` (CGGammaValue = Float). Read current: `CGGetDisplayTransferByTable` (probe_color.swift: both displays are currently identity: r[128]=0.502, r[255]=1.0).
  - Pros: no window, works on any display incl. when DDC fails, per-display, also gives per-channel color tint.
  - Cons: process-owned: CGDisplayRestoreColorSyncSettings() or app quit/crash resets to ColorSync profile; reapply on display reconfiguration / wake (CGDisplayRegisterReconfigurationCallback, NSWorkspace.didWakeNotification). Conflicts: Night Shift / True Tone / f.lux-style tools and BetterDisplay's own gamma ("allowColorManipulation@Display:3"=1, "value@softwareBrightness-ColorController"=1) fight over the same table (last writer wins) -> don't run alongside BetterDisplay software brightness. Reduces effective bit depth when dimming (banding on 8-bit paths); on HDR/EDR content gamma is bypassed or ignored. Night Shift on Apple Silicon is applied in a separate stage (CoreBrightness), so mixed behaviour is possible but not guaranteed.
- Overlay: borderless NSWindow level >= .screenSaver / CGShieldingWindowLevel, ignoresMouseEvents, collectionBehavior [.canJoinAllSpaces,.stationary,.fullScreenAuxiliary], black with alpha = 1-brightness, one per NSScreen. Pros: no table conflicts, trivial, trusted. Cons: screenshots/recordings show/exclude it inconsistently, doesn't dim HDR highlights, might get covered by fullscreen apps/menu bar unless level is high, cursor/notch edge cases, extra compositing. Overlay can't make screen brighter than hardware; gamma neither.
- Recommendation: hardware first (DisplayServices / DDC); gamma-table dimming as "software extra dim" fallback for displays without DDC (store the user's choice, restore on quit with CGDisplayRestoreColorSyncSettings); overlay only as optional second fallback.

## 4. Color presets: what BetterDisplay offers and what can be done
BetterDisplay prefs (domain pro.betterdisplay.BetterDisplay; license fields skipped) show features in use / present per display:
- Color profile per display ("colorProfilesSupported", "currentColorProfileURL@Display:N", "factoryColorProfileURL@Display:N"). Built-in: current = factory Color LCD-37D8832A...icc. LG: current = /System/Library/ColorSync/Profiles/sRGB Profile.icc, factory = /Library/ColorSync/Profiles/Displays/LG HDR WFHD-DF561446-...icc. => user switched the LG to the generic sRGB profile (ColorSync custom profile).
- Color/gamma table (colorTableCapable=1), software brightness, quantization, saturation, contrast (software "contrast-ColorController"), filters (sepia, comic, XRay, thermal, vibrance, median: all 0/off), "blueLight-EnvironmentController" 0.5 (Night Shift-like), color mode (menuLevelColorMode), XDR preset menu (xdrPresetsSupported=0 for both -> N/A), HDR (hasHDR=0, configuredPotentialEDR/ReferenceEDR present), DDC: hardware brightness + volume ("value@hardwareBrightness-DDCController@Display:3"=0.627, "volume-DDCController"), "combinedBrightness-CombinedController" (hardware + software brightness merged into one slider: 0.690 built-in, 0.813 LG), restoreFramebufferSettingEnableDithering@Display:3, PIP, mirroring, resolution/refresh menus. No DDC input switch or color-preset values are stored (menuLevelDDCInput exists but unset).
- Menu items all "unset" (default); nothing hidden/pinned.

Probes (probe_builtin.swift, probe_color.swift, probe_mp.swift):
- Current profile per display, read-only: `ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass, uuidCF)` -> dict with FactoryProfiles{modeID:{DeviceModeDescription,DeviceProfileURL}, "DeviceDefaultProfileID"} and CustomProfiles{modeID:URL} (key present only if user overrode). Built-in: factory "1" = Color LCD...icc, no custom. LG: modes "HDMI HD" (factory LG icc, default) and "HDMI SD" (SD 170M-A.icc), CustomProfiles["HDMI HD"] = sRGB Profile.icc. Effective profile = custom if present for the active mode else factory. Quick path: `CGDisplayCopyColorSpace(id).name` -> kCGColorSpaceSRGB for LG, unnamed for built-in (wide-gamut custom ICC).
- Setting (NOT done): `ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass, uuid, [modeID: URL] as CFDictionary)` (public API; passing the factory URL / removing key restores). Persistent across app exit (stored by ColorSync), unlike gamma. Might need a `CFDictionary` with `kColorSyncDeviceDefaultProfileID` key for the default mode.
- Available display-profile candidates for a picker: /System/Library/ColorSync/Profiles (sRGB, Display P3, AdobeRGB1998, DCI(P3) RGB, ITU-709/2020, ACESCG Linear, ROMM RGB, Generic Gray/RGB...), /Library/ColorSync/Profiles (+ Displays/ factory ones: Color LCD, two LG HDR WFHD UUIDs — the 2nd UUID FD0AF9BF... is an old/other connection of the LG or a mirror/dummy), ~/Library/ColorSync/Profiles (doesn't exist). ColorSyncIterateInstalledProfiles callback in my probe returned 0 items (Swift closure/ctx issue) — enumerate by directory scan + ColorSyncProfileCreateWithURL + ColorSyncProfileCopyDescriptionString instead.
- DDC color preset VCP 0x14: LG reports current 0x0B (User 1), max 11. Standard values: 0x01 sRGB, 0x02 Native, 0x03 4000K, 0x04 5000K, 0x05 6500K, 0x06 7500K, 0x07 8200K, 0x08 9300K, 0x09 10000K, 0x0A 11500K, 0x0B User1, 0x0C User2, 0x0D User3. A real list of allowed values needs the capabilities string (VCP code E3/ get capabilities; not queried). Writing it changes the monitor's own OSD preset: do per-user opt-in only. RGB gains 0x16/18/1A (50/100 now) are the user-preset fine tuning. 0xDC unsupported on this LG.
- Built-in reference presets: private `MonitorPanel.framework` -> MPDisplayMgr.displays -> MPDisplay has `hasPresets`, `presets`, `activePreset`, `defaultPreset`, `buildPresetsList`, `setActivePreset:` (only resolved, never called). On this Mac: hasPresets=0, presets=nil, activePreset=nil for BOTH displays => this built-in panel (non-XDR MacBook Air-class Liquid Retina) has no reference modes. Consistent with BetterDisplay xdrPresetsSupported=0. On MBP XDR machines the same MPDisplay API would give the "Apple Display" presets list (HDR Video, Photography, ...). CoreDisplay_Display_CopyColorMode/GetCurrentPreset symbols do not exist here.
- CoreBrightness (private) classes resolved: CBBlueLightClient (getBlueLightStatus:, setEnabled:, getCCT:, setStrength...), CBTrueToneClient (enabled/setEnabled:/mode), CBAdaptationClient. CBColorModeClient does not exist. Not queried; useful if HugeDisplay later wants Night Shift/True Tone toggles.

## 5. Recommended approach per display type
- Built-in (Embedded, Apple): DisplayServicesGet/SetBrightness (+ register change notification), Float 0-1. Optional gamma for extra-dim below minimum. Color: ColorSync custom-profile list (all of /System/Library/ColorSync/Profiles/Display P3, sRGB, etc. + factory). Skip XDR presets (hasPresets=0 here; keep MPDisplay-based UI hidden unless `hasPresets`).
- External with DDC (this LG over HDMI): DDC VCP 0x10 (+0x12 contrast, 0x14/16/18/1A color if desired) via IOAVService. Use 5/30 ms x1 write profile, retry up to 3, serial queue + coalescing. Poll rarely; read on popover open. Gamma dimming for >0 range below hardware min is optional.
- External without working DDC / virtual / mirrored: gamma-table software brightness, fallback overlay.
- Color preset = (a) ColorSync profile switch per display (primary; persistent, public API) and (b) optional DDC 0x14 for monitors supporting it. Show "reference preset" UI only if MPDisplay.hasPresets.

## 6. Risks / open items
1. Private APIs can change in macOS 27.x betas: dlsym-guard everything, feature-flag off if a symbol is nil. DisplayServicesAmbientLightCompensationEnabled crashes with the guessed signature.
2. DDC is slow (35-90 ms) and contends with BetterDisplay on the shared I2C bus; run only one app's DDC; failures observed under heavier sleep profile.
3. IOAVService<->CGDisplayID mapping: trivial for one external; for several needs EDID UUID/IODisplayLocation scoring (see ref/Arm64DDC.swift ioregMatchScore).
4. Gamma changes are lost on quit and collide with Night Shift/BetterDisplay; must restore with CGDisplayRestoreColorSyncSettings().
5. DDC writes to color presets (0x14) and OSD-affecting values are unverified here (read-only run); some LGs store them in NVRAM with write-limits; rate-limit writes.
6. VCP 0x60 input value read was 0 for an HDMI-connected LG (odd): do not build input switching on it without checking the capabilities string.
7. I did not read the monitor capabilities string (VCP list) — needed for valid 0x14 values; DDC "Get capabilities" is a multi-fragment I2C command (opcode 0xF3).
