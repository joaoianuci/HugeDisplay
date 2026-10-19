# HugeDisplay

A free, tiny macOS menu-bar app for the display controls you actually use:

- **Turn any display on/off** — external or built-in, without unplugging.
- **Resolution & refresh rate** per display, including HiDPI modes, with a 15 s "Keep / Revert" safety prompt.
- **Brightness** per display — built-in panel natively, external monitors over **DDC/CI**, software dimming as fallback.
- **Color profile** switching per display (ColorSync).
- **Picture-in-Picture** of a whole display in a floating, resizable window (opacity, click-through).
- Launch at login.

No accounts, no license, no telemetry, no updater frameworks, no polling.

| Idle, measured on an M5 | HugeDisplay |
|---|---|
| CPU | ~0.0 % |
| Memory | ~18 MB |
| Threads | 3–6 |
| App size | ~1.2 MB |

## Requirements

- macOS 15 or later, **Apple Silicon** (DDC brightness uses the Apple Silicon I²C path).
- Xcode 16+ / Swift 6 toolchain to build.

## Download

Grab the latest `HugeDisplay-vX.Y.Z.zip` from the [Releases page](https://github.com/joaoianuci/HugeDisplay/releases/latest),
unzip it and drag `HugeDisplay.app` to `/Applications`.

> **The build is ad-hoc signed and not notarized.** There is no paid Apple Developer ID behind it yet, so
> Gatekeeper will say the app "can't be opened" the first time. You only need to get past it once:
>
> - **Right-click** (or Control-click) `HugeDisplay.app` → **Open** → **Open**; or
> - on recent macOS, try to open it once, then go to **System Settings → Privacy & Security** and click
>   **Open Anyway**; or
> - remove the quarantine flag from Terminal:
>   ```bash
>   xattr -dr com.apple.quarantine /Applications/HugeDisplay.app
>   ```
>
> You can verify the download against the `.sha256` file attached to the release, or build it yourself (below).

**Roadmap:** releases will move to a Developer ID signature plus Apple notarization, which removes the
first-launch warning. Until then, ad-hoc builds are the only option; since the signature identity changes
between versions, macOS may ask you to re-grant Screen Recording (used only by PIP) after an update.

## Build & install

```bash
git clone https://github.com/joaoianuci/HugeDisplay.git
cd HugeDisplay
scripts/build-app.sh
cp -R build/HugeDisplay.app /Applications/
open /Applications/HugeDisplay.app
```

The build is ad-hoc signed. To keep the Screen Recording permission (needed only for PIP) across rebuilds,
sign with your own identity: `SIGN_IDENTITY="Apple Development: you@example.com" scripts/build-app.sh`.

Run the tests with `swift test`.

## Safety notes

Turning displays on/off and DDC use **private macOS APIs** (SkyLight, DisplayServices, IOAVService). Every
symbol is resolved at runtime; if Apple removes one, that feature hides itself instead of crashing.

- HugeDisplay never lets you turn off your last usable display.
- Displays it turned off are re-enabled when you quit the app, when it is relaunched after a crash, and
  automatically if no usable display is left (e.g. you unplug the external while the built-in is off).
- A reboot always brings every display back.

If something ever goes wrong while a display is off, relaunching HugeDisplay restores it.

## Project layout

```
Sources/HugeDisplay/        SwiftUI menu-bar app (UI + wiring)
Sources/HugeDisplayCore/    Displays, Modes, Toggle, Brightness (DDC), Color, PIP, Support
Tests/HugeDisplayCoreTests/ Unit tests for the pure logic
docs/research/              Notes from probing the APIs on real hardware
PLAN.md                     Roadmap and architecture
```

## License

MIT — see [LICENSE](LICENSE). Not affiliated with BetterDisplay or Apple.
