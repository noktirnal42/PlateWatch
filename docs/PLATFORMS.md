# PLATFORMS.md — where PlateWatch runs, and how we test it without the hardware

Last reviewed 2026-10-29. The maintainer owns Apple hardware only. Every claim
below separates *implemented* from *verified*, and names how each non-Apple
target is verified.

## The real blocker: every model is CoreML

`models/registry.json` ships `.mlmodel`/`.aar` CoreML artifacts. Nothing outside
Apple silicon can run them. Until the on-device pipeline has an ONNX (desktop,
Linux, Android) and TFLite or ONNX Runtime Mobile (Android, Wear OS) path, a
non-Apple client can only consume the server. The conversion work, licences and
benchmarks belong to WS3 and must be recorded in the registry before any
platform claims local detection (AGENTS.md guardrail 5).

## Status

| Platform | State | What exists | Verified how |
|---|---|---|---|
| macOS (Hub) | working | `apps/macos-hub` | local, CI (`macos-26`) |
| iPhone | field QA open | `apps/ios` | simulator, device install; handheld QA open |
| Apple Watch | device gate | `apps/watchos` | installed on hardware; push untested |
| CarPlay | blocked | none | needs Apple entitlement and a vehicle |
| iPad / Mac Catalyst | unverified | iOS target builds | not exercised on an iPad layout |
| visionOS, tvOS | not planned | — | no use case yet |
| Linux server / Docker | implemented | `server/Dockerfile`, Vapor | `cross-platform.yml` (experimental) |
| Linux, Pi, Jetson edge | reference | `tools/python-edge-agent` | unit tests on Linux, Windows, macOS runners |
| Web | reference | read-only explorer | browser |
| Android phone | read-only | `apps/android` (Java, REST consumer) | `assembleDebug` on a Linux runner (experimental) |
| Windows | not started | none | planned |
| Wear OS | not started | none | planned |
| Android Auto | not started | none | planned |

## Platforms we may be missing

- **Windows desktop Hub equivalent** (feed browsing, Live, review). Most
  likely path: a cross-platform shell over the Python/ONNX runtime, or a web
  UI served by a local agent. Needs a decision; see below.
- **Linux desktop** — the same client as Windows, plus the headless edge box.
- **Android phone capture** — CameraX plus an ONNX or TFLite detector.
- **Wear OS** — notification-only companion to the phone, like the watchOS app.
- **Android Auto** — the CarPlay equivalent; also blocked by a review process.
- **Progressive web app** — installable read-only explorer; cheapest wide reach.
- **iPadOS** — first-class layout; the iOS target already builds.
- **Dashcams and fixed edge boxes** — Raspberry Pi 5, NVIDIA Jetson, Coral. The
  Python agent is the seed.
- **Browser-only demo** — WebAssembly or WebGPU detector for judging the
  pipeline without installing anything. Nice to have; never uploads frames.

## Testing without the hardware

| Target | Method | Cost | Limits |
|---|---|---|---|
| Linux x64 / arm64 | GitHub Actions `ubuntu-latest`, `ubuntu-24.04-arm` | free for public repos | no camera |
| Windows | Actions `windows-latest`; Windows 11 ARM in UTM on the Apple Silicon Mac | free | no camera; ARM only locally |
| Linux locally | UTM or Docker Desktop on the Mac (arm64 Ubuntu) | free | arm64 only |
| Android phone | Android Studio emulator locally; `reactivecircus/android-emulator-runner` on Linux runners | free | no real camera or thermals |
| Wear OS | Android Studio Wear emulator | free | no real sensors or push |
| Raspberry Pi | QEMU for logic; community hardware for the camera path | free | real camera needs a person with a Pi |
| Real-device matrix | Firebase Test Lab free tier, BrowserStack open-source programme | free tier | limited minutes |

What emulation cannot prove: camera quality, low-light and thermal behaviour,
battery use, push delivery. Those stay labelled "device gate" until a community
tester reports them.

## Community testing

- Issue templates per platform ask for OS version, hardware, what ran and what
  broke. Reports without those fields are hard to act on.
- Prerelease builds (Android debug APK, edge agent tarball, Docker image) are
  attached to GitHub Releases so testers need no toolchain.
- A tester never receives credentials. They test against synthetic data or a
  local server; camera sources stay behind the terms and robots checks.

## Order of work

1. **Now:** `cross-platform.yml` keeps the Python tools green on Linux, Windows
   and macOS and records whether the Android build and Linux server build work.
2. **WS3:** convert the plate and vehicle detectors to ONNX, record licences
   and a benchmark in the registry, add a runtime-agnostic eval harness.
3. **Linux edge:** run the ONNX detectors in the Python agent on a Pi, with
   the same fail-closed fleet and media policy the Apple apps use.
4. **Android capture** and Wear OS on top of the same ONNX models.
5. **Windows and Linux desktop** once a client stack is chosen.

## Decision needed

Windows and Linux desktop need one client stack. Options: a native stack per
OS, a cross-platform shell (Tauri or Qt) sharing a Rust or Python core, or a
local web UI served by the edge agent. The last has the smallest maintenance
surface for a one-person project and matches the existing Python agent, but it
gives a lesser Live experience than the Hub. Record the choice in DECISIONS.md
before any Windows work starts.
