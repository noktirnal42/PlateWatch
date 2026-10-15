# Where plate reading is on, and where it is off

**Not legal advice.** This is how the software behaves today and why, based on `docs/research/FEED-LEGAL-RESEARCH.md`
(statute text read where marked VERIFIED, secondary sources otherwise). The statutes change; counsel should confirm
before anyone relies on this list. Owner position (2026-10-14): PlateWatch is not an ALPR in the usual sense, so it is not
"ALPR use". **2026-10-15:** the owner reports that counsel's view is that neither OCR of plates on third-party public
feeds nor handheld use is ALPR "use". That view is relayed, not documented: **no written opinion is in the repo**, and its scope
(which states, which designs) is unknown. On the owner's instruction the default was relaxed accordingly: **no state is
disabled by default** (`JurisdictionPolicy.platesDisabledByDefault` is empty). The previous list is kept as
`platesConservativeStates` and can be restored in one line (see "Gaps to close"). Please file counsel's written opinion
next to this page and cite it here.

## What "plate reading off" means

Only plate **text recognition** is switched off. Everything else still runs: vehicle detection, fleet lettering and unit
numbers read from doors, agency identification, and sightings. Off means the recognizer is not run at all (not merely
hidden), so nothing is read and nothing can be stored.

## How the Hub decides (`PlateKit.JurisdictionPolicy`)

1. A camera or home location is mapped to the states that have a catalogued place within **30 km** of it.
2. If **any** of those states is in the active "off" set, plate reading is **off** for that source. The active set is **empty by default** (see top); with the conservative list restored, this is why a camera
   just across a state line from Maine or New Hampshire is also off).
3. If the location is **unknown**, or no US place is catalogued within 30 km (including anywhere outside the US), plate
   reading is **off** — the gate fails closed.
4. Otherwise plate reading is **on**, and the redaction gate still applies: plates are persisted only for
   fleet-confirmed vehicles (`docs/LEGAL-ETHICS.md`).

Set the Hub's home location in **Settings → Home location** (Use my location, latitude/longitude, or a Plus Code).
Public feeds use each camera's own catalogued position, not the home location.

## Previously off by default (now reference data, not enforced)

These were the default-off states until 2026-10-15. They remain in `platesRestricted` / `platesPendingCounsel` and are enforced only if `platesConservativeStates` is passed.

| State | Why | Status |
|---|---|---|
| Maine | 29-A MRSA §2117-A: a person may not use an automated licence plate recognition system except listed public uses | Statute text read (VERIFIED) |
| New Hampshire | RSA 261:75-b: ALPR only by law enforcement for listed purposes | Statute text read (VERIFIED) |
| Arkansas | Ark. Code 12-12-1801 to -1808: ALPR operation unlawful except listed uses; 2025 amendments reportedly extend it | Pending counsel (secondary source) |
| Idaho | Non-law-enforcement use prohibited (per NCSL) | Pending counsel (secondary source) |
| Kentucky | Use unlawful except listed purposes (per NCSL) | Pending counsel (secondary source) |
| Connecticut | Retention limits and restrictions on private vendors (per NCSL) | Pending counsel (secondary source) |

Plus the **30 km border margin** around each of these, when enforced.

## On by default, with notes (reviewed)

| State | Note |
|---|---|
| California | Civ. Code 1798.90.5–.55: "operators" and "end-users" need security safeguards and a public usage and privacy policy. Publish one (research item 20). Open question whether the project is an operator. |
| Minnesota | Minn. Stat. 13.824 is aimed at law-enforcement data, but its definition can reach privately owned readers whose data are shared with law enforcement. |
| Virginia | Va. Code 2.2-5517 regulates agencies and their vendors; not a general private ban. |
| Colorado | Retention rules for government custodians. |
| Utah, Vermont, Oregon, Illinois, Iowa, North Carolina, Tennessee, Georgia, Montana, Nebraska, New Mexico, Alabama, Kansas, Maryland, New Jersey | Government-focused retention and use rules; no general private-use ban found. Iowa DOT's site terms separately limit automated request rates. |
| Florida | Only a transportation-department permit action for law-enforcement readers on state rights-of-way; no general ban. |
| Texas | A state directive on permits for law-enforcement readers; no private-use statute found. |

## On by default, desk-reviewed 2026-10-15

Alaska, Arizona, Delaware, District of Columbia, Hawaii, Indiana, Louisiana, Massachusetts, Michigan, Mississippi, Missouri,
Nevada, New York, North Dakota, Ohio, Oklahoma, Pennsylvania, Rhode Island, South Carolina, South Dakota, Washington,
West Virginia, Wisconsin, Wyoming. No general private-use ban found; details, citations and a watch-list of pending bills
are in [`research/STATE-ALPR-SWEEP-2026-10-15.md`](research/STATE-ALPR-SWEEP-2026-10-15.md). Secondary sources only; statute text
not read. **Washington** enacted a Driver Privacy Act (SB 6002, March 2026) whose reach to private operators is unconfirmed.

## Outside the United States

Still off everywhere (no US place within 30 km). Canadian, Finnish, Singaporean and other feeds can still be used for vehicle
and fleet detection, but not plate reading.

## Gaps to close

- **Counsel's written opinion** is not in the repo. The relaxation rests on the owner's report of it. File it here and cite it.
- To restore the conservative behaviour: in `JurisdictionPolicy`, make `platesDisabledByDefault` return `platesConservativeStates`
  (the tests in `IdentityTests` pass it explicitly, so they will keep passing), update this page, run the PlateKit tests.
- Unknown location and non-US locations stay **off**: counsel's view as relayed concerned US statutes. Say so to counsel if
  non-US feeds matter.
- Statutes to watch for private-operator reach: Washington SB 6002 (March 2026), California Civ. Code 1798.90.5 (operator duties);
  pending MI HB 5492, NY A563A (`research/STATE-ALPR-SWEEP-2026-10-15.md`).
- The state lists live in `packages/PlateKit/Sources/PlateKit/Identity/JurisdictionPolicy.swift`.
- The handheld iPhone app uses the same gate (`PlateReadingGate`, per frame, from the phone's coarse location or an imported photo's
  own GPS; unknown location ⇒ plates off). The Watch app does no analysis.
