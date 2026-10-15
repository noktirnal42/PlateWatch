# Published Brady/Giglio CSV conversion — October 14, 2026

The owner requested actual import files for the two previously linked sources. Separate extraction agents produced and checked 223 rows from the 50-a.org DA adverse credibility index and 44 rows from ABC15's embedded MCAO Tier 2 table, dated April 7, 2023. The named datasets, raw inputs, scripts, hashes and instructions are local delivery artifacts outside the repository; no live database records were created during conversion.

The actual `PublishedListImporter` accepted 223 and 44 candidates, all pending, with names and source URLs. Export rows fit its 600-character excerpt limit (NYC maximum 414; Arizona 598). NYC status/date are blank where the index supplies none; Arizona preserves 42 literal `TIER 2` statuses and two `-` values. Departure/status dates remain original fields, never inferred incident dates. Historical/third-party inclusion is not a current misconduct finding.

The Hub CSV dialog now exposes a published source URL and agency column, pre-fills standard `name`, `agency`, `reference`, `status` headers, and rejects invalid source URLs before import. Source URLs populate `SourceCitation.url`; per-row URLs/original fields remain in the excerpt. The signed Hub build and 13 hostless tests passed. Native visual confirmation of the dialog remains subject to the computer-use helper limitation recorded in the QA handoff.

## Source documents

- [50-a.org DA adverse credibility index](https://www.50-a.org/credibility), 223 linked names at retrieval; underlying DA documents and present-day individual status were not separately verified.
- [ABC15 article](https://www.abc15.com/news/local-news/investigations/brady-list/database-mcaos-more-secretive-brady-list) and its [published Datawrapper CSV](https://datawrapper.dwcdn.net/h8vCB/2/dataset.csv), 44 rows as of April 7, 2023. The original publisher CSV is retained with the local export.

## Additional-source research

# Additional US Brady/Giglio sources

Checked October 14, 2026 (America/Los_Angeles). `sources.csv` is a catalogue of 8 source-level leads, **not an officer import CSV**. No individual records were collected in this research task. Availability does not establish redistribution rights or automated-collection permission; freshness is recorded separately from retrieval.

## Best next conversions

1. **Deschutes County, Oregon:** [DA-issued 2025 Brady list hosted by OPB](https://www.opb.org/pdf/Brady%20List%202025_1744655988491.pdf) is a readable one-page text PDF with Tier 1 and Tier 2 headings. Strongest small conversion candidate. Preserve tiers verbatim; obtain the applicable policy rather than guessing what each tier means. Internal document date is absent; 2025 comes from the filename.
2. **Vermont:** [ACLU Vermont's database page](https://www.acluvt.org/vermont-brady-letter-database/) links a [public Airtable](https://airtable.com/app8VTGJ9e4OblhDh/shrJ4eNWJ1ROMWtBR/tblnbyRpnRt03MfI8/viwCU2PIH3MXP4nzo) and original letters obtained from state's attorneys. Page explicitly labels its database June 8, 2022. Table rows and export availability were not verified; use the publisher's offered export, if enabled, or request one.
3. **Brooklyn, NY:** [Official Brooklyn DA release](https://www.brooklynda.org/2021/08/02/brooklyn-district-attorney-eric-gonzalez-releases-his-offices-disclosure-letters-regarding-police-officers-in-brooklyn/) points to [WNYC/Gothamist Datawrapper](https://datawrapper.dwcdn.net/hcA3n/5/). Historical March 5, 2021 snapshot; 10,162 letters, and only about two thirds have disclosures. Do not mark everyone in this collection as having an adverse credibility finding. Dynamic table landing resolved, but contents/export were not verified.
4. **Massachusetts original releases:** StateReference hosts fulfilled public-records collections from [Middlesex](https://www.statereference.com/items/pr_requests/574), [Essex](https://www.statereference.com/items/pr_requests/603), and [Hampden](https://www.statereference.com/items/pr_requests/697). They list a Discovery Notice Master List (January 26, 2023), Database Contents COMBINED, and LEAD (January 27, 2023), respectively. Inventories are verified; PDF retrieval in this tool failed at signed attachment redirects. Preserve stable inventory/attachment URLs, not expiring asset signatures; manually inspect original release and outcomes before converting. These are candidates, not verified import-ready exports.

## Useful leads with concrete limitations

- [New Hampshire DOJ Exculpatory Evidence Schedule](https://www.doj.nh.gov/exculpatory-evidence-schedule) returned HTTP 403. No bypass attempted. [Official NH Law Library guide](https://courts-state-nh-us.libguides.com/c.php?g=1103147&p=8042696) provides background. Obtain a current official PDF manually or by public-records request; do not substitute an undated mirror as current state data.
- [Suffolk DA's LEAD announcement](https://www.suffolkdistrictattorney.com/press-releases/items/items/2020/9/26/o7c84damgt0h2ib6s0czowjqusdhfh) is accessible but historical (September 2020), with no current downloadable names on that page. Names can be removed, including after exoneration or appeal, so request a current release.
- [Dallas County DA notices](https://www.dallascounty.org/government/district-attorney/notices.php) lists specific Brady disclosure and Youngkin materials. It is not a verified full officer Brady list. The Youngkin list may concern affected cases, so do not map rows to officers without inspecting the document.
- [Colorado First DA's guide](https://firstda.co/resources/peace-officer-credibility/) links the [official POST portal](https://post.coag.gov/s/). Portal rendered a CSS error in web retrieval. Its categories cover certification, employment, investigation and untruthfulness matters: not every entry is a Brady/Giglio designation. [Boulder DA policy](https://assets.bouldercounty.gov/wp-content/uploads/2024/06/Peace-Officer-Credibility-Disclosure-Policy.pdf) is accessible, but is policy rather than names.
- [North Carolina 2024 Giglio report](https://www.ncleg.gov/Files/Library/agency/doj17714.pdf), dated February 27, 2025, is **aggregate reporting only** and expressly omits identifying information. It cannot populate officer profiles.

## Arizona and source classification

The separate ABC15 extraction work is the primary Arizona task. Additional searching found an [ABC15/Scripps-hosted Rule 15 report](https://ewscripps.brightspotcdn.com/fc/d7/dfc20b594785a2ef17c5f8a45b48/rule-15-list.pdf) dated February 7, 2025; send this to that extractor to determine whether it is already the user's article attachment. Do not combine two versions without preserving version dates and original statuses.

[Arizona POST Integrity Bulletins](https://post.az.gov/compliance/integrity-bulletins) are a different source class. Many describe anonymized scenarios and certification outcomes; they are not named Brady lists and cannot safely supply names by inference. Similarly, generic complaint datasets and commercial sites branded “Brady List” are not interchangeable with an actual prosecutor-issued disclosure list.

## Collection and import requirements

- Confirm terms, robots and permitted access before recurring collection; public accessibility alone is insufficient. No login, CAPTCHA or refusal bypass.
- Each import needs publisher, original document URL, document/snapshot date, retrieval date, agency, verbatim status/category, and row/page citation. Keep separate records across dated releases.
- Retain allegations, sustained findings, dispositions, exonerations and removals distinctly. Name-only matching is unresolved until additional agency/identifier evidence and human review.
- Preserve official redactions. Do not infer private identities or restore redacted information. Do not link records to face recognition or field-camera person tracking.
- Seek current releases before asserting current designation. This research proves discovery/access status only, not completeness or statewide coverage.
