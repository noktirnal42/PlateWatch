# ACCOUNTABILITY-DATA.md — the people & records program (M7)

PlateWatch watches **the powerful**. In the United States that is well-trodden,
protected ground — but not uniform ground: photographing and recording officials
in public is First-Amendment-protected activity in the circuits that have decided
it (*Glik v. Cunniffe*, 1st Cir. 2011; *Fields v. City of Philadelphia*, 3d Cir.
2017, among others), while the rule varies by circuit, qualified immunity often
decides the damages question, and several states have passed (and courts have
sometimes enjoined) laws limiting how close you may record police. Contributors
need the local rule, not a blanket assurance — see LEGAL-ETHICS. Public-records laws exist
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
   headshots) so humans can verify a record ("is this the right
   vehicle/person?"). **Copyright matters here:** works of the *federal*
   government are public domain (17 U.S.C. §105), but many state and local
   agencies retain copyright and campaign/social photos are the photographer's.
   Default: **store the URL, retrieval date, a SHA-256 of the file and a
   thumbnail only where the licence allows — link out, don't re-host.** A photo
   is stored with its citation and is for human moderator comparison only.
3. **Credibility & conduct records** — Brady/Giglio lists released by
   prosecutors (public only where a jurisdiction has released them), **state POST
   decertification lists that a state publishes**, lawsuit dockets, settled
   journalism. These attach to officials/agencies as cited records.
   - **The National Decertification Index (NDI) is *not* public.** It is run by
     IADLEST and is open only to verified law-enforcement/POST personnel (access
     is approved by each state's POST; some states, e.g. California, bar even
     private investigators). Public-record equivalents are individual state POST
     registers that are published, plus public datasets such as the Invisible
     Institute's Citizens Police Data Project. (The draft said "NDI public
     entries" — corrected.)
   - **Court dockets:** PACER charges per page and restricts bulk automated
     access; prefer the free RECAP archive / CourtListener API (Free Law Project)
     and state portals' own terms. Verify each docket against the filing.
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

## Location firewall (added in review — a gap in the first draft)

Take-home and assigned vehicles are the sharp edge of the cross-reference chain.
A cruiser seen parked overnight, joined to a person via `UnitAssignment`, would
**derive an officer's home location** even though no home address is ever
collected — exactly what Rule 6 forbids. Therefore:

- **A person-linked record never carries a sighting location.** Sightings stay
  agency/unit-level (coarse geohash6, k-anonymous aggregates); the person link
  is shown as a *cited assignment*, never as "seen at <place> at <time>".
- No overnight/residential-hours sighting is ever published against a named
  individual, and the UI must not offer a per-person timeline or map.
- A moderator confirming a unit↔person link reviews the **link**, not the
  sighting history; a test asserts that `OfficialProfile`/`PersonLink` types
  have no location field and cannot be constructed from a `Sighting`.

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
  (Illinois BIPA 740 ILCS 14, Texas, Washington) regulate biometric identifiers
  and some create private rights of action; the exact exemptions differ, so the
  project's rule is simply *never*. Photos aid human verification; nothing more.
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

Citation-gated profile, incident and person-link types exist in `AccountabilityKit`;
automated person-record collection and cross-reference publication are not implemented.
The Hub exposes the existing **fleet-only** FOIA draft generator and a labelled
programme overview. It does not collect officer photos, run face recognition,
or identify people in live footage.

Next implementation sequence for the records workstream:

1. Review the programme with the owner before person-data ingestion lands.
2. Add isolated adapters for official agency rosters/employee lists, official award
   pages and permitted agency social posts, released Brady/Giglio/POST lists,
   court filings/outcomes and FOIA releases. Record publisher, original URL,
   retrieval date and evidence excerpt/hash for every extracted claim.
3. Suggest candidate links using name, agency, role, published identifiers and
   overlapping dates. A name alone never confirms identity; ambiguous matches
   remain separate pending moderator review.
4. Preserve the released wording, docket and outcome/status. Keep allegations,
   findings and dispositions distinct, with corrections and appeal support.
5. Link official photo sources for human verification subject to their licence;
   do not derive face embeddings or match camera occupants. Keep person records
   separate from sighting locations, timelines and presence alerts.
6. Validate citation enforcement, false-match handling, moderation and the
   location firewall before enabling publication or claiming automation works.
