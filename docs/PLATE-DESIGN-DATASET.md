# PLATE-DESIGN-DATASET.md — licensing review for the plate-design classifier

Status: **gate not cleared.** No image source has been approved for training.
This document is the review record required by
[DECISIONS.md](DECISIONS.md) (2026-10-11, plate-design classifier) before any
image is downloaded.

## Goal

Classify a plate's design family (US state, exempt/government, federal) so the
redaction gate can use it. Only *design* examples are needed: reference images
of plates as issued, not photos of anyone's private vehicle.

## Hard constraints

1. **No private-citizen plate photos.** LEGAL-ETHICS Rule 1. Training data
   must not be crops from private vehicles, and must not come from scraping
   photos of identifiable people or vehicles.
2. **Record the licence of every source** before use (AGENTS.md guardrail 5).
   Unknown or missing licence = not usable.
3. **Redistribution.** Weights trained on the data are not committed (AGENTS.md
   guardrail 5), but we must still be able to say what the model was trained
   on.

## Candidate sources reviewed

Source findings come from secondary search summaries. Each has to be opened
and read directly before the gate can clear.

| Source | What it offers | Licence (as found) | Verdict |
|---|---|---|---|
| Roboflow "License Plates Dataset" ([public.roboflow.com](https://public.roboflow.com/object-detection/license-plates-us-eu)) | Object-detection plates, drawn from Open Images | Listed as CC BY 4.0; underlying images CC BY 2.0 | **Reject for this task.** Detection data with plates of private vehicles; the "US-EU" coverage is unclear. |
| Roboflow Universe US plate detection sets | Detection, scraped web images | CC BY 4.0 on some; source collection unclear | **Reject.** Detection data, and scraped sources carry the privacy risk in constraint 1. |
| Kaggle "US license plate" classification sets | Per-state classes, 50 states + DC | Not stated in the summary | **Open.** Read the licence on each Kaggle page. If the set holds photos of private vehicles, reject it. |
| Vendor "Fifty States" sets (gts.ai) | Per-state plate images | Not stated | **Reject until licence is stated in writing.** |
| Wikimedia Commons plate photos | Per-state plate images | Varies per file (public domain, CC BY-SA 3.0/4.0 found) | **Usable per file, with care.** Each file's licence must be recorded. Photos can include private vehicles; prefer scans or official design images. |
| State DMV or agency design pages | Official images of issued plates | Unknown per state; government works are often not copyright-free | **Open, state by state.** Needs written permission or a confirmed public-domain basis. |

## Recommended route to clear the gate

1. **Start with official, licensed reference images.** For each state, record the
   source URL, the licence, and the retrieval date. Keep the record in
   this document's source table, and set the `license` field in `models/registry.json`.
2. **Use synthetic augmentation only for variation,** not as a substitute for
   real designs. Augmentation (lighting, blur, angle) is fine.
3. **Exclude any frame containing a non-design plate.** A design classifier
   needs only the plate face, and the crop must not include a surrounding
   private vehicle.
4. **Train a small classifier** and record its licence as `PlateWatch` (the
   registry entry for `plate-design-classification` already says so) only once
   every training source is recorded.

## Open questions for the project owner

- Are state DMV design images usable for a public model, or must we seek
  written permission state by state?
- Is a smaller, state-agnostic "government vs private" classifier enough for
  the redaction gate, deferring full state families?

## Current behaviour

The gate already treats a missing design as non-exempt
(`RedactionGateService`), so nothing breaks while this is pending.

## Review of state DMV specimen images — 2026-10-19 (owner asked to use them "where licence or permission allows")
Result: **no state is confirmed usable; nothing was downloaded.**
- No DMV page I could read states a licence for reuse. Virginia's DMV media page (<https://www.dmv.virginia.gov/news/media>) offers three plate images (Standard Passenger, Autumn, Eyes on the Road) "for media use" with no stated terms; "media use" is not a grant for model training, and Virginia's college/organisation plate pages say sponsor-owned designs are copyrighted by the sponsor (state-created scenic plates by the Commonwealth).
- General position found: a state usually owns the copyright in designs it commissioned or created, designs by outside artists belong to the artist (e.g. California's Arts plate), and a Commons "government work" tag on a *photograph* does not clear the underlying design. So an unlicensed specimen image is a legal risk even if freely downloadable.
- What would clear a state: a written statement (licence, terms page or email) permitting use of its standard-issue plate image for training a non-commercial open-source classifier; only standard-issue base designs are wanted, not specialty/sponsor plates. Requesting it is an outward-facing message and is the owner's to send. Suggested request text: "PlateWatch is an open-source, non-commercial project that classifies a plate's issuing state from its design. May we use the standard-issue [State] passenger plate image from your website as one training example, with attribution to [Agency]? We will not redistribute the image."
- Until a state replies in writing, keep using the Commons sources already recorded (CC0 / PD / CC BY / CC BY-SA per file) and synthetic variation of them.

## Local fleet-confirmation set — 2026-10-19
`scripts/export_fleet_plate_crops.py` exports the operator's own agency-resolved Review crops (label = state of the resolved agency key; local, gitignored, never uploaded). Today it finds **0 usable items** (the Review queue is empty and the Hub's evidence archive holds 2 files), so this source adds no data yet; the 3 photos in `eval/user/` are acceptance cases and must stay out of training.
