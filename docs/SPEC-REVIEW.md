# SPEC-REVIEW.md — review of the 2026-10-13 specs (accuracy and completeness)

Reviewer: Claude (Sonnet 5.5). Reviewed: GLM 5.3's HANDOFF checklist, `MODEL-TRAINING.md`,
`ACCOUNTABILITY-DATA.md`, `CAMERA-SOURCES.md`, `PROJECTS.md`, LEGAL-ETHICS Rule 6.
Method: every factual claim was checked against the code, a measurement, or a primary
source (links below). Verdicts: ✅ accurate · ✏️ corrected · ➕ gap filled · ⚠ unverified.
**Edits are in the same PR.** The mission/guardrail direction (Rule 6, citation-first,
no biometrics, no private individuals) is sound and was left as written.

## 1. Low-contrast ("stealth livery") OCR spec — ✏️ corrected by measurement

**Spec:** "re-OCR the vehicle ROI with CoreImage contrast enhancement (`CIColorControls` ~2 +
histogram equalization; normal + inverted variants), `.accurate`, merge unseen lines; only when
`hasFleetKeyword` or official plate and `agencyText == nil`."

**What was measured** on the Waltham Police photo (charcoal "WALTHAM POLICE" on a black tailgate),
varying scale, treatment and crop (scratch experiments, 40+ combinations):

| Treatment | Result |
|---|---|
| Original frame / tiles | `THAM` (fragment) |
| `CIColorControls` contrast ≈ 2.2–2.5 (+ gamma) | **worse** (`THAM`, `TRAM`, nothing) |
| **Inverted** (levels, or plain) | **useless** (`Jird`, `Jord`) — the spec's "inverted variant" never helped |
| Histogram equalization | not available as a built-in CIFilter; not tested |
| Unsharp mask | `WALTHAM` at 2×, brittle |
| **Linear levels stretch** (`out = in × gain + bias`, gain 2–4) on a **wide band at 2× scale** | **`WALTHAM`**, robust across gain 2–4 |
| Same stretch on a *tight* crop | worse — it loses context |
| The stylised right-hand "POLICE" | unreadable under every treatment (`Jird`) |

**Implemented instead** (`VehicleML/ContrastVariants.swift`, `VisionBaselineAnalyzer.nameFleetVehicles`):
a levels stretch (gain 2.5 and 3.5) at 2× on dark regions only (mean luminance < 0.38) over the
frame, a mid-body band and its halves. **Gating is structural, not just a condition:** the extra
lines go into a *separate* field, `VehicleObservation.enhancedText`, which `IdentityResolver` may use to
**name the place** of an already-fleet vehicle and which `FleetScoring`/the gate never read — so
enhanced noise cannot create or raise a fleet flag. The pass runs only when a vehicle already has
fleet evidence and its place is unresolved. Corpus fleet metrics are unchanged (59 % / 100 % / 0 FP).

## 2. `MODEL-TRAINING.md` — ✏️ rewritten

| Claim | Verdict |
|---|---|
| Open Images V7 has *Vehicle registration plate*; images CC BY 2.0, annotations CC BY 4.0 | ✅ class `/m/01jfm_` confirmed in the class list. Licence nuance added: per-image, and Google disclaims it |
| …"~15k plate images", "US-heavy" | ⚠ unverified — marked |
| keremberke (8.8k) **and** justjuu (~10k) as two datasets, "multi-country but plates are plates" | ✏️ **one dataset**, and a filename audit shows **97 % Vietnamese motorbike/military/diplomatic images** + 3 % Open Images (CC BY 2.0, not 4.0): wrong domain, unknown image rights → replaced by Open Images' own plate class (2,775 CC BY 2.0 images in validation+test) |
| mabo7237/license-plates-700k "MIT", recommended | ✏️ moved to **excluded**: empty card, viewer error, "Duplicated from guica/…", no provenance |
| UniDataPro US set CC BY-NC-ND, paid | ✅ (free repo is a 5-row preview); NC-ND also on `UniqueData/license_plates` |
| Create ML annotation file `labels.json`, coordinates "centre, normalised 0–1 × size" | ✏️ file is **`annotations.json`**; `x,y` = box **centre in pixels**; ⚠ Apple sources disagree on the key names (`image/annotations` vs `imagefilename/annotation`) — a verify-by-import step was added |
| "Full Network transfer-learning (YOLOv2-based)" | ✏️ these are **two** algorithms: *Transfer Learning* (OS backbone, head only, ~5× smaller) and *Full Network* (YOLOv2, Apple suggests >200 boxes/class, default) |
| Plate OCR "pretraining" on the 700k set via Create ML | ✏️ **Create ML has no OCR template** — not possible in the GUI |
| Fleet classifier sourced from `eval/corpus/` | ✏️ **data leakage**: that is the test set. Train from a separate crawl with an overlap check |
| (not mentioned) data volume | ➕ the eval corpus has 5–13 images/class; classification needs 100–300+/class; no US police/fire/EMS dataset exists as a download → Commons category crawl (CC0/PD/BY only; BY-SA eval-only) |

## 3. `ACCOUNTABILITY-DATA.md` — ✏️ / ➕

| Claim | Verdict |
|---|---|
| "National Decertification Index public entries" | ✏️ **false** — NDI is restricted to verified law-enforcement/POST users; replaced by published state POST registers and public datasets |
| PACER as a docket source | ✏️ PACER charges per page and limits bulk access; RECAP/CourtListener added as the free route |
| Official photos "stored with their citation" | ➕ copyright: federal works are PD (17 U.S.C. §105), many state/local agency photos are not → link-out / hash, don't re-host |
| "settled, encouraged ground" for recording officials | ✏️ well-trodden but **circuit-by-circuit**, qualified immunity, and state buffer-zone laws; softened |
| "BIPA/Tex./Wash. statutes make [face matching] unlawful" | ✏️ they *regulate* biometric identifiers (some with private rights of action); softened |
| (not mentioned) take-home vehicles | ➕ **Location firewall:** unit↔person link + overnight sighting would *derive* a home location although no address is collected. Rule added: person-linked records never carry sighting locations |

## 4. `CAMERA-SOURCES.md` — ✏️

| Claim | Verdict |
|---|---|
| Live iPhone camera ✅ working | ✏️ ⚠️ implemented + unit-tested, never run on a live feed |
| Bonjour `_platewatch._tcp` | ✏️ code advertises **`_platewatch-snapshot._tcp`**, port 8088 (`HubController.swift`) |
| 511NY / WSDOT as public-feed starting points | ✏️ both need keys (511NY: account + developer key + agreement, ~10 calls/60 s; WSDOT: free AccessCode). Caltrans' open dataset lists cameras, not live frames. Starter set = keyless feeds only |
| RTSP can't be opened by `AVAssetReader`; VLCKit LGPL-2.1 | ✅ consistent with AVFoundation behaviour; ⚠ LGPL + App Store distribution needs a legal look (record in DECISIONS) |
| Continuity Camera `.continuityCamera` device type, macOS 13+ | ✅ (also needs the sandbox camera entitlement in the Hub) |
| Hub folder watch and Bonjour snapshot endpoint ✅ shipped | ✏️ **not true** — folder watch starts only after the menu is first opened; the snapshot server is never started and its HTTP handler corrupts binary bodies (verified 2026-10-13; details in CAMERA-SOURCES §Hub verification) |

## 5. HANDOFF §999 — ✏️
- "PRs need `gh` — not installed": **`gh` is installed and authenticated** (PR #5 exists).
- "FeedIngest green": at commit `6c61b49` its tests did not compile (`geohash:` vs `geohash6:`); fixed by the later FeedIngest commits.
- Commit trailers on GLM's own commits read "Co-Authored-By: Claude Sonnet 5.5" — attribution is carried over
  from the shared reminder, not from authorship. Worth correcting for the history's sake.

## Sources
- NDI access: IADLEST — https://iadlest.org/our-services/ndi/about-ndi ; NDI FAQ — https://www.iadlest.org/Portals/0/Files/NDI/FAQ/NDI%20FAQ%20.pdf ; California POST SB 2 FAQ — https://www.post.ca.gov/SB-2-FAQs
- keremberke dataset card — https://huggingface.co/datasets/keremberke/license-plate-object-detection ; justjuu — https://huggingface.co/datasets/justjuu/license-plate-detection
- mabo7237 — https://huggingface.co/datasets/mabo7237/license-plates-700k ; UniDataPro US — https://huggingface.co/datasets/UniDataPro/united-states-license-plate-dataset
- Open Images V7 boxable classes — https://storage.googleapis.com/openimages/v7/oidv7-class-descriptions-boxable.csv
- Create ML annotation format — Apple WWDC19 session 424 https://developer.apple.com/videos/play/wwdc2019/424 ; forum thread https://developer.apple.com/forums/thread/765286
- Create ML algorithms — Apple tech talk 10155 https://developer.apple.com/videos/play/tech-talks/10155
- 511NY API — https://511ny.org/developers/doc ; WSDOT Traveler Information API — https://wsdot.wa.gov/traffic/api/ ; Caltrans CCTV — https://dot.ca.gov/caltrans-open-data-inventory
