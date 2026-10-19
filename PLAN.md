# HugeDisplay — Plan

Free, lean macOS menu-bar app covering the slice of BetterDisplay actually used here:
display on/off toggle, per-display resolution + refresh rate, brightness, color presets, and PIP.
No licensing, no updater/analytics frameworks, no polling.

## Baseline to beat (BetterDisplay, measured 2026-10-19, idle, 60 s)

| Metric | BetterDisplay | HugeDisplay target |
|---|---|---|
| CPU idle | ~0.03 % avg, 0.2 % peak | < 0.03 % avg |
| Memory | 91 MB (122 MB RSS) | < 40 MB |
| Threads | 11 | ≤ 6 |
| Idle wakeups | ~0.5 /s | < 0.1 /s |
| Bundle | 77 MB (Paddle, Sentry, Sparkle, helper) | < 5 MB |
| PIP capture | not measured | measure; zero-copy IOSurface path |

Details: [docs/research/pip-baseline.md](docs/research/pip-baseline.md).

## Machine facts (from research)

- Apple M5, macOS 27.0.1, Swift 6.4. Displays: built-in Color LCD (id 1) + LG HDR WFHD 2560x1080 (id 3, main).
- LG HiDPI 5120x2160 mode is offered by the OS itself (ioModeID 75) → no virtual display needed for the beta.
- Mode enumeration ≈ 0.1 ms → enumerate on demand, no caching layer needed.
- `CGSConfigureDisplayEnabled` / `SLSConfigureDisplayEnabled` resolve on this OS (calling untested).
- Details: [docs/research/modes-toggle.md](docs/research/modes-toggle.md), [docs/research/brightness-color.md](docs/research/brightness-color.md).

## Architecture

```
HugeDisplay (app target, SwiftUI MenuBarExtra)
 └─ AppModel ── wires services, owns lifecycle (restore on quit/crash)
HugeDisplayCore (library)
 ├─ Displays/   Display model, DisplayManager (event-driven via CGDisplayReconfigurationCallback), service protocols
 ├─ Modes/      resolution + refresh (public CG APIs)
 ├─ Toggle/     enable/disable (SkyLight private API, dlsym) + safety/recovery
 ├─ Brightness/ DisplayServices (built-in), DDC/CI over IOAVService (external), gamma fallback
 ├─ Color/      ColorSync profile per display (+ DDC color preset when available)
 ├─ PIP/        ScreenCaptureKit → IOSurface → CALayer in a floating NSPanel
 └─ Support/    PrivateSymbol (dlopen/dlsym; missing symbol = feature hidden, never a crash)
```

Each module implements one protocol in `Displays/Services.swift`, so modules are built in parallel
and in isolation (one git worktree per module), then merged.

## Features

### Beta (v0.1) — the fast, high-value cut
1. **Display on/off toggle** (main feature). Safety: never disable the last active display; restore all on quit/SIGTERM/next launch after crash; auto-re-enable built-in if the external disappears.
2. **Resolution + refresh rate** per display, with HiDPI/native markers, applied permanently.
3. **Brightness** per display: built-in via DisplayServices, LG via DDC (throttled writes), software fallback.
4. **Color profile** switching per display (ColorSync).
5. **PIP** of a display in a floating, resizable, aspect-locked panel (opacity, click-through), restored on launch.
6. Launch at login (SMAppService).

### v0.2
- Global hotkeys (toggle display, brightness up/down) and media keys routed to DDC for the external.
- DDC volume + contrast; combined brightness (one slider drives all displays).
- Night-shift-like warmth / blue light via gamma (user had blue light 0.5 configured).
- Mode menu filters (21:9, refresh, HiDPI only) mirroring the user's BetterDisplay setup.

### v0.3+
- HiDPI unlock for non-Retina displays via `CGVirtualDisplay` mirroring (only if needed; costs DDC passthrough + GPU).
- PIP of a single window / region; PIP of a virtual display.
- Profiles ("Desk", "Laptop only") that apply toggle + mode + brightness at once; auto-apply on connect.
- Developer ID signing + notarization (also keeps the Screen Recording grant stable across updates).

## Parallel execution plan

| Lane | Work | Depends on |
|---|---|---|
| R1 | Research: modes + toggle | — |
| R2 | Research: brightness + color | — |
| R3 | Research: PIP + BetterDisplay baseline | — |
| S | Scaffold, contracts, build script | — (runs during R1–R3) |
| M | Modes module | S, R1 |
| T | Toggle module | S, R1 |
| P | PIP module | S, R3 |
| U | Menu-bar UI (codes against protocols only) | S |
| B | Brightness + Color modules | S, R2 |
| I | Integrate, wire lifecycle, build .app | M, T, P, U, B |
| V | Opus review + fixes; metric run vs baseline | I |

Implementers: Sonnet sub-agents in isolated worktrees, one module each, touching only their folder.
Reviewers: Opus (medium; low for micro changes).

## Risks

- Private APIs (SkyLight toggle, DisplayServices, IOAVService DDC) can change per macOS release → every symbol is resolved with dlsym and the feature is hidden if missing.
- Disabling the built-in on Apple Silicon has field reports of needing a restart to recover → restore-on-quit, crash recovery, and never disabling the last display.
- Screen Recording permission is reset by ad-hoc re-signing on each rebuild → sign with a stable identity for daily use.
- DDC may fail on some LG inputs/ports → software dimming fallback.

## Manual test checklist (beta)

- [ ] Toggle LG off/on; toggle built-in off/on with LG connected; unplug LG while built-in is off → built-in returns.
- [ ] Quit app with a display disabled → display comes back.
- [ ] Switch LG between 2560x1080 HiDPI/LoDPI and 75/60 Hz.
- [ ] Brightness sliders on both displays.
- [ ] Switch color profile on each display.
- [ ] PIP of LG on built-in: resize, opacity, click-through, relaunch restores it.
- [ ] Measure idle CPU / RSS / threads / wakeups for 60 s vs. baseline table.
