# PlateWatch research: transit / federal / fleet reference sources

Date: 2026-10-13. Method: WebFetch/WebSearch only, read-only, one catalogue/terms page per source. Two passes (first pass hit a usage limit; second pass filled gaps).

Labels: VERIFIED = official page fetched and read. UNVERIFIED = search snippet / third-party mirror only. NOT REACHED = not researched or fetch failed.
Important: no Part A source found publishes police/fire/EMS camera feeds. Transit sources below are GTFS-realtime vehicle positions, not images. No claim here is a legal opinion.

## Part A - camera / feed sources

| # | Source | Access | Key? | Catalogue URL | Cadence | Licence / terms | Automated-use rule | Verdict |
|---|---|---|---|---|---|---|---|---|
| A1 | MBTA V3 API (vehicle positions, not cameras) | REST + streaming | Key recommended for default rate limit/streaming (VERIFIED, mbta.com/developers/v3-api) | https://api-v3.mbta.com/docs/swagger/index.html | Near real-time | VERIFIED (PDF read, https://cdn.mbta.com/sites/default/files/2023-08/mbta-massdot-develop-license-agreement.pdf): MassDOT grants "non-exclusive, limited, and revocable rights to use, reproduce, and redistribute the Data"; must "Clearly acknowledge MassDOT as the provider"; no logos/trademarks; may combine with other data; MassDOT may alter terms/suspend data without notice. No commercial-use ban found in text | None stated beyond API rate limits | usable with key + attribution |
| A2 | King County Metro GTFS / GTFS-RT | Feeds | Not stated | https://kingcounty.gov/en/dept/metro/rider-tools/mobile-and-web-apps | n/a | VERIFIED: "limited, revocable license to use, reproduce, and redistribute the Data"; must display "Transit scheduling, geographic, and real-time data provided by permission of King County."; GTFS-RT must be used with Metro GTFS | None stated | usable with attribution |
| A3 | NYC MTA developer feeds | GTFS-RT; Bus Time | Buses: account + API key (VERIFIED, https://www.mta.info/developers); subway/rail/alerts: page does not require a key | https://www.mta.info/developers ; https://api.mta.info/ | Not stated for RT | VERIFIED: "Our data feeds are free to use", subject to terms and conditions (text not read); logos/maps need a licence | Not stated | keyed (bus) / read terms first |
| A4 | WMATA | REST | Sign-up links on page | https://developer.wmata.com/ | n/a | VERIFIED (homepage): "free of charge"; Developer License Agreement not read (Terms URL guessed, 404) | Not stated | keyed / ask-first |
| A5 | Transitland | REST aggregator | Yes | https://www.transit.land/documentation | - | VERIFIED: datasets free for non-commercial use; per-feed licences vary | Rate limits on free tier | keyed; useful for finding per-agency licences |
| A6 | SEPTA, TriMet, CTA | - | - | - | - | SEPTA: data.gov metadata only points to a generic "other" licence (UNVERIFIED). TriMet: only an old reference to a developer agreement (UNVERIFIED). CTA: nothing found | - | NOT REACHED |
| A7 | 511.org (SF Bay) | REST | HTTP 401 on fetch | https://api.511.org/ | - | Not read | - | NOT REACHED |
| A8 | City of Seattle (SDOT) traffic cams (WSDOT-sourced images) | Still-image pages | No | https://www.seattle.gov/trafficcams/ | ~1-4 min (UNVERIFIED snippet) | UNVERIFIED snippet: City "does not archive or retain" images; may suspend access any time; dataset listing says "no license information was provided" | Not stated | ask-first |
| A9 | Port of Seattle, PANYNJ, Golden Gate, Florida's Turnpike, E-ZPass, Texas toll, Ports of LA/LB | - | - | - | - | Port of Seattle image library (not cameras) is copyrighted (UNVERIFIED snippet). Earlier terms URLs for Port of Seattle and PANYNJ returned 404. No camera terms found for others | - | NOT REACHED |
| A10 | NPS webcams | Still images on park pages | No | Catalogue page https://www.nps.gov/subjects/digital/webcams.htm returned 404 (VERIFIED miss) | Varies | UNVERIFIED (third-party archive snippet): NPS disclaimers say webcam images are public domain, credit NPS requested | Not stated | probable-usable; confirm per-cam disclaimer |
| A11 | NWS | Web content | No | https://www.weather.gov/disclaimer | - | VERIFIED: pages "in the public domain, unless specifically noted otherwise"; use "without charge for any lawful purpose" without implying endorsement or modifying and presenting as official | Not stated | usable (no fleet-relevant cams known) |
| A12 | USGS | Web content | No | https://www.usgs.gov/information-policies-and-instructions/copyrights-and-credits | - | VERIFIED: "USGS-authored or produced data and information are considered to be in the U.S. Public Domain."; non-USGS items may be copyrighted | Not stated | usable (no fleet-relevant cams identified) |
| A13 | NOAA GLERL webcams | Still images | No | https://www.glerl.noaa.gov/metdata/docs/webcam_disclaimer.html | Not stated | VERIFIED: "Information presented on these pages is considered public information and may be distributed or copied."; credit requested; images "as is", for entertainment not safety | No explicit crawl rule | usable (lake scenery, not fleet-relevant) |
| A14 | NOAA NDBC BuoyCAM | `https://www.ndbc.noaa.gov/buoycam.php?station=xxxxx` | No | http://www.ndbc.noaa.gov/faq/buoycamlinks.shtml | Daylight only; none if >16 h old | VERIFIED: page has no licence/terms statement; says retry no sooner than 30 minutes after "Unable to access" error | Polite-retry guidance only | ask-first (government work, but not stated) |
| A15 | USACE, USCG, USFS, BLM, county sheriff / EM / campus cams | - | - | - | - | No policy found | - | NOT REACHED |
| A16 | explore.org | Website | n/a | https://www.explore.org/terms-of-service | - | VERIFIED: no copying/redistribution without written permission; personal non-commercial; bots/spiders prohibited | Automated copying prohibited | not-usable |
| A17 | Open CC webcams | - | - | https://www.raptorresource.org/about-us/licensing-and-rights/ ; https://www-origin.novascotiawebcams.com/copyright | - | UNVERIFIED snippets: Raptor Resource and Nova Scotia Webcams use CC BY-NC-SA (Nova Scotia footer also says "All rights reserved") | - | NC licence; wildlife/scenic, not fleet-relevant; not-usable for project |

## Part B - reference datasets

| # | Source | URL | Format | Licence | Update | Fields useful for matching | Verdict |
|---|---|---|---|---|---|---|---|
| B1 | California State Fleet (DGS Office of Fleet and Asset Management) | https://data.ca.gov/dataset/california-state-fleet ; CSV https://data.ca.gov/dataset/1b31c08e-b1a7-4459-8aef-41cfff61fc5e/resource/065249ff-32c0-424f-b960-78c3fdbf7244/download/california-state-fleet-2015-2025.csv ; dictionary (DOCX) https://data.ca.gov/dataset/1b31c08e-b1a7-4459-8aef-41cfff61fc5e/resource/d7f9894e-d4e9-4ce7-8341-ed8c9c5e9ff3/download/california-state-fleet-data-dictionary.docx | CSV, datastore API JSON, DOCX dictionary | VERIFIED: "License not specified"; Rights "No Restrictions on Public Use" | VERIFIED: annual; last updated Oct 1, 2026 | Column names NOT read (dictionary DOCX unread). Description: non-confidential state fleet assets by executive agency | usable pending column check |
| B2 | Seattle Active Fleet Complement | landing cos-data.seattle.gov/d/enxu-fgzb; catalog https://catalog.data.gov/dataset/active-fleet-complement-7619e | CSV/JSON/XML/RDF (Socrata) | UNVERIFIED snippet: "No license information was provided" | Monthly (snippet) | Column list not read | promising; check columns.json |
| B3 | Montgomery County MD Fleet Equipment Inventory (id 93vc-wpdr) | https://catalog.data.gov/dataset/fleet-equipment-inventory ; CSV https://data.montgomerycountymd.gov/api/v3/views/93vc-wpdr/export.csv?accessType=DOWNLOAD | CSV/JSON/XML | VERIFIED: no licence stated (access level public) | VERIFIED: quarterly | Columns not listed on page; snippet says unit readiness status | promising; check columns |
| B4 | NYC Fleet Daily Service Report (5rzx-3686) | https://catalog.data.gov/dataset/new-york-city-fleet-daily-service-report | CSV/JSON/XML | VERIFIED: no licence stated | Last updated May 28, 2024 | Availability by agency; not per-vehicle (snippet) | low value |
| B5 | GSA Federal Fleet Report (FAST) | https://catalog.data.gov/dataset/federal-fleet-report ; https://gsa.gov/node/81134 | Spreadsheets / dashboard | VERIFIED: CC0 1.0 | VERIFIED: annual (last record update Feb 17, 2022) | Agency-level summary only (inventory, cost, miles); no unit numbers (UNVERIFIED snippet). Per-agency FAST records listed as restricted | usable for agency fleet-size sanity checks only |
| B6 | HIFLD law enforcement locations | https://hifldgeoplatform.opendata.arcgis.com/ | CSV/SHP/GeoJSON (snippet) | UNVERIFIED snippet: public domain | Old (CSLLEA-derived) | Agency name, address | legacy; ask-first |
| B7 | BJS CSLLEA 2018 (ICPSR 38771) | https://www.icpsr.umich.edu/web/NACJD/studies/38771 | ICPSR files | Fetch returned 403; terms unread | Every ~4 years (snippet) | Agency enumeration (17,541 agencies per snippet), type, personnel counts | UNVERIFIED; may need ICPSR login |
| B8 | FBI Crime Data Explorer agency API | cde.ucr.cjis.gov (FBI page was 403 earlier) | REST | Key from api.data.gov (UNVERIFIED, third-party READMEs); base `https://api.usa.gov/crime/fbi/sapi`, path `/api/agencies` | Unknown | ORI, agency name, state | keyed; UNVERIFIED, legacy endpoints may be gone |
| B9 | USAspending API | https://api.usaspending.gov/docs/endpoints | REST | VERIFIED: "Endpoints do not currently require any authorization." No terms statement on page. Endpoints incl. `/api/v2/search/spending_by_award/`, `/api/v2/search/spending_by_category/naics/` and `/psc/` (filter support not confirmed) | Continuous | Award recipient, awarding agency, PSC/NAICS (vehicles) | usable (no key); use sparingly |
| B10 | Sourcewell, state procurement portals, LA, Chicago, state POST lists, livery references, NREL City and County Vehicle Inventories (registrations, not fleets) | - | - | - | - | - | NOT REACHED |

## Prioritised shortlist (clearest licence first)

1. GSA Federal Fleet Report - CC0 (VERIFIED); agency-level only.
2. NWS - public domain (VERIFIED); no fleet cams, reference only.
3. USGS - public domain (VERIFIED); same caveat.
4. NOAA GLERL webcams - "may be distributed or copied" (VERIFIED); scenic only.
5. USAspending API - no key, no terms text (VERIFIED); procurement matching.
6. California State Fleet (DGS) - "No Restrictions on Public Use", licence unspecified (VERIFIED); best roster, check dictionary.
7. MBTA V3 API - explicit redistribution licence with attribution (VERIFIED).
8. King County Metro feeds - explicit licence with required legend (VERIFIED).
9. Montgomery County Fleet Equipment Inventory - no licence stated (VERIFIED), quarterly; check columns.
10. Seattle Active Fleet Complement - no licence info, monthly (UNVERIFIED snippet).

Runners-up: NPS webcams (probable public domain, UNVERIFIED), NYC MTA feeds (free, terms unread), FBI CDE (keyed, UNVERIFIED). Rejected: explore.org, CC-NC webcam networks.

## Gaps to redo
SEPTA/TriMet/CTA terms; port/bridge/toll camera terms; USACE/USCG/USFS/BLM; sheriff/campus cams; CA fleet data dictionary and Seattle/Montgomery column lists; ICPSR access terms; FBI CDE official docs; WMATA licence; Sourcewell; LA/Chicago fleet datasets; livery references.
