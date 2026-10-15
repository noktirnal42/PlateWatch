# Session handoff — 2026-10-14 (read this first)

Written at the end of a long Claude session so a new agent can pick up cold. It complements — does not replace —
[`HUB-HANDOFF-2026-10-14.md`](HUB-HANDOFF-2026-10-14.md) (Codex's Hub notes), [`IOS-UI-HANDOFF.md`](IOS-UI-HANDOFF.md) (iOS),
[`NEXT-STEPS.md`](NEXT-STEPS.md) (prioritised backlog) and [`../AGENTS.md`](../AGENTS.md) (hard rules). Facts here were verified
on 2026-10-14; anything marked **UNVERIFIED** was not.

## 1. What PlateWatch is now

An open-source accountability system for taxpayer-funded fleets. Three surfaces share the Swift packages in `packages/`:

| Surface | Where | State |
|---|---|---|
| **macOS Hub — the desktop console** | `apps/macos-hub` | Full windowed app (sidebar: Dashboard, Live, Public feeds, Cameras & ingest, Review, Models, Records & FOIA, Moderation, Settings). Menu-bar item kept as a shortcut. **This is the centre of gravity.** |
| iOS app (+ watch) | `apps/ios`, `apps/watchos` | Polished by Codex (PR #18, merged). Handheld camera/VoiceOver/thermal tests still not done. |
| Reference server | `server/` (Vapor, Postgres) | Moderator console + JSON API, publication guardrails, takedowns, audit log. |

Owner decision: **the Hub is the one desktop app that does everything** — web feeds, iPhone/Continuity/IP cameras, files/video, the
analysis pipeline, review, and moderation (moderators only).

## 2. Branch and PR state

- `main` has PRs #11–#19 merged (feed quality, robots policy, model release + `.aar` install, terms review, iOS polish, …).
- **PR #20 `feat/hub-moderation` is open and mergeable** — the Hub console, feeds, moderation, guardrails, location, importers. Several
  agents (Claude, Codex, GLM) have committed on this one branch in one shared checkout. CI re-runs on every push; **auto-merge is
  disabled** on the repo, so merge by hand once CI is green (`gh pr merge 20 --merge`).
- Merge `main` into the branch if GitHub reports conflicts (the only conflicts so far were in `docs/NEXT-STEPS.md`).

## 3. What exists (by area)

**Hub (`apps/macos-hub/Sources`)**
- `Console/` — `ConsoleView` (sidebar), `FeedsPane` (list, ★ favorites, ⦸ block, search, source/status filters, sort incl. State, Favorites
  grid of live thumbnails, preview panel, Open-in-Live), `TermsReviewSheet` (guided terms confirmation), `LivePane` (local/Continuity camera
  or video file with overlays; never shows plate text), `ReviewPane` (local outbox with evidence thumbnails), `ModerationPane`
  (Sightings / Takedown requests / Audit log), `RecordsPane` (FOIA builder + cited directory), `HomeLocation` (GPS / lat-lon / Plus Code),
  `ModeratorAccess` (Keychain credential + `ModerationClient`), `FeedPreferences` (favorites/blocked).
- `FeedRunner` — per-host robots check, per-host 1 req/s pacing, per-camera status, HLS + snapshot sources, **status changes coalesced to
  ≤2 UI refreshes/s** (do not make `sourceStates` `@Published` again — it froze the app).
- `HubController` — ingest (folder watch, Bonjour snapshot server on an OS-assigned port, RTSP stub), analysis (**max 2 feed frames in flight;
  surplus dropped and counted**), catalogue importers menu (Austin, Caltrans, WSDOT, Iowa, Newfoundland, DriveBC + others added by GLM).

**Packages** — `PlateKit` (incl. `PlusCode`, `JurisdictionPolicy`, `Geohash`), `FeedIngest` (`RobotsCache` with `decisions(for:)` batching and
a documented `PublicAPIPermission.caltransCCTV`, `CameraCatalogueImporters`, `SnapshotPoller`, `FeedTermsReview`), `VehicleML`
(`ModelManager` installs `.aar` via isolated, symlink-rejecting `ModelArchive`), `PlateSync`, `CaptureKit`, `AccountabilityKit`.

**Server** — `PublicationPolicy` (24 h publication delay `PUBLISH_DELAY_HOURS`, 21-day retention `RETENTION_DAYS`, `Sighting.publicQuery` is the
only starting point for public queries), `TakedownController` (`POST /v1/takedowns`), moderator JSON API under `/moderator/api/…`
(`queue`, `sightings/:id/decision`, `takedowns`, `takedowns/:id/resolve`, `audit`) guarded by `MODERATOR_TOKEN` + header
`X-PlateWatch-Moderator: 1`, append-only `audit_log`.

**Models** — `models-v0.1.0` release is **published** (owner did it); `models/registry.json` pins the SHAs of the *published* assets
(re-hash uploads: `aa` output is not byte-reproducible). Create ML plate detector beats YOLOv8n; the fleet crop classifier is **not safe as
evidence** (fails on stealth livery).

**CloudKit** — container `iCloud.org.platewatch.platewatch`, team `LH8KLB9N4F`: schema imported to Development and **deployed to
Production** (Agency, Sighting, SightingSubmission, Vehicle). **Not yet tested:** a two-account creator-only check, and there is no
moderator publish tool for CloudKit (needs a server-to-server key).

## 4. Build, run, test

```bash
# Hub (needs xcodegen; project is generated, apps/macos-hub/project.local.yml holds DEVELOPMENT_TEAM and is gitignored)
(cd apps/macos-hub && xcodegen)
xcodebuild -project apps/macos-hub/PlateWatchHub.xcodeproj -scheme PlateWatchHub -configuration Debug \
  -derivedDataPath /private/tmp/pw-hub-signed -allowProvisioningUpdates build
pkill -f PlateWatchHub.app; rm -rf ~/Applications/PlateWatchHub.app
cp -R /private/tmp/pw-hub-signed/Build/Products/Debug/PlateWatchHub.app ~/Applications/ && open ~/Applications/PlateWatchHub.app

# Packages / server (run from the package dir)
swift test --package-path packages/FeedIngest      # also PlateKit, VehicleML, PlateSync, CaptureKit, AccountabilityKit
swift test --package-path server

# Server locally (Postgres must be running; dev DB URL default is in server/Sources/App/configure.swift)
MODERATOR_TOKEN="$(cat ~/.config/platewatch/moderator-token)" PORT=8083 swift run --package-path server App serve

# Evaluation on unlabelled feed frames (gitignored eval/feeds/)
eval/harness/.build/release/EvalHarness eval --survey eval/feeds/austin --models models/cache --tasks vehicle-detection
```

Signed builds matter: **unsigned builds never get the macOS Location/Keychain behaviour a real build gets** (and re-prompt on every rebuild).
Use the signed command above (Apple Development identity, team `LH8KLB9N4F`).

## 5. Local state and secrets (paths only — never commit values)

| What | Where |
|---|---|
| Moderator token (41 chars, mode 600) | `~/.config/platewatch/moderator-token` |
| Hub's moderator credential | Keychain service `org.platewatch.hub.moderator`, account `moderator-token`; server URL in defaults `moderatorServerURL`; enrolment UI only if `defaults write org.platewatch.PlateWatchHub moderatorEnrollment -bool true` |
| Feed catalogue (8k+ cameras, per-source terms) | `~/Library/Application Support/PlateWatchHub/feeds.json` |
| Hub prefs | defaults domain `org.platewatch.PlateWatchHub`: `hubGeohash6`, `hubFavoriteFeeds`, `hubBlockedFeeds`, `hubSnapshotPort` |
| Sample feed frames, eval corpus, models cache | `eval/feeds/`, `eval/corpus/`, `models/cache/` — all gitignored |
| Training data | `~/Documents/PlateWatch-Training/` |
| Research notes | `docs/research/`, `/private/tmp/pw-research/` (scratch) |

Do **not** re-create the Keychain item from the command line on each run: it resets "Always Allow" and triggers a prompt that blocks the app.

## 6. Hard-won gotchas

1. **Shared checkout.** Several agents commit on one branch in one working tree. Commit only your own paths (`git add <files>`, never `-A`), read
   `git status` first, and use a separate worktree for anything long (`git worktree add /private/tmp/<name> -b <branch> origin/main`).
   AGENTS.md rules 6–7 exist because a tracked symlink once wiped the eval corpus.
2. **Main-thread starvation** was the root of most "stuck" symptoms: 8k-row tables, thousands of per-camera publishes, per-camera actor
   hops. The Hub is now ~13 % CPU idle; keep it that way. When the main thread is saturated, accessibility queries time out and UI automation
   fails with "could not read which file this window is editing" — fix the CPU, not the tool.
3. **Robots policy.** 401/403/429 on robots.txt ⇒ do not fetch; 5xx ⇒ do not fetch **unless** a documented `PublicAPIPermission` applies
   (Caltrans CWWP2 only); S3 `AccessDenied` for a missing robots.txt ⇒ allow (it is "no file"). Terms confirmation is **human-only** — never
   automate it or tick the box for the owner.
4. **CI** restarts on every push to a PR; pushes while it runs reset it. Batch commits, then wait.
5. macOS has no `timeout`; zsh does not word-split unquoted variables; `git grep -A` is not supported (use `grep -n -A`); a stale
   `swift-package` process can hold SwiftPM's lock (kill it); `sleep` loops are blocked in this harness — use background commands.
6. Computer-use: background `app_*` tools need a responsive app; a full-screen Space hides the target window (`off_space`); never drive the
   OpenCode windows for other projects ("GFG", "OpenSquare" are the owner's, unrelated). Permission prompts (Keychain, Documents, Location)
   are the owner's to answer.
7. `PlateWatchHub.xcodeproj` is generated (xcodegen) and ignored; CI copies `project.local.example.yml` to `project.local.yml`.

## 7. Positions and decisions (owner's)

- PlateWatch is "not an ALPR as we know it", so the owner's position is that it is not ALPR "use". **Counsel reportedly confirmed it (owner, 2026-10-15; nothing in writing in the repo)**, so the
  state "off" list is empty by default as of 2026-10-15 (unknown/non-US location still off; see [`PLATE-READING-JURISDICTIONS.md`](PLATE-READING-JURISDICTIONS.md)). Plate *reading* off ⇒ fleet detection continues.
- CC BY-SA images were allowed for the plate-state classifier only (that classifier was abandoned: location is the primary state source).
- Public camera feeds carry no GPS: location comes from the source's catalogued position. The Hub's *home* location is operator-set.
- The owner publishes releases and answers system prompts; agents do not.

## 8. Open items (rough priority)

1. **Merge PR #20** when CI is green; then delete the shared-branch habit — new work on fresh branches from `main`.
2. **Postgres on this Mac was shutting down** at the end of the session (`FATAL: the database system is shutting down`). Restart it before running the server; the dev DB is `platewatch`.
3. Hub: the **Live pane** video-file path was exercised 2026-10-15 (an mp4 of the Austin sample frames played with vehicle overlays and stopped cleanly) and the owner confirmed the Continuity camera path works (only test photos pointed at it — little local traffic); LLM/MLX assistants are **not built** (must stay on-device; AGENTS.md rule 3).
4. **Use my location** shows "permission granted but no position available" on this desktop Mac (no GPS/Wi-Fi fix). Manual lat/lon and Plus Code work.
5. CloudKit: two-account creator-only test; moderator publish path (server-to-server key).
6. Legal: counsel (reported) says feed OCR and handheld use are not ALPR "use" — get it in writing and file it (the gate is already relaxed on the owner's instruction); the remaining 23 states + DC were desk-reviewed 2026-10-15 (`research/STATE-ALPR-SWEEP-2026-10-15.md`; no ban found; WA SB 6002 reach unconfirmed); the handheld iOS app now applies the jurisdiction gate (`PlateReadingGate`).
7. Feeds: 15 more working sources have unclear terms (`research/FEED-RESEARCH-MORE-SOURCES.md`); Arizona-first research (`a82d65e`) lists next steps;
   WSDOT allows "low volume" only; do **not** poll Illinois/Michigan/Kentucky/Tennessee images (robots), NYC DOT (ask), Houston TranStar.
8. Recognition: Austin cameras are wide views — 0 fleet hits in 39 sampled frames. Real hits need close, low-angle lanes. Stealth-livery data
   (Waltham as held-out) is the known classifier gap.
9. Release engineering: signed/notarised Hub build, layered icon variants, handheld thermal/VoiceOver passes.

## 9. First 30 minutes for a new agent

1. `git fetch && git status -sb && gh pr list` — confirm nothing is uncommitted that you did not write.
2. Read `AGENTS.md`, this file, `NEXT-STEPS.md` §10–11, `HUB-HANDOFF-2026-10-14.md`.
3. Build the Hub with the signed command; open Public feeds, star a camera, open Favorites, open Moderation → Audit log (server running).
4. Pick one item from §8, make a worktree, keep commits small, and update the relevant doc (AGENTS.md convention).
