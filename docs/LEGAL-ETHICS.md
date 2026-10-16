# LEGAL-ETHICS.md — guardrails that keep this lawful and worthwhile

This project watches **the powerful** — public institutions and the officials
who run them — and it deliberately does not watch private individuals. The
rules below are encoded in the data layer (`RedactionGate`, `SourceCitation`
requirements, moderation states) and are conditions for contribution, not
vibes.

## Mission scope

The platform documents **publicly funded vehicles and agencies** — police,
fire, EMS, public works, transit, school districts, federal fleets — because
taxpayers own them and accountability for public assets is a legitimate civic
function. It is **not** a general-purpose people-tracking system. Officials
acting in their public capacity are not shielded from public scrutiny:
photographing and recording them on duty is protected activity (*Glik v.
Cunniffe*; *Fields v. City of Philadelphia*), and aggregating what public
records and public-interest publishers already say, with citations, is the
platform's purpose. See `docs/ACCOUNTABILITY-DATA.md` (M7) for the people &
records program and its guardrails.

## Rule 1 — Fleet-focused ingestion (enforced in code)

- A sighting of a likely private vehicle (no fleet markings, standard-issue
  civilian plate, no match to a known fleet record) is kept **on-device** by
  default.
- Only when a fleet-confidence threshold is crossed (classifier +
  markings + known unit format) does a record enter the shared database.
- **Local Review exception (owner clarification, 2026-10-15):** preserve the target
  vehicle's evidence crop intact for human review. Do not black out its plate, lettering,
  or incidental background plate/text regions, and do not discard the image because
  another detected vehicle overlaps. Earlier crop suppression/redaction made evidence
  unreviewable; those image rules are removed for the local Hub Review store.
- This exception does not permit private-vehicle plate indexing, private-person enrichment,
  or image publication. Review JPEG bytes stay on the Mac: REST explicitly omits them
  and CloudKit maps no image field. Shared structured plate/registration and location
  fields retain their fleet-confirmation rules. Any future image-export feature needs
  its own explicit publication policy; local evidence must not be destructively altered
  to implement that policy.
- **Server-enforced (`server/`):** a plate is persisted only for
  `fleetConfirmed` sightings. `pending` and `redacted` rows keep unit number,
  bucketed area, and fleet confidence for moderator review, but never the
  plate. The public sightings feed and exports serve `fleetConfirmed` rows only.

## Rule 2 — Public records only for enrichment

- Officer/agency/assignment data comes exclusively from sources we can cite:
  agency rosters, fleet registries, FOIA releases, auction listings, official
  posts. Every enriched field carries a `SourceCitation` (URL + retrieval
  date + source type).
- **Never** DMV records, data broker APIs, or paid people-search databases
  (DPPA liability, plus it's contrary to the entire point).
- Unit number + officer **inference is labeled as inference** with a
  confidence. Nothing requires a reader to trust a low-confidence link.

## Rule 3 — Jurisdiction reality check

- **US baseline:** photographing vehicles/plates on public roads is settled
  lawful activity; plate data itself is not protected personal data when
  self-collected. Publishing *fleet* rosters sourced from public records is
  standard journalism.
- **EU/UK:** ANPR-style processing triggers GDPR even for public plates. Our
  answer: the shared dataset is fleet-scoped (processing relates to public
  bodies' assets), private plates never persist, and sighting geo is
  bucketed (~1 km) until fleet-confirmed. Deployments in the EU should run
  the strict-mode redaction profile and get local counsel.
- Audio is never recorded (two-party-consent states).
- When in doubt: fleet-only, bucket geo, keep raw media local.

## Rule 4 — Do-no-harm publication policy

Some taxpayer-funded vehicles must never be real-time-tracked in the open:
domestic-violence response units, victim services, child-protective services,
undercover-adjacent units revealed only by speculation. These are:
- excluded from watchlist push alerts,
- published with coarse time/space fuzzing or not at all (moderator-owned
  `SafetyHold` list),
- subject to an appeal/removal process documented in CONTRIBUTING.

## Rule 5 — Anti-abuse stance

- No doxxing, no home addresses, no family info, ever. Moderator removal is
  final and logged.
- Rate-limit proof-of-personhood for contributors (CloudKit account + signed
  device) keeps bot-dumps out.
- The database documents assets and assignments **as institutions**, and
  commentary features are deliberately absent — this is a records tool, not
  a forum.

## Rule 6 — Public officials in public capacity (people & records program)

Public officials are legitimate subjects of public scrutiny; private
individuals are not subjects at all. The M7 program
(`docs/ACCOUNTABILITY-DATA.md`) may collect and publish, **with citations**:

- official rosters/assignments, official bios and photos, Brady/Giglio
  releases, decertification registers, lawsuit dockets, and the work of
  public-interest publishers — always attributed to the original source;

### Identifying officials on camera (authorized with conditions)

Matching a person seen in a sighting to a public accountability record, and
surfacing that record (court, Brady/Giglio, decertification, roster), is part
of the mission — when **every** condition holds:

1. **Recorded subjects only.** The matching corpus contains only people who
   already have a cited public accountability record (Brady/Giglio release,
   decertification register, docket, official disciplinary publication).
   Nobody is enrolled "just in case", and **private individuals are never
   enrolled or matched**.
2. **Public photos only.** Reference photos come from official/department
   publications or public-interest publishers, each carrying a
   `SourceCitation`. Never personal social media, DMV records, or data
   brokers.
3. **On-device.** Face embeddings are computed and matched on the operator's
   device; biometric templates never leave it and are never stored in the
   shared database. What may be shared is a confirmed, citation-carrying
   *link* — never biometric data.
4. **Confirmation, not assertion.** A match is labeled inference with a
   confidence and never auto-publishes or asserts that the person *is* the
   subject; publishing a person-linked record requires the same moderator
   confirmation as every other person link.
5. **Public capacity only.** Identification surfaces cited records; it is
   not a person-tracking product. No home addresses, no family, no off-duty
   private life; no published per-person live maps or presence alerts;
   residential-hours sightings are never linked to a named individual (see
   the location firewall in ACCOUNTABILITY-DATA.md).
6. **Verbatim + appealable.** What a docket alleges is stored as an
   allegation with status and source; Brady entries name the releasing
   office. Removal/appeal follows the SafetyHold process.

**Jurisdiction gate.** Biometric matching is disabled by default in code. A
deployment may enable it only after local-counsel review of that
jurisdiction's biometric statutes (Illinois BIPA, Texas CUBI, Washington
RCW 19.375 and their analogues create independent exposure with differing
exemptions and remedies). The enablement decision (who approved, when, for
where) is recorded with the deployment configuration.

and may never:

- profile or track a **private individual** (civilian plates, bystanders,
  family members);
- publish home addresses, family details, or off-duty private life;
- run biometric matching outside the conditions above — no enrollment of
  subjects without cited accountability records, no upload of biometric
  templates, no identification that publishes or alerts without human
  confirmation;
- assert as fact what a docket only alleges — records are stored verbatim
  with status and source.

Auto-inferred person↔vehicle links are labeled as inference and never
auto-publish. Removal/appeal follows the SafetyHold process.

## Why publish this policy

The commercial ALPR industry (and its public-sector customers) operate
mass-surveillance infrastructure with almost none of these constraints. The
project's credibility — and its legal safety — depend on being visibly more
disciplined than the systems it audits.

## Addendum 2026-10-13 — review confirmations and evaluation data

- A user confirming a below-threshold detection submits at the persist floor only; the server
  stores it as `pending` moderation, without a public plate or exact geo.
- On CloudKit, uploads are creator-readable only; plate text is attached only if the
  fleet-confirmed rule would publish it anyway.
- Evaluation photos are third-party, licensed (see `eval/manifest.json`), kept out of the repo, and
  never converted into synthetic "sightings".
