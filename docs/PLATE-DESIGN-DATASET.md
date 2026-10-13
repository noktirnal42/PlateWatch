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
