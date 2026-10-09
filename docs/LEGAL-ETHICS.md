# LEGAL-ETHICS.md — guardrails that keep this lawful and worthwhile

This project watches power, not people. The rules below are encoded in the
data layer (`RedactionGate`, `SourceCitation` requirements, moderation states)
and are conditions for contribution, not vibes.

## Mission scope

The platform documents **publicly funded vehicles and agencies** — police,
fire, EMS, public works, transit, school districts, federal fleets — because
taxpayers own them and accountability for public assets is a legitimate civic
function. It is **not** a general-purpose people-tracking system.

## Rule 1 — Fleet-focused ingestion (enforced in code)

- A sighting of a likely private vehicle (no fleet markings, standard-issue
  civilian plate, no match to a known fleet record) is kept **on-device** by
  default.
- Only when a fleet-confidence threshold is crossed (classifier +
  markings + known unit format) does a record enter the shared database.
- Non-fleet plate text in the background of an otherwise-fleet capture is
  **redacted before upload** (blur mask in stored crop; plate field dropped).

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

## Why publish this policy

The commercial ALPR industry (and its public-sector customers) operate
mass-surveillance infrastructure with almost none of these constraints. The
project's credibility — and its legal safety — depend on being visibly more
disciplined than the systems it audits.
