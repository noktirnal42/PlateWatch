# HARDWARE.md — camera guide for public-fleet ALPR

Scope note: this guide targets **documenting vehicles on public roads from
public vantage points**. Follow local law and venue rules.

## Physics that matter more than brand

1. **Pixels on plate.** A US plate is ~30 cm wide. Reliable OCR wants
   ≥ 80–100 px of plate width; ~250+ px for confident fleet-marking reads.
   That is the single biggest determinant of model accuracy.
2. **Shutter speed.** A car at 50 km/h crosses ~14 mm/ms. Freeze motion with
   ≥ 1/500 s; 1/1000 s+ for highway. This drives your lighting/IR budget.
3. **Angle.** Keep ≤ 30° vertical/horizontal from the plate normal when
   possible. Rectification helps, but beyond ~35° characters blur apart.
4. **Night.** Plates are retroreflective. An 850 nm IR illuminator pointed
   with the camera produces high-contrast plates while staying invisible-ish;
   940 nm is covert-er but dimmer. Phones cannot practically do this.
5. **Mounting.** Vibration kills focus. Solid pole/window mount; dash suction
   mounts are fine for phones, terrible for long lenses.

## Tier 0 — the phone in your pocket ($0)

| iPhone | Daylight reach (plate) | Night | Notes |
|---|---|---|---|
| 12–14 (wide 26 mm) | ~12–15 m | Poor–fair | Use 1080p/60, lock exposure |
| 15 Pro / 16 Pro (5× 120 mm) | ~25–30 m | Fair | Digital crop beyond 15× is useless for OCR |
| Any (flash/burst) | — | + limited | Flash retroreflection works at ≤ 8 m |

**Feasibility verdict:** excellent for mobile/patrol-style capture and spot
documentation; marginal as a 24/7 fixed node (weather, power, thermal).

## Tier 1 — value PoE bullet ($120–250) — the workhorse

Look for, in order: 1/1.8"+ sensor · 4 MP+ · varifocal 2.7–13.5 mm · manual
shutter ≥ 1/1000 s · 850 nm IR · ONVIF/RTSP + FTP/snapshot upload · IP66.

- **Reolink RLC-811A / 823A** — cheap, sub-streams for motion gating; snapshot
  upload works out of the box with our Hub app.
- **Amcrest IP4M-1046B / IP8M series** — similar class, good IR throw.
- **Uniview IPC2325** — NDAA-friendlier alternative (important irony: we avoid
  vendors on the FCC covered list).
- Avoid proprietary cloud-only brands (Ring, Eufy) — no local stream, and it
  would be rather contrary to the mission.

## Tier 2 — DIY edge ($150–350)

- **Raspberry Pi 5 + HQ Camera + C/CS tele lens + 850 nm illuminator:**
  classical hobby ALPR node; runs a future Python edge agent or just FTPs
  snapshots to the Mac Hub app.
- **Luxonis OAK-4 / OAK-D PoE:** on-camera inference; can pre-filter so the
  hub only sees plate-bearing frames.
- **Old iPhone + Continuity Camera:** genuinely good 24/7 node for a window
  overlooking a street — the Hub treats it as a managed source.

## Tier 3 — dedicated ALPR ($1,500+)

Axis Q1785-LE, Dahua ITC237-PU1B, Vivotek IP9165-LPR. Certified capture at
highway speeds, windshield glare rejection, synchronized IR strobe. Buy when a
permanent newsroom/agency-watch deployment justifies it; otherwise Tier 1 is
85% of the performance for 10% of the price.

## Hub hosts

- **Mac mini (M2/M4)** — the reference Hub host: multi-source ingest, ANE
  analysis for a handful of streams, silent, no fan dust ingress issues in a
  garage. This is the "modern and capable" default.
- NVIDIA Jetson Orin Nano — only for non-Apple edge boxes (Linux agent, future).

## Recommended starter rig (~$350 + a Mac you own)

1× RLC-811A-class PoE camera · 1× 5-port PoE switch · 1× outdoor junction
box · 25 m outdoor Cat6 · pole/window mount. The Mac runs `apps/macos-hub`.
Field night kit adds one 850 nm IR floodlamp (~$40).

## Legal-safety hardware rules baked into docs and code

- Cameras point at public rights-of-way, never into private property windows.
- No automatic audio recording (two-party-consent states) — the capture
  pipeline drops audio tracks by design.
