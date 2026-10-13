# ACCOUNTABILITY-DATA.md — the people & records program (M7)

PlateWatch watches **the powerful**. In the United States that is settled,
encouraged ground: photographing and recording officials in public is
First-Amendment-protected activity (*Glik v. Cunniffe*, 1st Cir. 2011;
*Fields v. City of Philadelphia*, 3d Cir. 2017), public-records laws exist
because citizens are entitled to see what government does, and officials
acting in their public capacity carry no reasonable expectation of privacy in
that conduct. Public-interest sites, cop-watch channels, court watchers and
journalists already publish this material every day — **PlateWatch's job here
is aggregation with provenance**, so scattered public information becomes
usable, verifiable, and hard to disappear.

The line the platform never crosses is equally firm: **public officials in
their public capacity — never private individuals.** Officers, commanders,
agency heads, elected officials and public employees as operators of public
assets are in scope. Their families, homes, and off-duty private lives are not.

## What gets collected (in build order)

1. **Rosters & assignments** — agency published rosters, budgets, org charts,
   FOIA releases, GSA/state fleet data (importers already exist in
   `FleetImporters`). Links `UnitAssignment` (unit ↔ vehicle ↔ person).
2. **Official photos** — from official government pages (agency bios, roster
   headshots, campaign/official social accounts) so humans can verify a
   record ("is this the right vehicle/person?"). Photos are stored **with
   their citation** and are for human moderator/comparison use.
3. **Credibility & conduct records** — Brady/Giglio lists released by
   prosecutors, state POST decertification registers, National Decertification
   Index public entries, lawsuit dockets (PACER, state courts), settled
   journalism. These attach to officials/agencies as cited records.
4. **Aggregation of existing publishers** — public-interest sites, watchdog
   channels, social accounts that already do this work. PlateWatch indexes
   what they publish, always citing the original source; it is a finding aid
   for the public record, not a replacement or a re-host of others' work
   without attribution.

## Cross-reference chain (the product)

`Sighting → vehicle/unit → UnitAssignment → OfficialProfile → cited records
(roster, photo, Brady entry, lawsuit, news)` — every arrow carries a
`SourceCitation`. A sighting of unit D756 can eventually answer "who is
assigned to D756, what agency, what does the public record say about them",
with links a journalist or resident can independently verify.

## Hard guardrails (encoded, not aspirational)

These extend `docs/LEGAL-ETHICS.md` Rules 2/4/5; they are what keeps the
program lawful, accurate, and worth defending:

- **Public capacity only.** No home addresses, no family, no off-duty
  personal life, no private citizens — civilian plates stay out of every
  person-linked record. Moderator removal for violations is final and logged.
- **Provenance or it doesn't exist.** Every person, photo, assignment and
  incident record requires ≥ 1 `SourceCitation` (URL, publisher, retrieval
  date). Un-sourced enrichment is rejected in code (AGENTS.md guardrail 2).
- **No biometric matching.** Photos are never run through face recognition
  against sighting frames or anyone's image. Beyond ethics, several states
  (Illinois BIPA 740 ILCS 14, Texas, Washington) impose statutory liability
  on biometric identification. Photos aid human verification; nothing more.
- **Inference is labeled.** Auto-suggested unit↔person links carry a
  confidence and never auto-publish; publication requires moderator
  confirmation with its own citation.
- **Allegation ≠ fact.** Lawsuits store docket references, parties, and
  status verbatim; summaries never go beyond the filing. Brady entries are
  stored as released, with the releasing office named.
- **Anti-abuse.** No scoring or ranking of individuals, no presence alerts on
  a person, no "leaderboards". Agency-level pattern analysis only (matches
  the ideas bin). Commentary features stay absent — records tool, not a forum.
- **Takedown & appeal** mirror the `SafetyHold` process: removal requests
  honored for safety harms, logged, and error corrections re-verified against
  the cited source.

## Data model (planned — see DATA-MODEL.md §Planned entities M7)

- `OfficialProfile` — name, role, agency, public-capacity photo + citations.
- `IncidentRecord` — kind (brady | decertification | lawsuit | news |
  report), reference, status, citations.
- `UnitAssignment` already exists (unit ↔ vehicle ↔ officer/agency-member);
  M7 adds the person link + confidence + citation.
- All person-linked records live behind the same moderation states as
  sightings; nothing publishes without a confirmed citation.

## Status & prerequisites

⬜ Not started. Depends on: CloudKit live (NEXT-STEPS §1), moderator publish
tool (§1b), and an ethics review pass of this document by the owner before
any person-data code lands. The `AccountabilityKit` package skeleton
(types + citation enforcement + tests) may land first — it contains no
collection logic.
