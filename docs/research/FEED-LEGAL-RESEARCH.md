# PlateWatch: Legal and Policy Constraints for Public Camera Feeds (research notes)

NOT LEGAL ADVICE. Research for engineering planning only; have counsel review before launch.
Date of research: 2026-10-13. Label key: VERIFIED = I read the primary text (statute/opinion/agency page) via fetch. UNVERIFIED = secondary source, search snippet, or primary text not retrievable (many .gov legislative sites returned 403).

## Topic 1: ALPR statutes (state-by-state)

Critical finding: several states regulate ALPR *use by anyone* (not only government). PlateWatch OCR of plates from camera frames fits typical statutory definitions ("cameras + computer algorithms converting plate images to computer-readable data") even if the project only wants fleet plates. Maine and New Hampshire are the highest-risk states. Whether a plate-OCR pipeline running on a third-party DOT feed is an "ALPR system" "used" by the project is an open legal question.

| State | Rule | Private/civilian reach | Source | Status |
|---|---|---|---|---|
| Maine | 29-A MRSA 2117-A: "a person may not use an automated license plate recognition system" except DOT (public safety/infrastructure), State Police CMV screening, and law enforcement for official purposes; data confidential; not stored >21 days; violation is Class E crime. Definition: one or more cameras plus algorithms converting plate images to computer-readable data. | YES, general prohibition on any "person" | https://www.mainelegislature.org/legis/statutes/29-A/title29-Asec2117-A.html | VERIFIED |
| New Hampshire | RSA 261:75-b: ALPR may be used only by local/county/state law enforcement for listed purposes; no occupant images; data purged within 3 minutes unless hit leads to arrest/citation/etc. | Effectively bars non-law-enforcement use | https://gc.nh.gov/rsa/html/XXI/261/261-75-b.htm | VERIFIED (via fetch summary; confirm exact text) |
| Virginia | Va. Code 2.2-5517: regulates law-enforcement agencies and their vendors; system data purged after 21 days, audit trail 2 years; excludes non-criminal-justice uses by state/local/private entities | Not a general private ban; vendors to LE must certify | https://law.lis.virginia.gov/vacode/title2.2/chapter55.7/section2.2-5517/ | VERIFIED |
| Minnesota | Minn. Stat. 13.824: LE agency ALPR data destroyed within 60 days absent active investigation; definition also reaches privately owned readers whose data are shared with law enforcement; sharing of non-investigative data restricted | Reaches private devices only if data shared with LE | https://www.revisor.mn.gov/statutes/cite/13.824 | VERIFIED |
| Arkansas | Ark. Code 12-12-1801 to -1808: general unlawfulness of ALPR operation by individuals/companies/govt except listed uses (law enforcement, parking, secure-area access). 2025 Act 668 reportedly added private landowners/businesses; 60 days private, 150 days others | YES, general prohibition with exceptions | NCSL table (read) https://www.ncsl.org/technology-and-communication/automated-license-plate-readers-state-statutes ; statute text not retrieved | UNVERIFIED (secondary) |
| California | Civ. Code 1798.90.5-.55: ALPR operators and end-users must maintain security safeguards and a public usage and privacy policy; public agencies may not sell/share ALPR info except to other public agencies. Definitions cover "operator" generally (includes private entities), excluding certain transportation agencies. Bartholomew v. Parking Concepts (Cal. Ct. App. 2026) addresses private operator policy duties. | YES, private operators must have policy and safeguards; no fixed retention in the statute for private | Statute (leginfo 403); summaries: https://www.bart.gov/sites/default/files/docs/ALPR%20ANNEX%20CA%20Civil%20Code%20Sections%201798.90.51%20and%201798.90%20.53.pdf | UNVERIFIED (search summary only) |
| Washington | SB 6002 (2026) "Driver Privacy Act" reportedly enacted March 2026: 21-day purge, warrant for private-vendor data, 2-yr access logs, no civil-immigration use. Codification not confirmed. | Mostly agencies; warrant required for private-vendor data | https://washingtonstatestandard.com/2026/03/06/automated-license-plate-reader-regulations-close-to-becoming-wa-law/ ; https://www.aclu-wa.org/news/washington-enacts-first-regulations-on-license-plate-readers/ | UNVERIFIED |
| Colorado | C.R.S. 24-72-113: government "passive surveillance records" (incl. traffic/ALPR cameras per news) destroyed after 3rd anniversary; access after 1 year limited. Applies to government custodians. | Government only | https://colorado.public.law/statutes/crs_24-72-113 | UNVERIFIED (snippet) |
| Connecticut | 21-day retention, private vendors limited to specified purposes (2026 roundup via NCSL) | Yes for vendors | NCSL table | UNVERIFIED |
| Idaho | Non-law-enforcement use prohibited (per NCSL) | Yes | NCSL table | UNVERIFIED |
| Kentucky | Use unlawful except listed purposes; 90 days | Yes | NCSL table | UNVERIFIED |
| Utah, Vermont, Oregon, Illinois, Iowa, NC, TN, GA, MT, NE, NM, AL, KS, MD, NJ | Government-focused retention/use rules (Utah 9 mo, Vermont 18 mo, Oregon 30 d, Illinois 120 d expressway cams, Iowa 30 d, NC 90 d, TN 90 d, GA 30 mo, MT 90 d/18 mo, NE 180 d, AL 5 yr). NM: privately captured data shared only by consent/court order. | Mostly not addressed for private | NCSL table | UNVERIFIED |
| Florida | FDOT memo (Aug 31, 2026) revoked approvals for LE LPR on state highway right-of-way under s. 316.0777; not a statute-based general ban | Government placement only | https://thecapitolist.com/fdot-revokes-permits-for-license-plate-readers-on-state-highways/ | UNVERIFIED |
| Texas | Governor directive pausing TxDOT permits for ALPR on state roads (Sept 2026); no private statute found | n/a | https://www.kbtx.com/2026/09/18/texas-freezes-installation-flock-cameras-along-state-roads/ | UNVERIFIED |
| New York | Not in NCSL table; no ALPR-specific statute found | n/a | NCSL table | UNVERIFIED (absence) |

(Sections for Topics 2-7 follow below as researched.)

## Summary table by topic

| # | Topic | Rule / finding | Jurisdiction | Primary source URL | Status |
|---|---|---|---|---|---|
| 1 | ALPR use by any "person" | Maine bans all non-listed ALPR use, 21-day retention, Class E crime | ME | https://www.mainelegislature.org/legis/statutes/29-A/title29-Asec2117-A.html | VERIFIED |
| 1 | ALPR limited to law enforcement | NH RSA 261:75-b: LE only, 3-minute purge | NH | https://gc.nh.gov/rsa/html/XXI/261/261-75-b.htm | VERIFIED |
| 1 | Private operator duties | CA Civ. Code 1798.90.5-.55: policy + safeguards for "operators" | CA | summary: https://www.bart.gov/sites/default/files/docs/ALPR%20ANNEX%20CA%20Civil%20Code%20Sections%201798.90.51%20and%201798.90%20.53.pdf (statute text 403) | UNVERIFIED |
| 2 | DOT cameras: "not recorded" statements | Arkansas ARDOT: "does not record or store traffic camera images"; Iowa DOT: recordings "briefly retained but not archived" | AR, IA | https://site.idrivearkansas.com/index.php/policies/camera-terms-of-use/ ; https://iowadot.gov/policies_and_statements/Terms-of-Use | VERIFIED (agency pages) |
| 2 | Statutes restricting analysing/storing public traffic-camera frames | None found for private parties. Government-custodian retention rules exist (CO 3 yr, IL expressway 120 d per NCSL). ALPR statutes (Topic 1) are the real constraint if OCR of plates counts. | multi | NCSL table | UNVERIFIED (absence of finding) |
| 3 | CFAA | Van Buren: "gates-up-or-down"; Court left open whether policy/contract limits count (n.8) | Federal | https://www.law.cornell.edu/supremecourt/text/19-783 | VERIFIED (summary of opinion text via fetch) |
| 3 | CFAA / public pages | hiQ v. LinkedIn, 41 F.4th 1180 (9th Cir. 2022): scraping public pages likely not "without authorization"; PI posture; contract claims survive (hiQ later lost on User Agreement breach, N.D. Cal. Nov 2022) | 9th Cir. | https://cdn.ca9.uscourts.gov/datastore/opinions/2022/04/18/17-16783.pdf (binary, not read) | UNVERIFIED (secondary) |
| 3 | Contract/ToS vs. logged-off scraper | Meta v. Bright Data (N.D. Cal. Jan 2024): terms govern "use" by account holders; X Corp v. Bright Data (N.D. Cal. May 2024): claims preempted/dismissed with leave to amend | N.D. Cal. | Proskauer note https://newmedialaw.proskauer.com/2024/05/14/california-court-issues-another-noteworthy-decision-dismissing-breach-of-contract-and-tort-claims-in-web-scraping-dispute/ | UNVERIFIED (district courts, persuasive only) |
| 3 | Government site terms on automation | Iowa DOT: no "robots, spiders", no more requests "than a typical human"; no framing/reproducing site without written consent. Arkansas: no embedding live images; screenshots must keep owner logo; owner copyright; some feeds owned by TV stations. PennDOT 511PA developer terms: images only to show current traffic status, other use requires written approval, attribution required. | IA, AR, PA | Iowa/AR URLs above; PA https://prdpenndot.pwpca.pa.gov/Doing-Business/OnlineServices/Documents/511PA_Developers_Corner-T+Cs.pdf | IA, AR VERIFIED; PA UNVERIFIED (snippet; host unreachable) |
| 4 | BIPA | 740 ILCS 14/10: biometric identifier = retina/iris scan, fingerprint, voiceprint, scan of hand or face geometry; photographs excluded, but courts split on photo-derived face templates (Onfido vs Shutterfly) | IL | https://lig.ilga.gov/legislation/ilcs/documents/074000140K10.htm (cert error) | UNVERIFIED (search excerpt) |
| 4 | Texas CUBI | Bus. & Com. Code 503.001: capture of biometric identifier (incl. "record of hand or face geometry") for commercial purpose requires notice + consent; destroy within 1 year of purpose ending; AG civil penalty up to $25,000 per violation; no private right of action | TX | https://texas.public.law/statutes/tex._bus._and_com._code_section_503.001 (mirror) | VERIFIED via statute mirror |
| 4 | Washington biometric | RCW 19.375.020: no enrolling a biometric identifier in a database for commercial purpose without notice/consent mechanics; definitions section not read | WA | https://apps.leg.wa.gov/rcw/default.aspx?cite=19.375.020 | PARTIAL: 19.375.020 VERIFIED, definition UNVERIFIED |
| 5 | Copyright of government works | 17 USC 105 covers federal works only; state/local governments may hold copyright; camera owner may be a private TV station (AR) | Federal/state | https://www.govinfo.gov/content/pkg/USCODE-2020-title17/html/USCODE-2020-title17-chap1-sec105.htm | VERIFIED as to s.105 existence via search; text not read. State-law position UNVERIFIED |
| 6 | Right to record police | Glik v. Cunniffe, 655 F.3d 78 (1st Cir. 2011); Turner v. Driver, 848 F.3d 678 (5th Cir. 2017) (First Amendment protects recording, subject to time/place/manner); Fields v. Philadelphia (3d Cir. 2017). All dealt with human recording, not automated mass capture. | Federal circuits | https://en.wikipedia.org/wiki/Glik_v._Cunniffe ; https://www.ca5.uscourts.gov/Opinions/pub/16/16-10312-CV0.pdf | UNVERIFIED (secondary) |
| 6 | Buffer zones | IN and LA 25-ft laws enjoined for vagueness (LA M.D. La.; IN 7th Cir. Aug 2025 per press). Irrelevant to fixed/remote cameras unless a handheld contributor approaches officers. | IN, LA | https://indianacapitalchronicle.com/2025/08/06/appeals-court-upholds-block-on-indianas-25-foot-police-buffer-law-citing-vagueness/ | UNVERIFIED |
| 7 | Publishing police location | No statute found banning publication of police vehicle locations. NYPD (2019) threatened Google/Waze on an obstruction theory; ACLU counters with First Amendment. Doxxing laws (NJ Daniel's Law, MN 609.5151, CO) target home addresses/personal info; CO law reportedly covers photos of a home or vehicle (secondary). | multi | https://abajournal.com/news/article/nypd-to-google-stop-pinpointing-police-activity ; https://www.revisor.mn.gov/statutes/cite/609.5151 | UNVERIFIED |
| 7 | Undercover/confidential plates | WA WAC 308-96A-080: agencies get undercover or confidential plates; undercover records show fictitious names. IL 625 ILCS 5/3-422 similar (not read). | WA, IL | https://www.law.cornell.edu/regulations/washington/WAC-308-96A-080 | WA VERIFIED; IL UNVERIFIED |
| 1/6 | Aggregated tracking (Fourth Amendment) | Schmidt v. City of Norfolk (E.D. Va., Jan 2026, 819 F.Supp.3d 492), on appeal 4th Cir. No. 26-1227. Applies to government, but signals mosaic concern; outcome not confirmed. | VA/4th Cir. | https://www.leagle.com/decision/infdco20260130846 | UNVERIFIED |

## Topic notes

2. Public traffic cameras. Some DOTs state they do not record (AR, IA), so a downstream project that stores frames is creating a record the agency says it does not hold. That is not illegal per se but is contrary to the feed's public expectation and could draw agency objection. Terms of use can attach even where no statute applies. No statute found that restricts a private party from analysing or storing frames.

3. Terms of use. After Van Buren and hiQ (Ninth Circuit only), CFAA exposure for polling public, ungated camera pages looks low, but (a) open footnote 8 in Van Buren, (b) other circuits not bound, (c) breach-of-contract and state computer-crime theories remain, (d) an IP block or cease-and-desist followed by continued access is the classic revocation fact pattern. Respect robots.txt, rate-limit below a human, honor written objections.

4. Biometrics. Design guarantee: no face detection, face embeddings, gait, voice, or person re-identification anywhere in the pipeline; vehicle detector classes only; blur or drop any frame region classified as person; no storage of occupant-visible crops. This keeps the project outside BIPA/CUBI/RCW 19.375 triggers (all keyed to capture of biometric identifiers). BIPA risk analysis is nuanced because courts have split on photo-derived data, so "never compute face geometry" is the stronger guarantee than "we only keep photographs."

5. Public records. Camera images held by a government may be public records, but copyright can still sit with the agency or a private owner. Record the licence statement per source, do not assume public domain.

6. Right to record is a defence for human recording of police in public; it does not expressly address automated, persistent capture of plates by a project, and does not override ALPR statutes.

7. Officer safety. No identified statute prohibits publishing marked-vehicle sightings, but the optics and obstruction-style claims (NYPD/Waze) are real, and unmarked/undercover vehicles are specifically protected by confidential-plate regimes.

## DESIGN GUARDRAILS for the Hub

Retention and storage
1. Do not retain raw frames. Process in memory; persist only the sighting row (timestamp, source id, agency, vehicle class, plate-derived fleet id if matched) and, optionally, a cropped vehicle thumbnail. Default raw-frame retention: 0 seconds (never written to disk).
2. Non-matching plate reads are discarded immediately (no plate text persisted unless matched to a known fleet registry or a clearly official plate format). This aligns with the "no un-redacted private-citizen plates" guardrail and with the 3-minute (NH) to 21-day (ME, VA, CT, WA) retention norms.
3. Hard cap on any persisted sighting detail: 21 days at full precision; older rows reduced to aggregates (agency/day/area counts). Make this a server-enforced TTL, not a client option.
4. Maintain an audit log of access (2-year logs are the norm in VA/WA for agencies) with no plate lookup interface for the public by plate number.

Redaction and biometrics
5. Person/face exclusion: no face/person models; mask pedestrian and occupant regions; reject any contributor upload containing identifiable faces unless blurred on-device.
6. Fleet-only gate: sighting is published only if the vehicle is classified as government fleet by livery/marking/plate class/registry match; otherwise the record is dropped. Private-vehicle data never leaves the device.

Aggregation delay and location fuzzing
7. Publish with a delay (suggest minimum 24 to 72 hours, tunable per class; longer for law enforcement) so the data cannot be used for live tracking or evasion; never offer a "live police map".
8. Geographic coarsening: publish at camera-region or ~1 km/census-tract level for law enforcement; exact camera id only for non-enforcement fleet (transit, public works) where counsel agrees.
9. Aggregate-by-default: expose counts and fleet-utilisation stats per agency and period, not per-vehicle trails. Suppress per-vehicle timelines that would reconstruct a movement pattern (mosaic concern).
10. Minimum-k suppression: do not publish cells with fewer than k sightings (e.g., k=3) in the reporting window.

Exclusions
11. Exclude unmarked, undercover, confidential-plate, and personal vehicles of employees. If a vehicle is only identifiable through a plate lookup (not livery), do not publish.
12. Exclude sensitive classes by default: SWAT/tactical, protective details, school buses with children visible, ambulances showing patients, federal agencies.
13. Jurisdiction gate: ship with ALPR-ban states disabled by default (at least Maine and New Hampshire; treat Arkansas, Idaho, Kentucky, Connecticut as disabled pending counsel). Geofence source feeds and contributors by state at ingest.
14. Takedown: agency/individual takedown channel, honoured within a short SLA; tombstone prevents re-ingest.

Source terms recording
15. For each feed, store a source record: URL, operator, ToS URL, ToS retrieval hash and date, licence/copyright statement, stated recording policy ("does not record"), required attribution, whether a developer agreement exists, polling rate permitted, and a legal-review status (approved/blocked/pending).
16. Respect robots.txt; poll no faster than the agency's stated refresh and below human request volume; send an identifying User-Agent with contact URL; stop and flag on 403/429/IP block or written objection (do not rotate IPs or evade blocks).
17. Do not frame or embed live feeds; keep owner logo/attribution on any displayed image (AR terms).
18. Prefer official data-feed programs (e.g., 511 developer APIs, DATEX/open data) and obtain written permission where terms prohibit non-traffic uses (PennDOT).
19. Log provenance (SourceCitation) for each sighting: feed id, capture time, ToS version at capture.

Privacy and governance
20. Publish a usage and privacy policy covering collection, retention, access, sharing, and security (this mirrors the California operator policy requirement and is good practice everywhere).
21. No sale/sharing of raw data; no law-enforcement data-sharing interface; document a response protocol for subpoenas (data minimisation makes this largely moot).
22. Handheld contributors: in-app guidance not to approach officers or interfere; no feature that targets a named individual; no home-address or off-duty logging.

## Open questions for counsel
1. Does running OCR on plates of third-party DOT camera frames make the project an "operator/user" of an ALPR system under Maine 2117-A and NH 261:75-b? Would on-device-only processing, immediate discard of non-fleet reads, or detection by livery alone (no plate OCR) change the answer? Should those states be geoblocked?
2. Arkansas, Idaho, Kentucky, Connecticut: confirm current statute text and whether "operation" by a remote processor of a lawfully published image is covered.
3. California: is the project an "ALPR operator" or "end-user" (1798.90.5), and does the transportation-agency exclusion matter? Confirm the Bartholomew v. Parking Concepts holding.
4. Washington SB 6002 (2026): confirm codification and whether private processors are covered.
5. Enforceability of DOT/511 terms against a project that never agrees to them (browsewrap); effect of hiQ outside the 9th Circuit; state computer-crime statutes (e.g., Cal. Penal Code 502 and equivalents) not researched here.
6. Whether DOT-published images carry copyright (state law varies) and whether derived data (sighting rows, thumbnails) is safe to publish; whether public-records laws (not researched) make DOT-held frames available instead through a records request or data-sharing agreement.
7. Does publication of delayed, aggregated police-vehicle sighting data raise obstruction, officer-safety, or state doxxing-law risk (e.g., CO law covering photos of a vehicle), and what delay/aggregation threshold counsel is comfortable with?
8. BIPA/CUBI/RCW 19.375: confirm that vehicle-only detectors with person masking are outside scope; confirm whether incidental faces in stored thumbnails matter.
9. Fourth Amendment/mosaic exposure for a private actor republishing aggregated movement (Schmidt v. Norfolk, 4th Cir. No. 26-1227) and state constitutional privacy provisions.
10. Contributor liability: terms of service for handheld captures, wiretap/eavesdropping statutes if audio is captured (disable audio).

## Research gaps (not covered or unverified)
Many legislative sites (leginfo, Justia, ILGA) returned 403/cert errors; NCSL's table was read but is secondary. Not researched: state computer-crime statutes, state public-records statutes on camera images, Oregon/Utah/Vermont/Illinois/Colorado/Texas/Florida/New York statute text, and any 2026 enactments after the NCSL table.
