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
