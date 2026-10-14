# Municipal / state traffic-camera sources for PlateWatch Hub

Research date: 2026-10-13 (all "read" statements mean read today). Read-only; one catalogue/terms page per source. VERIFIED = official page/doc read; UNVERIFIED = search snippet only or not readable.
Legend verdicts: usable / keyed / ask-first / not-usable. None of this is legal advice; "no rule found" is not "permission".

## Summary table

| Source | Access | Key? | Catalogue URL | Image-URL / lat-lon / in-service fields | Cadence / resolution | Licence / terms (quote, URL) | Automated-use rule | Verdict |
|---|---|---|---|---|---|---|---|---|
| Austin TX (Socrata b4k4-adkb) | Still JPEG | No (VERIFIED) | https://data.austintexas.gov/api/views/b4k4-adkb ; SODA https://data.austintexas.gov/resource/b4k4-adkb.json | `screenshot_address`; `location` (GeoJSON [lon,lat]); `camera_status`=TURNED_ON (VERIFIED) | `published_screenshots` says "every 5 minutes" but empty; res not stated | "Public Domain"; attribution "City of Austin, Texas - data.austintexas.gov" (metadata, VERIFIED) | None found in metadata; image host terms not read | **usable** |
| Iowa DOT | Still + video URLs in CSV / ESRI feature service | No for feature service ("do not require credentials", VERIFIED); XML feed needs request form | https://data.iowadot.gov/datasets/IowaDOT::traffic-cameras-3/about ; feeds page https://iowadot.gov/travel-tools/iowa-511/511-data-feeds | Field names NOT read (JS app); older Socrata copy data.iowa.gov 4bfg-n52x has static image + video URL (UNVERIFIED) | Not stated; URLs changed 2026-05-20 | No licence text found; "we do not have a reliable way to identify or notify all users of our data" (https://iowadot.gov/news/2026-05-28/...) VERIFIED | No rule stated | **usable (caveat: ask)** - open, unauthenticated, no explicit licence |
| Oregon TripCheck | Still image URLs via API | **Yes** - portal account + subscription key (VERIFIED) | TripCheck API portal (see Getting Started Guide V5 https://www.tripcheck.com/pdfs/TripCheckAPI_Getting_Started_GuideV5.pdf) | CCTV Inventory resource gives "an Internet URL ... specific still camera image"; field names not extracted | Inventory refresh 24 h; image cadence/res not stated | "Data provided to TripCheck.com ... made available to the public for integration into applications, research and more." https://www.oregon.gov/odot/Maintenance/Pages/Traveler-Information.aspx (VERIFIED); portal Terms behind signup (not read) | Unknown (portal Terms) | **keyed** (free) |
| Minnesota MnDOT / 511mn | None found | n/a | https://511mn.org (no developer page visible) | n/a | n/a | No official developer terms found (UNVERIFIED absence) | n/a | **ask-first** / not-usable now |
| TxDOT / Houston TranStar | Web viewer only; JSON API excludes cameras | Contact required | http://traffic.houstontranstar.org/api/api_doc.aspx | No camera API (VERIFIED) | Not stated | "no copying, reproduction, or distribution of the information contained in this site is permitted"; "External framing or linking to specific images or graphics is prohibited without the express written consent of TxDOT." http://traffic.houstontranstar.org/disclaimer.aspx (VERIFIED) | Framing/linking images & redistribution prohibited without written consent | **not-usable** (ask-first for written consent) |
| CDOT COtrip | Unknown | Unknown | https://www.cotrip.org (JS app, unreadable) | Unknown | Unknown | Nothing official found | Unknown | **ask-first** (UNVERIFIED) |
| DC DDOT | Locations only (no image field) | No | https://maps2.dcgis.dc.gov/dcgis/rest/services/DDOT/TrafficOperations/MapServer/2 ; OCTO CCTV layer .../Transportation_Sensors_WebMercator/MapServer/11 | `Latitude`,`Longitude`,`Operation_Status` (0/1), no image URL (VERIFIED) | n/a | OCTO layer "Creative Commons Attribution 4.0 (CC BY 4.0)" https://catalog.data.gov/dataset/closed-circuit-tv-street-cameras (VERIFIED) | none; no images | **ask-first** for imagery; locations usable |
| NYC DOT TMC | Stills at webcams.nyctmc.org | Official: data-sharing agreement | https://nyc.gov/html/dot/html/about/datafeeds.shtml | No documented API; community pattern nyctmc.org/api/cameras/{id}/image (UNVERIFIED) | "frequently updated"; community says ~2 s, ~352x240 (UNVERIFIED) | "Developers wishing to access the cameras' data feed should contact NYC DOT" (VERIFIED); must sign data-sharing agreement; include NYC DOT disclaimer on retransmission | Agreement governs | **ask-first** |
| Seattle SDOT | Still image URLs | No (open GIS layer) | https://gisdata.seattle.gov/server/rest/services/SDOT/SDOT_Assets/MapServer/9 (500 "not started" today) ; metadata https://www.seattle.gov/Documents/Departments/SDOT/GIS/Traffic_Cameras_OD.pdf | `URL` ("Link to Traffic Camera live image"), `SERVSTAT`, geometry = point; `OWNERSHIP` SDOT/WSDOT (metadata VERIFIED) | dataset weekly; image cadence not stated | "The City of Seattle does not archive or retain any of the images from the traffic cameras." / "reserves the right to suspend public access ... at any time." https://www.seattle.gov/trafficcams/northgate_1st.htm (VERIFIED); open-data licence not read | none stated | **usable** (confirm licence with dot_it_gis@seattle.gov) |
| Georgia 511GA | JSON/XML API; Views[].Url is a page link | **Yes** - developer key; 10 calls/60 s | https://511ga.org/api/v2/get/cameras ; docs https://511ga.org/help/endpoint/cameras | `Latitude`,`Longitude`, `Views[].Url`, `Views[].Status` ("Enabled") (VERIFIED) | not stated | Terms page rendered empty; "Requires a developer key." | throttling 10/60 s | **keyed** |
| Caltrans CWWP2 | JSON/XML/CSV per district | Not needed (UNVERIFIED) | https://cwwp2.dot.ca.gov (CONNECTION REFUSED) | `currentImageURL`, lat/lon, update-frequency (snippets, UNVERIFIED) | `referenceImageUpdateFrequency` minutes (UNVERIFIED) | "designed to provide real-time travel Information to be used by commercial, media ... agencies and the public" (dot.ca.gov CWWP page snippet); Conditions of Use not read | Unknown | **ask-first** until terms read |
| Florida FL511 | Unknown | Likely agreement/key | https://fl511.com (developer URLs 404) | n/a | n/a | FDOT "ATIS Data Use Agreement" (snippet) | agreement | **ask-first** (UNVERIFIED) |
| Arizona AZ511 | API | **Yes** - key; 10/60 s | https://az511.com/developers/doc | cameras resource "returns all cameras"; fields not read | n/a | Terms not shown on page | throttling | **keyed** |
| Virginia VDOT 511 | Unknown; SmarterRoads for approved users | Registration/approval (UNVERIFIED) | https://smarterroads.vdot.virginia.gov/ | n/a | n/a | not read | n/a | **ask-first** (UNVERIFIED) |
| Michigan MiDrive | Web only found | n/a | https://www.michigan.gov/drive | n/a | n/a | disclaimer page 403 to our fetcher | n/a | **ask-first** (UNVERIFIED) |
| Illinois Getting Around Illinois | ArcGIS layer "Gateway Traffic Camera Locations" (says not a live feed) | No (UNVERIFIED) | IDOT Open Data portal (endpoint not read) | snapshot URL field, lat/lon, age flags (snippet only) | stale >10 min warn / >30 min too old | not read | n/a | **ask-first** (UNVERIFIED) |
| Pennsylvania 511PA | Keyed developer program | **Yes** - agree to T&Cs | 511PA Developers Corner (T&Cs PDF host failed DNS) | n/a | n/a | T&Cs 2014 (snippet): access "only to Developers that agree to comply" | a snippet claims camera use limited to showing current traffic (UNVERIFIED) | **keyed / ask-first** |
| New Jersey 511NJ | Unknown | Unknown (platform sibling uses keys) | https://511nj.org (SPA, unreadable) | n/a | n/a | not read | n/a | **ask-first** (UNVERIFIED) |

## Recommended starter set (pilot)

1. Austin TX - ~822 TURNED_ON cameras, public-domain open data, no key. Best first pilot. Poll politely (>=60 s per camera; they say the feed is not recorded or retained); store only derived/redacted results per LEGAL-ETHICS.
2. Seattle SDOT - open GIS layer with `URL` + `SERVSTAT`; REST was down today (500), so fall back to the ArcGIS Hub download; confirm licence by email (dot_it_gis@seattle.gov).
3. Iowa DOT - unauthenticated ESRI feature service; re-read catalogue on every run because URLs changed 2026-05-20; email the DOT integrator list (Sinclair Stolle) to register and ask about licence.
4. DC DDOT/OCTO - CC BY 4.0 camera location inventory; useful as metadata (lat/lon, active flag) but NOT for imagery.
5. Oregon TripCheck - free key, explicit "integration into applications, research" statement; good second-wave pilot after reading portal Terms.
6. Georgia / Arizona 511 - keyed; consider only after reading the Developers Access Agreement (Wisconsin's sibling agreement exists as a docx; we could not read it).

Do NOT pilot: Houston TranStar/TxDOT (framing and redistribution prohibited without written consent), NYC (agreement required), Minnesota (no program found).

## Could not verify

- Caltrans CWWP2 (ECONNREFUSED), dot.ca.gov CWWP page (fetch failed), gisdata.dot.ca.gov (not attempted per brief).
- Iowa field names (data.iowadot.gov is a JS app) and licence.
- Oregon CCTV field names and portal Terms of Use (behind signup).
- 511PA T&Cs PDF (host prdpenndot.pwpca.pa.gov: DNS failure), 511WI access agreement (.docx unreadable).
- CDOT COtrip, FL511, VDOT, MiDrive (403), Illinois endpoint, NJ511, Minnesota (any official developer access).
- Georgia 511 terms page rendered empty; GDOT ArcGIS layer rnhp.dot.ga.gov returned Web Adaptor error.
- NYC webcams terms-of-use page and official API (none visible); community URL pattern unverified.
- Native image resolution/cadence: not stated by any source we could read (NYC ~352x240 / ~2 s is community-sourced, UNVERIFIED).
- Austin: image-host (cctv.austinmobility.io) terms of use not read.

---
# Per-source notes (evidence)

### Austin TX (Socrata b4k4-adkb) - VERIFIED (data.austintexas.gov/api/views/b4k4-adkb.json read 2026-10-13)
- Access: still JPEG per camera, no key. Catalogue: https://data.austintexas.gov/api/views/b4k4-adkb (SODA: https://data.austintexas.gov/resource/b4k4-adkb.json)
- Fields: `screenshot_address` (e.g. https://cctv.austinmobility.io/image/1000.jpg), `location` (GeoJSON [lon,lat]; no separate lat/lon columns), `camera_status` (TURNED_ON 822 / DESIRED 123 / VOID 34 / REMOVED 30), `camera_id`, `location_name`, `modified_date`.
- Cadence: not stated for feed; `published_screenshots` says "every 5 minutes" but empty on all rows. Dataset itself updated daily. Resolution not stated.
- Licence: "Public Domain" (dataset metadata); attribution requested: "City of Austin, Texas - data.austintexas.gov". Description: "Video is NOT recorded or retained of daily traffic"; data "may not suit legal, engineering, or surveying use".
- Automated-use rule: none seen in metadata (image host terms not read). Verdict: usable (pilot).

### Iowa DOT - partly VERIFIED
- VERIFIED (iowadot.gov/travel-tools/iowa-511/511-data-feeds, read 2026-10-13): ESRI feature service "Iowa DOT Traffic Cameras (CCTV)" on the DOT Data Portal; services "do not require credentials to access". XML feed (data/cctv.xml, schema CCTV.xsd) requires a request via a vendor form (keyed/ask). Page states NO usage rules.
- VERIFIED (iowadot.gov news 2026-05-28): catalogue https://data.iowadot.gov/datasets/IowaDOT::traffic-cameras-3/about (download CSV; "Request a new file"). Image/video URLs changed 20 May 2026 (video4.iowadot.gov -> video.iowadot.gov pending); so do not hardcode URLs - re-read catalogue. Advisory: "we do not have a reliable way to identify or notify all users of our data." Contact: Sinclair Stolle, traffic management systems engineer; 515-239-1933.
- UNVERIFIED: older Socrata copy data.iowa.gov id 4bfg-n52x (static image URL + motion video URL), daily update (search snippet). The data.iowadot.gov about page is a JS app; field names NOT read (could not verify). No licence text found. Verdict: usable-with-caveat (open, no key, but no explicit licence; contact DOT).

### Oregon TripCheck - VERIFIED
- VERIFIED (TripCheckAPI_Getting_Started_GuideV5.pdf, read 2026-10-13): API requires a developer-portal account and subscription key (401 "Invalid or missing API subscription key"); you must read/accept portal Terms of Use at subscribe time (text not public). Feed "CCTV Inventory", refresh 24 h: "provides an inventory of all available cameras currently displayed on TripCheck, along with an Internet URL that can be used to access the specific still camera image. Cameras may be ODOT owned ... or owned and maintained by a partner agency." Field names not read (doc lists endpoint names but I did not extract the schema).
- VERIFIED (oregon.gov/odot/Maintenance/Pages/Traveler-Information.aspx): "Data provided to TripCheck.com from our infrastructure are made available to the public for integration into applications, research and more." and data "is made available for free via XML and JSON formats". (Page does not say cameras explicitly.)
- Verdict: keyed (free key; terms behind signup). Partner-agency cameras may carry separate rights.

### Minnesota 511mn / MnDOT - VERIFIED negative-ish
- 511mn.org/developers/help returned only the SPA title (no developer page visible). Web search found NO official MnDOT developer API/terms for cameras (UNVERIFIED absence). Verdict: ask-first / not-usable until MnDOT confirms in writing. Related: MnDOT snow-plow camera images exist as a GIS layer (btaa catalogue snippet, UNVERIFIED).

### Georgia 511GA (Iteris/Castle Rock-style 511 platform) - VERIFIED
- VERIFIED (511ga.org/developers/doc, /developers/help, /help/endpoint/cameras): "Requires a developer key." Registered account needed first. "Throttling is enabled. Ten calls every 60 seconds." Cameras endpoint https://511ga.org/api/v2/get/cameras (params key, format=xml|json). Fields: Id, Source, SourceId, Roadway, Direction, Latitude, Longitude, Location, SortOrder, Name, Views[]{Id, Url (a /map/Cctv/{Id} page link, not a raw JPEG per the sample), Status ("Enabled"), Description, SortId}. No refresh interval documented. Terms page (511ga.org/terms) rendered no text -> terms NOT read.
- Same platform/pattern (UNVERIFIED for each, search snippets show endpoint docs exist): 511ny.org, 511wi.gov, 511la.org, 511.alaska.gov. fl511.com/help/endpoint/cameras -> 404.
- Verdict: keyed.

### TxDOT / Houston TranStar - VERIFIED (traffic.houstontranstar.org, /disclaimer.aspx, /api/api_doc.aspx read 2026-10-13)
- Disclaimer quotes: "no copying, reproduction, or distribution of the information contained in this site is permitted" (without TxDOT advance written approval); "External framing or linking to specific images or graphics is prohibited without the express written consent of TxDOT."; no part of the site may be "set within a 'frame'". Does not address bots explicitly. Footer: "(c) 2026 Houston TranStar. All rights reserved."
- API page (api_doc.aspx): JSON feeds only for speed segments, incidents, lane closures, flood warnings; NO camera feed; "to inquire about gaining access to the live data feeds, please contact Houston TranStar." Camera viewer /cctv/transtar/ , no refresh interval stated, no image URL pattern.
- Verdict: not-usable without written TxDOT consent (ask-first).
- TxDOT statewide cameras: UNVERIFIED (search snippet): distributed via C2C data access portal; 2013 TrafficLand licence.

### Colorado COtrip - mostly UNVERIFIED
- cotrip.org is a JS app (nothing readable). Search found no official public camera API/terms. A codot.gov file page titled "JSON APIs Access URLs for COtrip" exists (image only; contents not read). Contact (UNVERIFIED snippet): cdot_cotrip@state.co.us. Verdict: ask-first.

### Pennsylvania 511PA - partly VERIFIED
- UNVERIFIED (search snippet): "Terms and Conditions Regarding Access to and Use of 511PA Transportation and Travel Data Feeds" (dated 2014) at prdpenndot.pwpca.pa.gov/.../511PA_Developers_Corner-T+Cs.pdf - states PennDOT makes "traffic camera video" feeds available only to Developers agreeing to the T&Cs. Host failed DNS (ENOTFOUND) from our machine -> could NOT read. Another snippet claimed camera images may be used only to show current traffic status (UNVERIFIED, from an unnamed search summary). Verdict: keyed/ask-first.

### NYC DOT TMC (nyctmc.org -> 301 -> webcams.nyctmc.org/map) - partly VERIFIED
- VERIFIED (nyc.gov/html/dot/html/about/datafeeds.shtml, read 2026-10-13): under "Real-Time Traffic Cameras": "Developers wishing to access the cameras' data feed should contact NYC DOT"; developers must sign a data-sharing agreement. Disclaimer: "make no representation as to the accuracy or usefulness of the information"; asks that a NYC DOT disclaimer be included in any retransmission or application.
- VERIFIED (nyc.gov/html/dot/html/motorist/atis.shtml): cameras "provide frequently updated still images from locations in the five boroughs", "only provide live feeds and do not record any footage", may be out of service. No interval stated.
- UNVERIFIED (news/forum snippets): unofficial pattern nyctmc.org/api/cameras/{id}/image, ~2 s refresh, native ~352x240. webcams.nyctmc.org/map is a JS app (no terms/API visible). NOT documented officially; no NYC Open Data camera dataset found. Verdict: ask-first (official route = data-sharing agreement). Also via 511NY keyed API (UNVERIFIED: 511ny.org/developers/doc exists, key + 10 calls/60 s).

### Washington DC - VERIFIED partial
- VERIFIED (catalog.data.gov/dataset/closed-circuit-tv-street-cameras): OCTO "Closed Circuit TV Street Cameras", licence "Creative Commons Attribution 4.0 (CC BY 4.0)", REST: https://maps2.dcgis.dc.gov/dcgis/rest/services/DCGIS_DATA/Transportation_Sensors_WebMercator/MapServer/11 ; CSV/GeoJSON via opendata.dc.gov (item 2bb8375e31a94067a17911ea70f917ef, layers=11). Fields NOT listed on the page; no image-URL field confirmed; this is a camera LOCATION inventory (cameras incl. non-traffic). Last updated 2026-10-13.
- UNVERIFIED: no official DDOT public live still-image endpoint found (ddot.dc.gov lists live cameras aggregated from several providers; TrafficLand is commercial). Verdict: ask-first for images; locations data usable.

### Seattle SDOT - VERIFIED (partly)
- VERIFIED (seattle.gov/Documents/Departments/SDOT/GIS/Traffic_Cameras_OD.pdf, 2018 metadata form): dataset "Traffic Cameras", update frequency Weekly; fields OBJECTID, COMPKEY, UNITID, OWNERSHIP (SDOT/WSDOT), DISTRICT, NAME, COMPTYPE, `URL` ("Link to Traffic Camera live image"), LOCATION, `SERVSTAT` ("Traffic Camera service status"). Lat/lon = layer geometry. Contact dot_it_gis@seattle.gov.
- UNVERIFIED (search snippet): REST layer https://gisdata.seattle.gov/server/rest/services/SDOT/SDOT_Assets/MapServer/9 ; when I fetched ?f=pjson it returned HTTP 500 "service not started" (so URL could not be confirmed live today). ArcGIS Hub dataset on data-seattlecitygis.opendata.arcgis.com.
- VERIFIED (seattle.gov/trafficcams/northgate_1st.htm): "The City of Seattle does not archive or retain any of the images from the traffic cameras." and "The City of Seattle reserves the right to suspend public access to the traffic camera images at any time." No refresh interval or usage terms on the page. Open-data licence not read.
- Verdict: usable (pilot) with polite polling; confirm licence with SDOT GIS.

### DC DDOT CCTV locations - VERIFIED (maps2.dcgis.dc.gov/dcgis/rest/services/DDOT/TrafficOperations/MapServer/2, read 2026-10-13)
- Layer "CCTV location": "DDOT's CCTV camera locations."; copyright "District Department of Transportation"; fields OBJECTID, Location, Latitude, Longitude, CameraID, Installation_Date, Operation_Status (0 Inactive, 1 Active), Description, Make (+ CameraID_in_ATMS, Camera_Type per search snippet, UNVERIFIED). NO image-URL field -> location inventory only, no still/HLS endpoint found.

### Caltrans CWWP2 - connection refused (ECONNREFUSED 149.136.20.139:443) for cwwp2.dot.ca.gov; dot.ca.gov CWWP page fetch also failed; ALL UNVERIFIED (search snippets)
- Portal "Commercial Wholesale Web Portal 2 ... designed to provide real-time travel information to be used by commercial, media ISPs, agencies and the public" (dot.ca.gov/programs/traffic-operations/traveler-information/cwwp). Formats JSON/XML/CSV/TXT; per-district files /data/dNN/...; CCTV field docs cwwp2.dot.ca.gov/documentation/cctv/cctv-field-description.htm: `currentImageURL`, `location.latitude/longitude`, `inService`(per CWWP2 convention, not seen today), `currentImageUpdateFrequency`(minutes), `streamingVideoURL`; `referenceImageUpdateFrequency` is a separate field. Portal says to read "Conditions Of Use" (text NOT read). Verdict: ask-first / re-test from another network.

### Arizona AZ511 - VERIFIED (az511.com/developers/doc)
- Developer key required (registered account first); "ten calls every 60 seconds"; cameras resource /help/endpoint/cameras ("returns all cameras"). Terms not on page (links to Disclaimer/Privacy not read). Field names not read. Verdict: keyed.

### Wisconsin (platform sibling, not requested) - 511wi.gov/developers/doc links a "Developers Access Agreement for 511 API" (docx; unreadable to our fetcher). Shows the Iteris template includes a separate access agreement - expect the same for GA/AZ/FL/NJ/NY (UNVERIFIED).

### Florida FL511 - UNVERIFIED
- fl511.com/developers/doc and /help/endpoint/cameras returned 404. Search snippet: FDOT ITS page for an "Advanced Traveler Information System Data Use Agreement" (updated 5/28/2024; third-party data feed from Florida 511; cameras not mentioned); older FDOT reports mention signed agreements to furnish CCTV feeds to media; 2026 FDOT solicitation for "FL511 Data Integration and Video Aggregation System". Verdict: ask-first/keyed (agreement).

### Virginia VDOT 511 / SmarterRoads - UNVERIFIED
- smarterroads.vdot.virginia.gov (smarterroads.org 301s there) fetched as title-only SPA. Search snippet: SmarterRoads provides raw/processed VDOT data "available to approved users"; no public 511 developer API found. Verdict: ask-first / registration.

### Michigan MiDrive - UNVERIFIED
- michigan.gov/mdot/about/mi-drive-disclaimer returned HTTP 403 to our fetcher. Snippet: cameras "provide live viewing and are not continuously recorded". No developer API found. Verdict: ask-first.

### Illinois Getting Around Illinois / Gateway - UNVERIFIED
- Search snippet (BTAA geoportal, which my fetch could not read - bot check): IDOT open-data ArcGIS FeatureLayer "Gateway Traffic Camera Locations [Illinois]"; says it is NOT a live feed; has an image-path field (travelmidwest.com popup), direction, lat/lon, and a snapshot field described as "public URL of camera's image file ... suitable for placement in an img src tag", plus age-in-minutes / too-old flags (warn >10 min, too old >30 min). Conflicting; underlying IDOT REST endpoint and terms NOT read. Verdict: ask-first.

### New Jersey 511NJ - UNVERIFIED
- 511nj.org/developers/doc returned only the domain (SPA). No NJ-specific developer page found in search. Verdict: ask-first / unknown.

### Georgia GDOT ArcGIS layer (extra lead) - UNVERIFIED
- Snippet: https://rnhp.dot.ga.gov/hosting/rest/services/web_trafficcameras/MapServer/0 "CCTV Camera" with a URL field (256 chars). Fetch today: ArcGIS Web Adaptor error "Could not access any server machines". Not confirmed live; licence unknown.
