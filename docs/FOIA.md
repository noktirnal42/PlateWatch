# FOIA — drafting public-records requests about fleets

PlateWatch can draft a public-records request about an agency's vehicle fleet
and its ALPR policies (`FleetImporters/FOIARequestGenerator`). It only produces
text. It never sends anything, and it never fills in the requester's identity.

## Hub desktop interface

Open **Records & FOIA → Fleet FOIA draft**. Enter the agency, state and optional
validated unit identifiers, choose the requested record categories, then preview,
copy or save the text. Requester placeholders remain for manual completion.
The Public-records programme tab describes future cited roster/court/Brady
cross-referencing; it does not run collection or identify people in camera frames.

## What the draft asks for

- Fleet inventory: unit or asset number, make, model, year, category, and plate
  if the agency holds it.
- Unit ↔ vehicle links, so sightings can be matched to fleet records.
- ALPR policy, retention schedules, and deletion logs (optional vendor
  contracts, off by default).

## Guardrails

- **No employee or officer names.** The letter asks for records "not to include
  names of employees".
- **Unit numbers are validated.** Only `1–12` characters of `A–Z`, `0–9`, `-`,
  and `/` are accepted. Anything else (a name, an address, a plate with spaces)
  is rejected and reported back, so the letter cannot carry personal data.
- **Placeholders for the requester.** `[Your name]` and the mailing address stay
  blank until the user fills them in, in their own tool.
- **Public records only** (LEGAL-ETHICS Rule 2). Nothing here requests DMV,
  driver, or broker records.

## Filing

1. Generate the draft and review it.
2. Personalize the placeholders.
3. File through the agency's public-records portal, or through MuckRock.
4. Record the response as a `SourceCitation` with `sourceType = foiaRelease`
   (URL of the released file, retrieval date, excerpt hash). That citation is
   what makes any enrichment built on the response traceable.

## Following public-records news (Records → Feeds)

The Feeds tab is a local RSS/Atom reader for agency release pages, court feeds and public-interest publishers. Entries
can become a request draft in the Requests tracker ("Draft request from this…") or a pending cited candidate. Feeds are
read-only and https-only; see ACCOUNTABILITY-DATA.md for the storage and safety rules.

## Deadline table status

Due dates come from `FOIADeadlines`. Virginia (Va. Code § 2.2-3704(B)) was read from the statute text on 2026-10-18.
California's AB 1821 was chaptered 2026-09-30; the table keeps the current 10-calendar-day rule for requests filed
before 2027-01-01 and switches to 10 business days afterwards. The federal rule and TX, IL, MA, WA, NY, CT and NH were also read from statute text on 2026-10-18 (TX via a republication of the code because the official site is script-rendered). California's statute text could not be retrieved from the sources available and stays unverified. The tracker counts business days as weekdays only; legal holidays are not skipped.

