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
   is stored with its citation; it may serve as human-comparison material and,
   where every LEGAL-ETHICS Rule 6 condition holds, as a reference image for
   on-device identification of officials with cited accountability records.
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
- The firewall governs what is **stored and published**. The Rule 6
  on-device identification flow is the operator's own tool at the moment of
  capture — it may show the operator which cited-record person matched in
  this frame — but nothing it displays becomes a published person-location
  fact: published records still carry no sighting location, and
  residential-hours frames produce no person link at all.

## Hard guardrails (encoded, not aspirational)

These extend `docs/LEGAL-ETHICS.md` Rules 2/4/5; they are what keeps the
program lawful, accurate, and worth defending:

- **Public capacity only.** No home addresses, no family, no off-duty
  personal life, no private citizens — civilian plates stay out of every
  person-linked record. Moderator removal for violations is final and logged.
- **Provenance or it doesn't exist.** Every person, photo, assignment and
  incident record requires ≥ 1 `SourceCitation` (URL, publisher, retrieval
  date). Un-sourced enrichment is rejected in code (AGENTS.md guardrail 2).
- **Biometric matching only under the Rule 6 conditions.** Face matching is
  permitted solely to identify officials who already have cited public
  accountability records, against cited public photos, computed on-device,
  never auto-publishing, and only in deployments whose jurisdiction has
  passed counsel review (LEGAL-ETHICS Rule 6 — Illinois BIPA 740 ILCS 14,
  Texas CUBI, Washington RCW 19.375 and their analogues regulate biometric
  identifiers, some with private rights of action; the exemptions differ).
  Biometric templates stay on the operator's device and are never stored or
  synced. Every match is labeled inference with a confidence and requires
  moderator confirmation to publish. Photos still aid human verification;
  matching never replaces it.
- **Inference is labeled.** Auto-suggested unit↔person links carry a
  confidence and never auto-publish; publication requires moderator
  confirmation with its own citation.
- **Allegation ≠ fact.** Lawsuits store docket references, parties, and
  status verbatim; summaries never go beyond the filing. Brady entries are
  stored as released, with the releasing office named.
- **Anti-abuse.** No scoring or ranking of individuals, no *published*
  presence alerts on a person, no per-person live maps, no "leaderboards".
  The Rule 6 identification flow — an operator's own device surfacing cited
  records at the moment a confirmed match appears — is not a presence alert
  and never reaches other users until the confirmation + SafetyHold gates
  are passed. Agency-level pattern analysis only (matches the ideas bin).
  Commentary features stay absent — records tool, not a forum.
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

**Built (2026-10-15, local to the operator's Mac; nothing syncs or publishes):**

- `AccountabilityKit/Records` — `FOIARequest`/`FOIATracker` (lifecycle, statutory due dates from a table that is
  **marked unverified**, appeal/follow-up draft, released documents hashed and cited as `foiaRelease`);
  `RecordCandidate` (every importer's only output: pending, verbatim, cited) and `RecordsLedger` (accept/reject,
  idempotent re-import); `PublishedListImporter` (a CSV that a public body already published — Brady/Giglio list or POST
  register — with the releasing office named by the user); `CourtListenerClient` (free RECAP/CourtListener search) and
  `PacerClient` (user's own PACER account) turning dockets into pending `lawsuit` candidates;
  `PersonMatcher` (suggestions only, confidence always < 1); `UnitRecordsIndex`; `RecordsLedger` people steps
  (`addProfile`, `proposeLink`, `confirmLink`, `attach`, `removeProfile`) behind the Hub **People** tab — a link starts as a
  hidden inference (confidence < 1) and is confirmed only with an additional external citation; records attach to a person
  only by an explicit choice; removing a person detaches their records. `RosterImporter` reads a published roster CSV
  (name, role, optional unit columns only — everything else in the file is ignored and never stored) into pending
  `RosterCandidate`s; accepting one creates the cited profile and, when a unit and agency key are given, a hidden
  proposed link.
- **One-click roster catalogue** (`RosterCatalog`, `RosterFetcher`; Hub → Records & FOIA → People → "Police rosters"): eight
  agency employee lists published on their own governments' Socrata open-data portals — NYPD, Chicago PD, LAPD, Seattle PD,
  Cincinnati PD, Baton Rouge PD, New Jersey State Police, Vermont Dept. of Public Safety (each probed live 2026-10-15). Pick
  one, press Import: the Hub pages through the portal (5,000 rows per request, half a second apart) asking **only for the name,
  job-title and published pay columns** (salary, overtime, other pay — public-employee compensation is a public record; age,
  gender and ethnicity columns are never requested; pay values are kept verbatim as strings), keeps the latest fiscal/pay year where
  the dataset has several, and stores the snapshot locally (`records/roster-<id>.json`). Search the snapshot and "Add as
  official" to make a profile cited to the dataset page (its published pay is kept on the profile), then propose and confirm a unit link as before. The catalogue entry
  carries a best-effort agency key (`US-<state>/<place>/<service>`) used to prefill links. Names are as the portal prints them
  (some "LAST, FIRST", some "FIRST LAST" assembled from two columns). These lists are payroll data: they show who is
  *employed*, not who is *assigned to a given vehicle* — unit numbers still come from FOIA releases or agency pages.
- **PACER budget** (`PacerBudget`): spending inside the free quarterly allowance (US$30, PACER's published waiver — a
  setting, confirm on pacer.uscourts.gov) is always allowed; anything above it is allowed only up to the user's
  "allowed above free" dollar limit, **default $0 = never billed**. Estimated cost is checked before each request and the
  network is not touched when it would be refused. Credentials are typed by the user into the Keychain
  (`org.platewatch.hub.records`); the code never sees them elsewhere.
  CourtListener search was **verified live by the owner (2026-10-15)**. PACER sign-in followed PACER's documented `cso-auth`
  call (`loginId`, `password`, required `redactFlag`, `clientCode` for searches); the first live try failed ("auth failed")
  before `redactFlag`/`clientCode` were sent, and errors now show PACER's `loginResult`/`errorDescription`. 2026-10-15: with a real account the call returned **HTTP 502** (PACER's own endpoint answers dummy credentials with a normal
  "Login Failed" JSON, so the request format is accepted); the client now retries gateway errors once, shows the server's
  words, and has an optional MFA-code field (`otpCode`, UNVERIFIED name). The PCL case-search call is still **UNVERIFIED**. First live use: free allowance only.
- **Known lists** (`RecordCatalog`, `RecordSourceFetcher`; Court & lists → "Known lists"): Washington's Criminal Justice Training
  Commission officer-certification dataset (data.wa.gov, 470 revocation/surrender/hearing cases since 2002, each citing its
  final order) imports as pending `decertification` candidates with the commission's own wording. A desk survey on 2026-10-15
  found no prosecutor publishing Brady/Giglio lists as downloads (they appear as PDFs or one-off records releases — use the
  CSV import), California POST's list page refused our connection, Oregon DPSST offers a search site and a statistics
  spreadsheet only, Massachusetts POST posts PDFs. The catalogue grows as machine-readable sources are found.
- Court & lists has a **Pending / Accepted** switch. Accepted records are listed with their status and source; each can be
  *shown for an agency* (pick a catalogue agency or type its key — it then appears in Review next to that agency's recognised
  units), *attached to an official* (People), or *sent back to pending*. An accepted record attached to neither is shown
  nowhere.
- Hub → Records & FOIA → **Requests** and **Court & lists** tabs; Review shows a **cited-records strip** for the selected
  vehicle's unit.

**Location firewall, as implemented:** `UnitRecordsIndex.records(forUnit:agencyKey:)` takes only a unit number and the
recognised agency's key — no sighting, place, time or camera — so nothing it returns can say where or when anyone was
seen. It returns only moderator-confirmed `PersonLink`s and cited records, never inferences, and nothing at all when the
agency was not recognised (unit numbers repeat across agencies). Accepting a candidate stores a cited record but does
**not** link it to a person; that is a separate choice in the People tab. "Confirmed" here means *the operator confirmed
it with an external citation* on their own Mac — there is no second-person moderation or publication path yet, and none
of this syncs. Photos, face matching and live identification are still not built.

FOIA deadline table: a 2026-10-15 desk check against secondary sources (AG opinions, state guidance) supported IL, CA, MA,
WA, CT, NH and the NY acknowledgement rule; TX is a certify-or-produce rule; VA was **not** confirmed; California's 2026
AB 1821 would change its period. Entries stay `verified: false` until statute text is read; each carries a `checkedNote`.

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

## RSS / Atom feed reader (Records → Feeds)

Operator-followed feeds (agency release pages, court and news feeds) are read locally by `RSSLibrary` /
`RSSFetcher` in AccountabilityKit and stored in `records/rss-feeds.json`. Rules: https only; 3 MB and 200-entry
parse caps; no DTD/external entities; links limited to http(s); entry text is shown as plain text and treated as
untrusted data; 300 items retained per feed (starred never trimmed). "Save for review" creates a *pending*
`RecordCandidate` (kind `news`, citation `newsReport` with the entry URL and excerpt hash) — it is never auto-accepted,
person-linked or published. No feed is bundled, so no third-party endpoint is contacted until the operator adds one.

