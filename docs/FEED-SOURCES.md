# FEED-SOURCES.md — public camera feeds and reference data the app suite can ingest

Reference for the macOS Hub (and any future ingest service) as it grows from handheld capture to **public feeds**:
state/municipal/federal cameras, business livestreams that are open to the public, and the non-video data used to
cross-reference what the cameras see. Written 2026-10-13. Companion to [CAMERA-SOURCES.md](CAMERA-SOURCES.md) (how frames
arrive), [ACCOUNTABILITY-DATA.md](ACCOUNTABILITY-DATA.md) (records about agencies/people) and
[LEGAL-ETHICS.md](LEGAL-ETHICS.md) (what may be persisted).

**Confidence labels** — ✅ verified by reading an official page · 🔎 found in web search, not opened or not confirmed ·
⚠ conflicting or unverified · ❌ attempted and failed. **Nothing here is legal advice.** Public *viewing* is not a
licence to copy, store or redistribute: every source needs its terms recorded before it is enabled.

## 1. What image quality does to us (measured) — design for this first

Public feeds are **low resolution** (typically 352×240 – 704×480, snapshots every 5 s – 3 min, heavy JPEG). We simulated
that on the 62-image eval corpus (`scripts/degrade_corpus.py`; profiles are rough, the trend is what matters):

| Quality | Fleet recall | incl. review queue | Precision / civilian FP | Plate reads (with plate model) | Identity fully correct |
|---|---|---|---|---|---|
| original | 63 % | 76 % | 100 % / 0 | 19/62 | 5/15 |
| ~720p, q60 | 57 % | 78 % | 100 % / 0 | 14/62 | 7/15 |
| ~480p, q40, blur, noise | **35 %** | 59 % | 100 % / 0 | 10/62 | 1/15 |
| ~240p, q30, blur, noise | **7 %** | 41 % | 100 % / 0 | 1/62 | 0/15 |

**By the vehicle's own pixel size** (what actually matters — a 1080p frame can hold a 50 px vehicle). Fleet detection pooled over the four
quality levels, n = 192 fleet vehicles, grouped by the main vehicle's long side in the frame:

| Main-vehicle long side | Fleet detected |
|---|---|
| < 400 px | 3/55 (**5 %**) |
| 400–899 px | 17/49 (**35 %**) |
| 900–1399 px | 27/46 (**59 %**) |
| 1400+ px | 27/42 (**64 %**) |

So `AnalysisTier.tier(forVehicleLongSide:)` uses 900 / 400 px, and the Hub takes the **worse of frame tier and vehicle tier** whenever the
vehicle detector supplies real boxes (without it the "vehicles" are pseudo-boxes grown from text regions, so their size is meaningless).

Consequences for the Hub:
1. **Lettering and plates stop being readable below ~480p.** The text-first pipeline that works on phone photos mostly
   fails on far-field traffic cameras. Precision stays 100 % (the gate is conservative), but recall collapses.
2. **Vehicle appearance must carry more weight** at low resolution (class cue, light bars, livery colour) — that is why the
   vehicle-crop fleet classifier matters (MODEL-TRAINING §7), and why its false-positive behaviour needs the same scrutiny.
3. **Tiered handling per source:** record each feed's native resolution in the registry; run the "thorough" text path only
   where pixels allow; otherwise route to the review queue with the appearance cue instead of pretending to read text.
4. **Aggregate, don't individuate.** At feed quality the honest output is "a police-type vehicle passed camera X at time T",
   not an identity. Identity claims need the markings and must carry `needsReview` (see IDENTITY.md).

## 2. Location comes from the source (see IDENTITY.md)
Feed frames have **no phone GPS and no EXIF**. The camera's catalogued position is the location hint for the identity
resolver (`PublicFeedSource.geohash6`, already mandatory). A source without a trustworthy position must not be enabled for
identity (only for aggregate counts).

**Implemented (PR #11):** `IdentityResolver.syncIdentity(vehicle:markings:confidence:location:forceReview:)` is the one
rule for what identity may leave the device; the Hub uses it with the operator-set camera geohash (`hubGeohash6`, now loaded at
launch) and the frame's `AnalysisTier`: **full** (≥ 960 px) may confirm an identity; **reduced** (480–959 px) is forced to review with
the registration withheld; **appearanceOnly** (< 480 px) asserts no identity. Verified on the Minneapolis photo: no camera location →
`US-??/minneapolis/police`; camera geohash in Minneapolis → `US-MN/minneapolis/police`; the same photo at 704 px → no hit (the recall
cliff). Still to do: per-source location for the feed *pollers* (the Hub's single `homeGeohash6` is for folder/HTTP ingest) and
enforcing `PublicFeedSource.mayBeAnalysed` before any poll.

## 3. Camera / live-feed sources

### 3a. State DOTs and 511 systems (the main source)
| Source | Access | Terms / notes | Status |
|---|---|---|---|
| **Caltrans CCTV** (CA) | Statewide catalogue via the Commercial Wholesale Web Portal (CWWP2, JSON/XML/CSV per district) and an ArcGIS layer (`CHhighway/CCTV`) with fields incl. `currentImageURL`, `streamingVideoURL`, `inService`, `currentImageUpdateFrequency`. No key documented | Published "so third-party developers can integrate". Caltrans disclaims accuracy/liability; ArcGIS item © State of California, licence field unspecified; a 1997 CHP/Caltrans agreement about real-time CCTV may still restrict rebroadcast of non-public-record info. Many sites have limited comms so stills update slowly and video is often absent | 🔎 docs only. ❌ **`cwwp2.dot.ca.gov` refused connections and `gisdata.dot.ca.gov` timed out from our development machine** (direct curl and the web fetcher), so the real JSON keys were **not** verified — test from the Hub's network. Contact: Caltrans GIS (listed on the dataset) |
| **Iowa DOT** | Open-data CSV with image **and video** URLs | Iowa DOT announced a camera video-system migration (May 2026) that changed image/video URLs — never hard-code URLs, re-read the catalogue | 🔎 |
| **Oregon TripCheck** | API with a CCTV inventory including a still-image URL per camera; inventory refreshed daily | Access terms not seen — check whether registration is required | 🔎 |
| **Ohio OHGO** | API with a **key** (register); camera snapshots refresh ~5 s | Key + terms | 🔎 keyed |
| **Utah UDOT** | API with a **key**, 10 calls / 60 s; separate public ArcGIS layer lists camera metadata (images unverified) | Key + throttle | 🔎 keyed |
| **511NY / 511 WI / 511 GA / other 511 platforms** | Common platform: developer key, ~10 calls/60 s throttle | Per-state agreement; **keyed** | ✅ (511NY docs read earlier) / 🔎 others |
| **WSDOT** (WA) | Traveler Information API needs a free AccessCode | | ✅ earlier |
| **MnDOT / 511mn** | ~1,100 cameras on 511mn.org; **no official developer documentation found**; image endpoints would have to be read from the site's own network calls or obtained from MnDOT | Treat as ask-first | 🔎 |
| **PennDOT** | Feeds by registration request, no charge | | 🔎 |
| **Massachusetts (Mass511)** | Highway data for developers via a partner (TrafficLand): live JPEG, ~1 frame / 120 s | Partner terms | 🔎 |
| **TxDOT / Houston TranStar / CDOT (CO) / GDOT (GA)** | Public viewing sites; snapshots every ~3 min (TranStar); TranStar says it records nothing; CDOT stills every few minutes; GDOT 511GA has a documented API (key status unconfirmed) | TranStar's terms reportedly forbid framing/linking individual images without permission; **no keyless licensed image endpoint confirmed** | 🔎 / ⚠ |

Rule (unchanged): **keyless, published-for-public-use image URLs first; keyed feeds only after the owner registers and accepts
the agreement; ask-first agencies only with written permission.** Respect each agency's refresh interval as a *floor*.

### 3b. Municipal
| Source | Notes | Status |
|---|---|---|
| **City of Austin** — "Traffic Cameras" on the open-data portal | Listed **Public Domain**, CSV/JSON/GeoJSON/KML; described as for monitoring live conditions. Whether image URLs need a key not verified | 🔎 best-licensed lead |
| **City of Seattle** | Open-data terms say free to use and share; SDOT camera layer is locations; highway stills come from WSDOT, SDOT street cams are live video | 🔎 |
| **Washington DC** (DDOT) | Traffic-camera layer on opendata.dc.gov (ArcGIS API) | 🔎 |
| **Calgary / Ontario (Canada)** | Open "Traffic Cameras" datasets — out of USA scope, useful as format references | 🔎 |
| **Chicago** | Portal holds *enforcement* camera locations/violations (red-light, speed) — **not** traffic-monitoring images; do not use enforcement-camera imagery | ✅ scope note |
| **NYC DOT TMC** | Large public webcam network; **terms and API shape not confirmed** | ⚠ |
| **Transit agencies** (buses/stations), **port & airport authorities**, **toll authorities** | Often publish cams or GTFS-realtime vehicle positions; per-agency terms | ⬜ to research per target |

### 3c. Federal
| Source | Notes | Status |
|---|---|---|
| **USGS** (volcano/river/glacier cams; e.g. HVO webcam API) | API returns **metadata**; some cameras are partner-sponsored (e.g. state DOT) with different rights; USGS says its APIs carry no guarantee of continued support. Mostly irrelevant to *vehicles* — useful as a test of the HLS/stills plumbing | 🔎 |
| **FAA Weather Cameras** (weathercams.faa.gov) | Stills ~10 min; "situational awareness only"; some cameras belong to third-party hosts who may hold rights; no public API seen | 🔎 low relevance |
| **NOAA / NWS** | Some lab webcams "as is, entertainment only"; NWS pages link FAA cams | 🔎 low relevance |
| **NPS** | Park webcams (partner-operated mix); no API/terms found | ⚠ |
| General rule | US federal works are generally not copyrighted, but partner/third-party cameras and aggregators can set their own terms — check the specific camera page | ✅ principle |

### 3d. Aggregators that could bootstrap a catalogue (verify before use)
- **bzsasson/traffic-camera-sources** (GitHub) — registry of official US feeds, camera locations as GeoJSON, measured per-state uptime; its own files CC BY 4.0, camera records keep the operating agency's attribution; some sources "no open-data licence stated". 🔎 Good seed for a `feeds.json`; re-verify each entry's terms.
- **TrafficLand API** — commercial aggregator of DOT cameras (docs at api.trafficland.com). Commercial terms. 🔎
- Third-party "live camera" sites (several SEO pages surfaced) — **not sources**; ignore.

### 3e. Civilian / business livestreams "open for public viewing"
Public viewability ≠ reuse rights. Default **excluded unless the owner permits**:
| Source | Why |
|---|---|
| **Windy Webcams API** | Official API; must show images only as delivered, link back and credit Windy; Windy can terminate any time; redistribution reportedly requires a paid plan (a staff forum post says ~9,990 €/yr — confirm); webcam *owners* can opt out of the API. Fine for a viewer, **not** for bulk analysis/storage without a licence |
| **EarthCam** | Revenue model is licensing its content; ToS governs viewing/sharing; licensing required for rebroadcast. Ask first |
| **YouTube / other platform livestreams** | Platform ToS (as summarised by secondary sources) prohibit automated access/scraping; use the official API only for metadata. Do not capture frames without the channel owner's written permission |
| **University / business webcams** | Terms vary (e.g. one university allows broadcast for 7 days with attribution, restricts commercial use). Per-camera permission |

### 3f. Hard exclusions
- **Unsecured / unlisted IP cameras** (default-credential or open-port devices, index sites like Insecam/Shodan-style) — *not* "public viewing"; accessing them is not authorised. Never ingest.
- **Enforcement cameras** (red-light/speed/ALPR networks run by police) and any feed not published for general public viewing.
- Sources whose terms forbid automated use or storage, and any that require a login the project does not hold.

### 3g. First live pilot — City of Austin (2026-10-13)
Research (docs/research/FEED-RESEARCH-MUNICIPAL-STATE.md) found **Austin** the cleanest keyless source: Socrata dataset `b4k4-adkb`
(listed Public Domain) with `camera_id`, `location` (GeoJSON point), `camera_status`, `screenshot_address` (image URL on
`cctv.austinmobility.io`). **Verified live:** the catalogue query returned records with those fields, and one still from each of 5
cameras fetched (1 request/s, identifying User-Agent, kept locally, **not committed**).
- Frames are **1920×1080 JPEG, 110–235 KB** → analysis tier `full` by pixel count — but the scenes are wide night-time intersection
  views where vehicles are a few dozen pixels tall. Pipeline result on the 5 frames: **0 fleet hits, 0 plates, 0 false positives, 0.46 s/image.**
  So resolution *per vehicle*, not frame size, is what limits reading — the tier thresholds should eventually use the vehicle box size too.
- At least one camera (Cesar Chavez / IH-35) **masks vehicles and pedestrians with grey blobs** before publishing: the operator is
  privacy-masking at source; analysing a masked region is pointless and arguably against the operator's intent. Detect and skip.
- The image host's own terms (austinmobility.io) were **not read** — only the dataset's Public Domain listing — so `automatedUseAllowed`
  stays false until a person reads them. Pilot polling beyond a handful of frames should wait for that.
- Other findings (research file): Seattle (REST layer 500'd; licence unread), Iowa (open portal; no licence text found; bans bots/framing),
  Oregon TripCheck / Georgia / Arizona keyed, NYC & PennDOT agreement-based, **Houston TranStar prohibits redistribution/framing without
  TxDOT's written consent, Minnesota has no developer access, DC lists locations only**; Caltrans/Michigan/CO/VA/IL/NJ could not be verified.

## 4. Reference / cross-referencing data (no video)
| Source | Use | Access | Status |
|---|---|---|---|
| **US Census Gazetteer** (already used) | place↔state↔lat/lon for identity | public domain download | ✅ in repo |
| **NHTSA vPIC** | VIN/make/model decode | free API, no registration; run big batches off-peak | 🔎 |
| **USAspending API** | federal contracts/grants (fleet/equipment procurement trail) | free, unauthenticated REST + bulk download | 🔎 |
| **SAM.gov** | entity/exclusion lists | **needs account + API key**; monthly bulk extracts | 🔎 keyed |
| **HIFLD law-enforcement locations** | agency points (name/county/state) | public ArcGIS layer, ≤2,000 per query; built on 2008–09 BJS data (stale); sources disagree on federal coverage | ⚠ |
| **FBI ORI / Crime Data Explorer** | agency identifiers | no current official bulk list found; CDE API needs a key; ORIs are CJIS-assigned | ⚠ |
| **GSA fleet (FAS)** and state fleet lists (e.g. California State Vehicle Fleet), NYC *Fleet Daily Service Report*, Montgomery County, Seattle active fleet, MTA police fleet inventory | rosters of public vehicles (unit numbers, makes) → roster matching | Socrata/ArcGIS portals, open licences vary | 🔎 (importers exist for GSA; others to add) |
| **State POST registers, CourtListener/RECAP, agency budgets** | accountability records (see ACCOUNTABILITY-DATA.md) | per source | per that doc |
| **OpenStreetMap / Wikidata** | stations, agency names, boundaries | ODbL / CC0 | 🔎 |

## 5. What the Hub's source registry must record (design requirements)
Extend `PublicFeedSource` (already: id, name, url, kind, refreshInterval, geohash6, citation, termsNote) with:
1. `terms`: licence class (`publicDomain` / `openLicence` / `permissioned` / `keyed` / `askFirst`), **URL of the terms page and the date read**, attribution text, and `automatedUseAllowed` (bool, default false until a human confirms).
2. `nativeResolution` and `expectedCadence`, so the pipeline picks the analysis tier (§1) and never polls faster than the floor.
3. `locationConfidence` (surveyed / approximate / unknown) — gates identity (§2).
4. `credentialRef` (keychain item, **never** in the repo) for keyed feeds; `.gitignore` already excludes key material.
5. Health: last success, consecutive failures, back-off; auto-disable on 403/429/terms change.
6. `retention`: frames are analysed in memory and **discarded**; only gate-approved sightings persist (LEGAL-ETHICS), exactly like handheld capture. Agencies that say they do not record (e.g. TranStar) must not become a de-facto archive through us.

Operational rules: identify ourselves in the User-Agent with a contact URL; honour `robots.txt`; one request at a time per host;
exponential back-off; cache catalogues (daily at most); re-read catalogues instead of hard-coding image URLs (Iowa changed URLs in 2026).

## 6. Growing the database safely ("quickly increase datasets and cross-references")
- Feed sightings feed **aggregates first** (counts by agency/type/camera/hour) and the existing moderation path for anything
  individual; no plate or identity is persisted below the `RedactionGate` bar, regardless of source.
- Training data from feeds: only with terms permitting it. Prefer sources whose licence allows derived datasets; keep the per-image
  licence in the manifest (as `scripts/crawl_commons_*.py` do). Frames from `askFirst`/platform sources never enter training sets.
- Cross-reference keys: `agencyKey` (`US-MA/waltham/police`), camera id, geohash, time bucket — never a person.

## 6b. Legal constraints found in research (not legal advice) and what the Hub implements
Full notes with VERIFIED/UNVERIFIED labels: [research/FEED-LEGAL-RESEARCH.md](research/FEED-LEGAL-RESEARCH.md). Headlines:
- **Several states regulate ALPR use by *any person*.** Maine (29-A MRSA §2117-A, Class E crime, verified) and New Hampshire
  (RSA 261:75-b, law enforcement only, verified) are the highest risk; Arkansas, Idaho, Kentucky, Connecticut reported (unverified).
  Whether plate OCR on a third-party DOT feed is "use" is **an open question for counsel**.
- Some DOTs say they **do not record** (Iowa, Arkansas, Houston TranStar): a project that stores frames creates a record the agency
  says it does not hold. Iowa bans bots/framing; Arkansas bans embedding and requires the owner's logo; PennDOT limits use to
  showing current traffic. CFAA risk for polling public pages looks low (Van Buren, hiQ — 9th Cir. only) but contract/state-law claims remain.
- No statute found banning publication of police-vehicle locations; confidential/undercover plates are protected; doxxing laws target home addresses.
- No face/person/biometric processing anywhere keeps the project outside BIPA/CUBI/RCW 19.375.

| Guardrail | Status |
|---|---|
| **Jurisdiction gate: plate recognition off in/near ME, NH (verified) and AR, ID, KY, CT (pending counsel), and when the location is unknown** | ✅ `PlateKit.JurisdictionPolicy` + `AnalysisContext.readPlates`; the Hub skips plate detection/OCR entirely (not just hides it); 30 km border margin; verified: Maine camera → fleet hit from lettering, 0 plates |
| No raw-frame retention | ✅ Hub analyses in memory / deletes folder drops after analysis; HTTP bodies never written. Pollers must keep this |
| Plate text persisted only for fleet-gate sightings, registration redacted below the bar | ✅ (RedactionGate / `syncIdentity`) |
| Terms recorded and human-confirmed before any poll | ✅ `FeedTerms` + pollers refuse unconfirmed sources |
| Resolution-tiered identity (low-res frames never assert identity) | ✅ `AnalysisTier` |
| Handheld iPhone capture under the same jurisdiction policy | ⬜ not applied yet — open question for counsel (the *user* operates it) |
| Aggregation delay (24–72 h), ~1 km coarsening, k-suppression, no live police map | ⬜ server/publishing side, not built |
| Exclude unmarked/undercover, SWAT/protective, school buses with children, ambulances with patients | ⬜ classifier/moderation work; unmarked vehicles are already undetectable from text |
| TTL: 21 days full precision then aggregates; access audit log; takedown channel + tombstones | ⬜ server |
| robots.txt, identifying User-Agent with contact URL, stop-and-flag on 403/429 (no IP rotation) | ⬜ pollers (back-off exists; robots/UA not yet) |

## 7. Open items / next research
1. **Verify the Caltrans CWWP2 JSON and one keyless snapshot URL from the Hub's own network** (our dev machine could not reach it), then build the first end-to-end pilot (catalogue → poll → analyse → aggregate) with 5–10 cameras.
2. Confirm **Austin** image URLs are keyless and read its terms page; confirm **Iowa** CSV fields; check **TripCheck** registration.
3. Research per-target: municipal (NYC TMC, DC, Houston, Denver), transit/port/airport/toll authorities, county sheriffs/OEMs that publish cams.
4. Decide with the owner: which `keyed` platforms to register for; whether to request written permission from `askFirst` operators.
5. Build the registry fields in §5, the per-tier analysis switch (§1), and run `EvalHarness` on **recorded real feed stills** (saved under `eval/feeds/`, gitignored) once any feed is reachable — the degraded corpus is only a proxy.

## Sources
- Caltrans CWWP2 portal — https://cwwp2-ssl.dot.ca.gov/sitemap.xml ; ArcGIS CCTV layer — https://gisdata.dot.ca.gov/arcgis/rest/services/CHhighway/CCTV/FeatureServer/0 ; Caltrans D2 camera FAQ — https://dot.ca.gov/caltrans-near-me/district-2/d2-popular-links/d2-traffic-camera-faq
- Austin traffic cameras — https://data.austintexas.gov/Transportation-and-Mobility/Traffic-Cameras/b4k4-adkb ; Seattle open data — https://data.seattle.gov/ ; DC — https://opendata.dc.gov/datasets/DCGIS::traffic-camera/api ; Houston TranStar FAQ — https://www.houstontranstar.org/faq/webfaq.aspx
- Iowa DOT camera system notice — https://iowadot.gov/news/2026-05-28/media-advisory-iowa-dot-updates-traffic-camera-video-system-data-feed-usersdevelopers ; OHGO API — https://publicapi.ohgo.com/docs/resources ; TripCheck API — https://tripcheck.com/Pages/API ; UDOT API — https://udottraffic.utah.gov:443/developers/doc ; 511NY — https://511ny.org/developers/doc ; 511WI — https://511wi.gov/developers/doc ; 511GA — https://511ga.org/developers/doc ; Mass highway data — https://www.mass.gov/service-details/highway-data-for-developers ; PennDOT — https://www.pa.gov/services/penndot/request-access-to-transportation-related-data-feeds.html
- Aggregators: https://github.com/bzsasson/traffic-camera-sources ; https://api.trafficland.com/docs
- Federal: USGS HVO webcam API — https://volcanoes.usgs.gov/vsc/api/hvoWebcamsApi ; USGS webcams — https://www.usgs.gov/mission-areas/natural-hazards/multimedia/webcams ; FAA weather cameras — https://www.faa.gov/about/office_org/headquarters_offices/ato/service_units/systemops/fs/alaskan/weather_cams ; NOAA GLERL disclaimer — https://www.glerl.noaa.gov/metdata/docs/webcam_disclaimer.html
- Business livestreams: Windy webcam terms — https://account.windy.com/agreements/webcams-terms-of-use ; EarthCam ToS summary — https://tostracker.app/document/earthcam
- Reference data: NHTSA vPIC — https://vpic.nhtsa.dot.gov/api/ ; USAspending — https://api.usaspending.gov/docs/endpoints ; SAM.gov entity API — https://open.gsa.gov/api/entity-api ; HIFLD law enforcement (OSM wiki) — https://wiki.openstreetmap.org/wiki/HIFLD/Law_Enforcement ; fleet datasets — https://catalog.data.gov/dataset/city-and-county-vehicle-inventories-f07a0 and https://catalog-beta.data.gov/dataset/new-york-city-fleet-daily-service-report
