# More public camera sources for the PlateWatch Hub (snapshotJPEG) - research 2026-10-14

Method: real HTTP requests from the dev machine, User-Agent `PlateWatchResearch/0.1 (+https://github.com/noktirnal42/PlateWatch)`, ~1 request/second, robots.txt checked per image host, one catalogue pull + 3-8 sampled images per source (no bulk polling). No tracked repo files were edited, nothing committed, no symlinks. Raw catalogue pulls and scripts live in `/private/tmp/pw-research/` (`w/`, `ag.py`, `agall.py`, `sample.py`).
Machine-readable list of READY sources: `/private/tmp/pw-research/more-sources.json` (also contains a second array `termsUnclearButWorkingKeyless`).
Not legal advice. Status meaning: READY = no key, keyless catalogue AND keyless live still verified, open/explicit public-use terms. NEEDS-KEY = free key/registration needed for the catalogue. TERMS-UNCLEAR = technically works keyless but no open licence read/found (or conflicting robots). NO = forbids automation, login, video-only, dead, or robots disallow.

"Last-Modified" below is the age of sampled images at request time (2026-10-14 ~22:00-22:12 UTC).

## Summary table

| # | Source | Jurisdiction | Cameras | Status | Catalogue | Licence / terms |
|---|---|---|---|---|---|---|
| 1 | Caltrans CWWP2 CCTV | CA state | 3,405 in service (3,597 listed) | READY | JSON per district | Public domain unless noted; "no charge" |
| 2 | WSDOT ArcGIS cameras | WA state | 1,706 | READY (low volume) | ArcGIS FS | "low volume use only" |
| 3 | Iowa DOT traffic cams | IA state | 1,262 | READY | ArcGIS FS | CC BY 4.0 + site rate limit |
| 4 | Iowa DOT plow-cam photos | IA state | ~999/h | READY (non-fixed) | ArcGIS FS | CC BY 4.0 |
| 5 | Calgary traffic cameras | CA-AB city | 214 | READY (text unread) | Socrata | Open Calgary terms |
| 6 | DriveBC webcams | CA-BC province | 1,042 on / 1,067 | READY | JSON | OGL-BC |
| 7 | NL highway cameras | CA-NL province | 48 | READY | ArcGIS FS | NL OGL |
| 8 | Toronto traffic cameras | CA-ON city | 336 | READY | GeoJSON (CKAN) | OGL-Toronto |
| 9 | Singapore LTA traffic images | SG | 8 returned now | READY (partial feed) | JSON | Singapore Open Data Licence |
| 10 | Hong Kong TD snapshots | HK | 1,013 | READY | UTF-16 TSV/CSV | DATA.GOV.HK T&C |
| 11 | Digitraffic weather cams | FI | 814 stations / 2,280 images | READY | GeoJSON | CC BY 4.0 |
| 12 | NYC DOT TMC | NYC | 982 (981 online) | TERMS-UNCLEAR | JSON | none found; C&D history |
| 13 | Illinois Gateway | IL state | 1,495 | TERMS-UNCLEAR / robots disallow | ArcGIS FS | CC BY-SA 2.0 but host robots `Disallow: /` |
| 14 | UDOT CCTV (ArcGIS) | UT state | 1,437 | TERMS-UNCLEAR | ArcGIS FS | disclaimer only |
| 15 | WisDOT 511 cams | WI state | 456 | TERMS-UNCLEAR | ArcGIS FS + `511wi.gov/map/Cctv/{ViewsId}` | terms page JS-only |
| 16 | Louisiana DOTD / 511la | LA state | 435 | TERMS-UNCLEAR | ArcGIS FS | unread |
| 17 | Alberta 511 | CA-AB province | 380 | TERMS-UNCLEAR (non-commercial) | ArcGIS FS | "non-commercial (educational)" |
| 18 | Oregon TripCheck (OEM mirror) | OR state | 1,189 | TERMS-UNCLEAR | ArcGIS FS | none found |
| 19 | FL511 mirror | FL state | 4,057 | TERMS-UNCLEAR | ArcGIS FS (unofficial) | unread |
| 20 | Seattle SDOT | Seattle | 393 | TERMS-UNCLEAR | ArcGIS FS (deprecated) | disclaimer only |
| 21 | Honolulu GoAkamai | HI city/state | 168 | TERMS-UNCLEAR | ArcGIS FS | licence "None" |
| 22 | Arlington TX | city | 103 | TERMS-UNCLEAR | ArcGIS FS | none |
| 23 | NZTA | NZ | 224 | TERMS-UNCLEAR | ArcGIS FS | "request API access" |
| 24 | TfL JamCams | London | 819 available / 890 | TERMS-UNCLEAR | JSON | terms page not readable |
| 25 | MnDOT (mirror) | MN state | 79 | TERMS-UNCLEAR | ArcGIS FS | none |
| 26 | Kirkland / Redmond / Bellevue (Kirkland GIS layer) | WA cities | 57 | TERMS-UNCLEAR | ArcGIS FS | none (mixed hosts) |
| 27 | WSDOT HighwayCameras REST API | WA | - | NEEDS-KEY | REST | AccessCode (free) |
| 28 | Ohio OHGO | OH | - | NEEDS-KEY | REST | HTTP 401 "API key required" |
| 29 | Oregon TripCheck official API | OR | - | NEEDS-KEY | REST (APIM) | "missing subscription key" |
| 30 | 511 platform states: AZ, GA, FL, ID, NV, AK, PA, UT, LA, WI, NC (DriveNC), CT, NY(?) | - | - | NEEDS-KEY | `/api/v2/get/cameras` | HTTP 400 "Invalid Key" (see note below) |
| 31 | Iowa CARS hub XML (`ia.carsprogram.org/hub/data/cctv.xml`) | IA | - | NEEDS-KEY | XML | HTTP 401 (request form via Castle Rock) |
| 32 | FAA WeatherCams | US federal | - | NEEDS-KEY | `weathercams.faa.gov/api/sites` | HTTP 401 |
| 33 | Maryland CHART | MD | 552 | NO (video only) | JSON/ArcGIS/Socrata | HLS/RTMP only, no still URL |
| 34 | MoDOT StreamingCams | MO | ~hundreds | NO (video only) | JSON | HLS only |
| 35 | DelDOT | DE | 362 | NO (video only) | ArcGIS FS (test server) | HLS only |
| 36 | Kentucky KYTC layer | KY | 256 | NO | ArcGIS FS | image hosts: trimarc.org `Disallow: /`; trafficwise URLs return HTML |
| 37 | Michigan MiDrive | MI | 681 | NO | ArcGIS FS | image host micamerasimages.net `Disallow: /` |
| 38 | Colorado CDOT layer | CO | 908 | NO (dead) | ArcGIS FS (2017) | `cotrip.org/images/camera?...` now serves the SPA HTML |
| 39 | PennDOT 511PA | PA | - | NO / key | API | developer T&Cs: images only to show current traffic status (search snippet) |
| 40 | Houston TranStar / Louisville TRIMARC / tnsnapshots.com (TN) | - | - | NO | - | TranStar terms (earlier research); trimarc + tnsnapshots robots `Disallow: /` |
| 41 | CalOES / ALERTCalifornia webcams | CA | 4,345 | NO for reuse | ArcGIS FS | ALERTCalifornia part CC BY-NC-ND 4.0; Caltrans part duplicates #1; mostly fire cams |
| 42 | Salem OR, Lexington KY, Teton WY, Maryland/NOLA/Baton Rouge Socrata sets, DC DDOT, Idaho ArcGIS, Ontario MTO, Quebec MTQ, Georgia GDOT layer | - | - | NO / unverifiable | - | see per-source notes |

Counts of verified entries: 11 READY, 15 TERMS-UNCLEAR with working keyless stills, ~6 NEEDS-KEY, ~12 NO/dead/unverifiable (>40 distinct sources examined).

## READY sources (full detail)

### 1. Caltrans CCTV (CWWP2) - READY, 3,405 cameras
- Catalogue: `https://cwwp2.dot.ca.gov/data/d{1..12}/cctv/cctvStatusD{01..12}.json` (also `.csv`, `.xml`, `.txt`). Verified all 12 districts HTTP 200 (D01 146, D02 91, D03 275, D04 759, D05 181, D06 128, D07 592, D08 505, D09 23, D10 154, D11 324, D12 419 = 3,597 records; 3,405 `inService` with an image URL). 
  - Note: the repo docs say cwwp2 refused connections; from this machine today it works.
- JSON shape: `{"data":[{"cctv":{...}}]}`; `cctv.index`, `cctv.location.locationName / latitude / longitude / nearbyPlace / route / direction`, `cctv.inService` ("true"/"false" strings), `cctv.imageData.static.currentImageURL`, `cctv.imageData.static.currentImageUpdateFrequency` (minutes: 5 = 1211 cams, 2 = 1129, 3 = 501, 1 = 399, 15/10/60/20 = rest), `cctv.imageData.streamingVideoURL` (HLS - ignore).
- Image pattern: `https://cwwp2.dot.ca.gov/data/d3/cctv/image/hwy5atpocket/hwy5atpocket.jpg` (derived per camera - use the catalogue URL). Sampled 9 images: `image/jpeg`, 7-114 KB, Last-Modified 0-5 min old.
- Terms: CWWP2 page "There is no charge for the use of this data. Please read the Conditions Of Use" (`https://cwwp2.dot.ca.gov/documentation/cctv/cctv.htm`) -> `https://dot.ca.gov/conditions-of-use`: "information presented on this website, unless otherwise indicated, is considered in the public domain. It may be distributed or copied as permitted by law." (also warns about third-party copyrighted data). The CWWP2 page states "Caltrans traffic camera video footage and still images are neither retained nor archived."
- robots: `cwwp2.dot.ca.gov/robots.txt` returns HTTP 500 (nothing usable). No key.
- Refresh: per-camera field above; poll no faster than 2-5 min.

### 2. WSDOT cameras via ArcGIS - READY (low volume), 1,706
- Catalogue: `https://data.wsdot.wa.gov/arcgis/rest/services/TravelInformation/TravelInfoCamerasWeather/FeatureServer/0/query?where=1%3D1&outFields=*&outSR=4326&f=json` (count 1706, maxRecordCount 2000). Fields: `OBJECTID`, `CameraTitle`, `ImageURL`, `CompassDirection`; lat/lon in `geometry.y/x` (request `outSR=4326`).
- Images: 1,631 on `https://images.wsdot.wa.gov/{region}/{route}vc{milepost}.jpg` (e.g. `/nw/167vc01358.jpg`), ~65 on `tripcheck.com` (Oregon), 3 Azure blob, 1 other. 6 samples: image/jpeg 22-114 KB, Last-Modified 10 s - 2 min.
- Terms: item `6692b4f163bd4ec99b5a897b2d207aa6` licenseInfo: "This data feed is intended for \"low volume\" use only. The Washington State Department of Transportation (WSDOT) may cancel or restrict access for any reason." Description: image refreshed ~every 5 minutes. WSDOT's own API (`/Traffic/api/HighwayCameras/...`) needs an AccessCode (HTTP 401 verified) but this layer does not.
- robots (images.wsdot.wa.gov): `Disallow: /Ferries/` only.

### 3. Iowa DOT Traffic Cameras - READY, 1,262
- Catalogue: `https://services.arcgis.com/8lRhdTsQyJpO52F1/arcgis/rest/services/Traffic_Cameras_View/FeatureServer/0/query?...` (the "Iowa DOT Traffic Cameras (CCTV)" dataset linked from `iowadot.gov/travel-tools/iowa-511/511-data-feeds`, "do not require credentials"). Fields: `device_id`, `Desc_`, `ImageURL`, `VideoURL`, `latitude`, `longitude`, `Route`, `REGION`, `Type` (364 RWIS, rest "Iowa DOT"), `UpdateDate/UpdateTime`.
- Image host `https://atmsqf.iowadot.gov/snapshots/...` (e.g. `/SNAPSHOTS/PUBLIC/Metro/cbtv74hd.jpeg`, 280 KB). 6 samples: 4 OK (Last-Modified 0-3 min old), 2 HTTP 404 (offline cams; path-case varies - never rewrite URLs).
- Terms: item licenseInfo CC BY 4.0 + "Iowa DOT's GIS Data Terms of Use" (`https://iowadot.gov/policies_and_statements/terms-of-use`, GIS section: CC0 or CC BY by dataset). Site terms: "You agree that you will not use or launch any automated system, including without limitation robots, spiders ... to monitor or copy the Iowa DOT's Web pages ... or to access the Site in a manner that sends more requests to the server ... than a typical human would". So: attribute, poll gently (spread requests, 1 per camera per >= 5 min, global cap).
- robots: atmsqf.iowadot.gov/robots.txt = 404.
- Related (not in JSON): `RWIS_Camera_Info_View` (309 RWIS positions, last 10 images each, `IMAGE_URL_SECURE`, no geometry - join needed; already covered by the 364 RWIS rows above) and the Iowa CARS XML (`ia.carsprogram.org/hub/data/cctv.xml`) = HTTP 401 (key via Castle Rock).

### 4. Iowa DOT plow-cam photos - READY but different shape, ~999 per hour
- `https://services.arcgis.com/8lRhdTsQyJpO52F1/arcgis/rest/services/AVL_Images_Past_1HR_View/FeatureServer/0` (fields `PHOTO_UID`, `PHOTO_ANUMBER` (truck), `PHOTO_LATITUDE/LONGITUDE`, `SECURE_PHOTO_URL`, `PHOTO_FILEDATE`, `ROUTE_NAME`, `GARAGE_NAME`). Images `https://cloud.iowadot.gov/Highway/Photos/Maintenance/MapSnapShots/SnowPlow/YYYY/MM/DD/A35694-....jpg`, 20-24 KB JPEG, verified (Last-Modified 1-3 h old, rolling window).
- Licence: CC BY 4.0 (same Iowa DOT GIS terms). Relevant to the fleet goal (government vehicles) but each frame is a moving-vehicle photo: needs per-frame GPS, not a fixed-camera poller. Photos can include private vehicles - redact per LEGAL-ETHICS. Sibling layers: Minnesota (96 rows, S3 URLs) and Nebraska (19 stale rows) not image-tested.

### 5. City of Calgary Traffic Cameras - READY (licence text unread), 214
- Catalogue: `https://data.calgary.ca/resource/k7p9-kppz.json` (Socrata; `$select=count(*)` = 214). Fields: `camera_location`, `quadrant`, `camera_url.url` (+ `.description` "Camera 75"), `point.coordinates` [lon, lat].
- Image: `http://trafficcam.calgary.ca/loc74.jpg` (pattern `loc{N}.jpg`; https also works) - 96-134 KB JPEG, Last-Modified 1-2 min old, `Cache-Control: no-cache`.
- Terms: Socrata `license: "See Terms of Use"`, attribution "The City of Calgary" -> `https://data.calgary.ca/d/Open-Data-Terms/u45n-7awa` (JS-rendered; I could not extract the grant sentence). The City publishes under its Open Government Licence; confirm text before enabling. Dataset description: "cameras are solely for traffic monitoring and not enforcement. Camera footage is not recorded."
- robots: `trafficcam.calgary.ca/robots.txt` 404.

### 6. DriveBC (BC Ministry of Transportation) - READY, 1,042 online of 1,067
- Catalogue: `https://www.drivebc.ca/api/webcams/` (1.2 MB JSON array). Fields: `id`, `name`, `location.coordinates` [lon, lat], `is_on`, `marked_stale`, `marked_delayed`, `last_update_modified`, `update_period_mean` (seconds; mostly ~900), `links.imageDisplay` = `/images/{id}.jpg?t=...`.
- Image: `https://www.drivebc.ca/images/{id}.jpg` (verified 904, 905: 49-56 KB JPEG; no Last-Modified; `expires` header reflects update time). robots.txt: allow all.
- Terms: released on DataBC under the Open Government Licence - British Columbia; API terms page `https://www2.gov.bc.ca/gov/content/data/policy-standards/data-policies/open-data/api-terms-of-use-for-ogl-information` (web-search summary; page body not fully read). bcgov README (`github.com/bcgov/drivebc-webcam-api`) describes release "for commercial use under the OGL".

### 7. Newfoundland & Labrador highway cameras - READY, 48
- `https://services8.arcgis.com/aCyQID5qQcyrJMm2/arcgis/rest/services/TI_HighwayCamera/FeatureServer/0` fields `location`, `url`, `CamType`, geometry. Images `https://www.gov.nl.ca/ti/highway-cams/cameras/sites/{site}/current.jpg` (7-37 KB; Last-Modified 0-25 min). 
- Licence (item): "licensed under the Newfoundland and Labrador Open Government Licence". Data "for illustration purposes only".

### 8. City of Toronto Traffic Cameras - READY, 336
- Catalogue (CKAN package `traffic-cameras`): GeoJSON `https://ckan0.cf.opendata.inter.prod-toronto.ca/dataset/a3309088-5fd4-4d34-8297-77c8301840ac/resource/4a568300-c7f8-496d-b150-dff6f5dc6d4f/download/traffic-camera-list-4326.geojson`. Properties `REC_ID`, `MAINROAD`, `CROSSROAD`, `IMAGEURL`, `REFURL1..4` (comparison images), `DIRECTION1..`; geometry MultiPoint [[lon,lat]]. CKAN also names the live list `https://opendata.toronto.ca/transportation/tmc/rescucameraimages/Data/tmcearthcameras.json`.
- Image `https://opendata.toronto.ca/transportation/tmc/rescucameraimages/CameraImages/loc9301.jpg`: 21-131 KB, Last-Modified 1-6 min old; **several are PNG bytes served as image/jpeg** (sniff magic bytes).
- Terms (`https://open.toronto.ca/open-data-licence/`): Open Government Licence - Toronto: "Copy, modify, publish, translate, adapt, distribute or otherwise use the Information in any medium, mode or format for any lawful purpose." Attribution: "Contains information licensed under the Open Government Licence - Toronto."

### 9. Singapore LTA traffic images - READY (partial), 8 now
- `https://api.data.gov.sg/v1/transport/traffic-images` -> `items[0].cameras[]` with `camera_id`, `location.latitude/longitude`, `image` (per-snapshot URL, changes each minute), `timestamp`, `image_metadata` (1920x1080). Verified image 134 KB, Last-Modified ~2 min old. **Only 8 cameras returned today** (normally ~90) - treat as flaky.
- Licence: "You can use, access, download, copy, distribute, transmit, modify and adapt the datasets ... whether commercially or non-commercially" (`https://data.gov.sg/open-data-licence`). No key (rate-limited by gateway). Image host robots = AccessDenied XML (no robots).

### 10. Hong Kong Transport Department traffic snapshots - READY, 1,013
- Catalogue: `https://static.data.gov.hk/td/traffic-snapshot-images/code/Traffic_Camera_Locations_En.csv` (UTF-16LE, tab-separated; columns `key, region, district, description, easting, northing, latitude, longitude, url`). Image `https://tdcctv.data.one.gov.hk/{key}.JPG`, 8-28 KB, Last-Modified 1-3 min old. robots 404.
- Terms (`https://data.gov.hk/en/terms-and-conditions`): "You are allowed to browse, download, distribute, reproduce, hyperlink to, and print the Data for both commercial and non-commercial purposes on a free-of-charge basis on condition that ... proper attribution". Low-res; mix of road CCTV and incident-detection cameras.

### 11. Fintraffic Digitraffic road weather cameras (Finland) - READY, 814 stations / 2,280 images
- Catalogue `https://tie.digitraffic.fi/api/weathercam/v1/stations` (GeoJSON; **must send `Accept-Encoding: gzip`**, else HTTP 406; they request a `Digitraffic-User` header). `properties.name`, `properties.collectionStatus`, `properties.presets[].id`; geometry [lon, lat, 0].
- Image `https://weathercam.digitraffic.fi/{presetId}.jpg` (e.g. `C0150301.jpg`, 297 KB, Last-Modified ~1 min old).
- Terms (`https://www.digitraffic.fi/en/terms-of-service/`): "Fintraffic's open data is licensed under the Creative Commons 4.0 By license ... even commercially, as long as you credit the source." Attribution: "Source: Fintraffic / digitraffic.fi, license CC 4.0 BY".

## TERMS-UNCLEAR (keyless stills verified, terms not open/readable) - details

| Source | Catalogue endpoint | Fields (name / lat / lon / image / id) | Image pattern & test | Why not READY |
|---|---|---|---|---|
| NYC DOT TMC (982) | `https://webcams.nyctmc.org/api/cameras` (JSON array) | `name` / `latitude` / `longitude` / `imageUrl` / `id` (+`area`, `isOnline`) | `https://webcams.nyctmc.org/api/cameras/{id}/image` -> JPEG 22 KB, `cache-control: no-store` | No terms/licence found (`nyc.gov` datafeeds page is Akamai "Access Denied" to curl). 404 Media reports a DOT cease-and-desist to a site reusing the cams. robots.txt serves the SPA (none). Ask NYC DOT. |
| Illinois Gateway (1,495) | ArcGIS `https://services2.arcgis.com/aIrBD8yn1TDTEXoz/arcgis/rest/services/TrafficCamerasTM_Public/FeatureServer/0` | `CameraLocation` / `y` / `x` / `SnapShot` / `OBJECTID` (+`AgeInMinutes`, `TooOld`) | `https://cctv.travelmidwest.com/snapshots/IL-IDOTD1_...jpg` JPEG 27 KB, 11 min old | Item licence CC BY-SA 2.0, **but `cctv.travelmidwest.com/robots.txt` = `Disallow: /`**. Do not poll without Travel Midwest/IDOT permission. |
| UDOT CCTV layer (1,437) | `https://services.arcgis.com/pA2nEVnB6tquxgOW/arcgis/rest/services/CCTV/FeatureServer/0` | `DisplayName` / geom.y / geom.x / `ImageUrl` / `ExtId` | `http://udottraffic.utah.gov/1_devices/aux14779.jpeg` JPEG 98 KB, 0-13 min old | Staff-owned item, disclaimer only; UDOT API requires a key (`/api/v2/get/cameras` -> Invalid Key). udottraffic robots disallows `/map/map*/` etc. but not `/1_devices/`. |
| WisDOT 511 (456) | `https://services5.arcgis.com/0pgGLzT0Nh7FVjon/arcgis/rest/services/511_Camera_Public/FeatureServer/0` | `Location` / `Latitude` / `Longitude` / (build) / `Id`,`ViewsId` | `https://511wi.gov/map/Cctv/{ViewsId}` -> live PNG 352x259 (timestamp overlay 5:04 PM), 113-221 KB, Last-Modified = now | 511wi terms page is JS-rendered (unreadable); official API wants a developer key. robots allows `/map/Cctv` (disallows `/map/map*/`, `/my511/`). |
| Louisiana DOTD (435) | `https://services1.arcgis.com/fXHQyq63u0UsTeSM/arcgis/rest/services/DOTD_Traffic_Cameras/FeatureServer/0` | `Name` / `Latitude` / `Longitude` / `Url` / `Id` | `https://511la.org/map/Cctv/127--1` JPEG 352x240, 20-45 KB, Last-Modified = now | GOHSEP-owned item; 511la terms unread; API needs key. |
| Alberta 511 (380) | `https://services.arcgis.com/wjcPoefzjpzCgffS/arcgis/rest/services/Alberta511/FeatureServer/0` | `Location` / geom / `Url` / `Id` | `https://511.alberta.ca/map/Cctv/226` JPEG 34-84 KB, Last-Modified = now | Item terms: "personal and public non-commercial (educational) use ... may be reproduced ... without charge or further permission" - non-commercial only. |
| Oregon TripCheck mirror (1,189) | `https://services.arcgis.com/uUvqNMGPm7axC2dD/arcgis/rest/services/TripCheck_Cameras/FeatureServer/0` | `attributes_title` / `attributes_latitude` / `attributes_longitude` / `attributes_filename` / `attributes_cameraId` | `https://tripcheck.com/RoadCams/cams/<name>_pid<id>.JPG` (percent-encode spaces): 27-30 KB; fresh for `www.tripcheck.com/.../i5brnbn_pid552.jpg`, stale (June) for Jacksonville Hill | No terms found (tripcheck.com robots 404, terms pages not located); ODOT API needs subscription key. |
| FL511 unofficial mirror (4,057) | `https://services.arcgis.com/3wFbqsFPLeKqOlIK/arcgis/rest/services/FL511_Traffic_Cameras/FeatureServer/0` | `DESCRIPT` / `LATITUDE` / `LONGITUDE` / `IMAGE` / `ID` | `https://images-dis.divas.cloud/DGI/chan-5924_h.jpg` JPEG 10-23 KB, Last-Modified 2 min | Personal 2022 item (stale `TIMESTAMP`); FL511 terms unread; official API needs key. |
| Seattle SDOT (393) | `https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services/Traffic_Cameras_CDL/FeatureServer/0` | `LOCATION` / geom / `URL` / `UNITID` | `https://www.seattle.gov/trafficcams/images/{STREAM_NAME}.jpg` JPEG 72-165 KB, 7 min old | Layer is flagged DEPRECATED; only a "no warranty" disclaimer; SDOT replacement layer has no image field. seattle.gov robots: Allow all. 262 more rows are WSDOT cams (use #2). |
| Honolulu (168) | `https://services.arcgis.com/6I1ysurtNWNxkuwd/arcgis/rest/services/HawaiiTrafficCameras/FeatureServer/0` | `Camera_Description` / geom / `URL` / `OBJECTID` | `http://cctv.cdn.goakamai.org//SnapShot/320x240/TL-0053.jpg` JPEG 19-25 KB, fresh | Individual's item; data.honolulu.gov (`cat5-2v98`) licence "None"; robots 404. |
| Arlington TX (103) | `https://services.arcgis.com/jXi5GuMZwfCYtZP9/arcgis/rest/services/Traffic_Camera_Updates/FeatureServer/0` | `Camera_Location` / `Lat` / `Long` / `Pic_URL` / `ObjectId` | `https://webapps.arlingtontx.gov/webcams/Abram_Center.jpg` JPEG 89 KB, 1 min old | Staff item, no licence. |
| NZTA (224) | `https://services.arcgis.com/CXBb7LAjgIIdcsPt/arcgis/rest/services/LiveCamerasNZTA_Public_View/FeatureServer/0` | `name` / `lat` / `lon` / `imageurl` / `id` | `http://www.trafficnz.info/camera/190.jpg` JPEG, 0-1 min old (one cam last updated 2021) | Item says API access by request to Infoconnect@nzta.govt.nz. |
| TfL JamCams (890; 819 available) | `https://api.tfl.gov.uk/Place/Type/JamCam` | `commonName` / `lat` / `lon` / `additionalProperties[imageUrl]` / `id` | `https://s3-eu-west-1.amazonaws.com/jamcams.tfl.gov.uk/00002.00865.jpg` 15 KB, 1.5 min old | TfL terms page behind a JS challenge; TfL asks for a registered app key. Almost certainly open-data friendly - get the licence text first. |
| MnDOT mirror (79) | `https://services6.arcgis.com/MU31z9HAakdc3W69/arcgis/rest/services/mydata/FeatureServer/0` | `name` / `location_l` / `location_1` / `views_url` / `id` | `https://video.dot.state.mn.us/video/image/metro/C617` JPEG 36 KB live; `.../C6231` -> 404 | Partial mirror; robots.txt 503; no terms. |
| Kirkland GIS combo (57) | `https://services2.arcgis.com/loGMwowmR0OPlOQb/arcgis/rest/services/TRN_TrafficCams_10032022/FeatureServer/0` | `LOCATION` / `LAT` / `LON` / `IMAGE_` / `TRAFCAM_ID` | `https://its.kirklandwa.gov/CamView/132ndSt106thPlJHSPTZ.jpg` 29 KB, fresh | Mixed owners (Kirkland 28, WSDOT 11, Bellevue 9 (HTML page, not image), Redmond 9); no licence. |

## NEEDS-KEY / registration (verified by real request)
- **WSDOT Traveler Information API** `https://www.wsdot.wa.gov/Traffic/api/HighwayCameras/HighwayCamerasREST.svc/GetCamerasAsJson` -> HTTP 401 "The supplied access code was missing or invalid." (use #2 instead, keyless).
- **Ohio OHGO** `https://publicapi.ohgo.com/api/v1/cameras` -> 401 `{"errorDescription":"API key required."}`.
- **Oregon TripCheck API** `https://api.odot.state.or.us/tripcheck/Cctv/Inventory` -> 401 "missing subscription key".
- **Castle Rock/Iteris 511 platform** (`/api/v2/get/cameras?format=json`) -> HTTP 400 `<Error><Message>Invalid Key</Message></Error>` on: az511.gov, 511ga.org, fl511.com, 511wi.gov, 511.idaho.gov, www.nvroads.com, 511.alaska.gov, www.511pa.com, 511la.org, www.udottraffic.utah.gov, drivenc.gov, www.ctroads.org. (511ny.org, 511mn.org, 511in.org, 511ia.org returned the SPA HTML - API location not found.) Side finding: on this platform `https://{host}/map/Cctv/{cameraId}` returns a live still without a key for az511.gov, fl511.com, 511.idaho.gov, 511.alaska.gov, 511.alberta.ca, hotline.gov.sk.ca, 511la.org, 511wi.gov (ids from other catalogues: id 1 gave a real JPEG on AZ/FL/ID/AK; a 15,136-byte PNG is the generic "no image" placeholder on NV/UT/PA/NC/CT/Ontario). Only the camera-id catalogues need the key, and their terms are JS-rendered; handle as TERMS-UNCLEAR until a state confirms in writing.
- **CARS hub XML** `https://ia.carsprogram.org/hub/data/cctv.xml` -> 401 Unauthorized (request via Castle Rock). COtrip `data.cotrip.org/api/v1/cameras` -> 404 (key platform moved).
- **FAA WeatherCams** `https://weathercams.faa.gov/api/sites` -> 401 Unauthorized (needs account/key). Not verified: NPS API (key by design), USGS HIVIS (no JSON endpoint located), NOAA NDBC buoycams (`https://www.ndbc.noaa.gov/buoycam.php?station=46059` returns a live 112 KB JPEG but there is no machine catalogue checked and they are ocean cams - not vehicle-relevant).

## NO / unusable
- **Maryland CHART** (552): all endpoints (`https://chart.maryland.gov/DataFeeds/GetCamerasJson`, ArcGIS `chartimap1.sha.maryland.gov/.../CHART/Cameras/MapServer/0`, Socrata `opendata.maryland.gov/resource/hua3-qc8n`) give HLS/RTMP/viewer-page URLs only, no still image.
- **MoDOT** `https://traveler.modot.org/timconfig/feed/desktop/StreamingCams2.json`: JSON with lat/lon and HLS `html` field only (video).
- **DelDOT** layer on `enterprise.firstmaptest.delaware.gov` (362): HLS only; the production host does not serve the service.
- **Kentucky KYTC** `trafficCamerasCur_Prd` (256): 250 images on `www.trimarc.org` (robots `User-agent: * Disallow: /`; sample URLs 404), 6 on `pws.trafficwise.org` (HTML, not image).
- **Michigan MiDrive** layer (681): images `https://micamerasimages.net/thumbs/...` serve JPEG but robots.txt is `Disallow: /`; old `mdotjboss.../MiDrive/camera/AllForView` is 404.
- **Colorado CDOT** `CDOT_Traffic_Cameras_V2` (908, 2017 snapshot): `cotrip.org/images/camera?imageURL=...` now returns the 511 single-page-app HTML.
- **PennDOT 511PA**: key + developer T&Cs (search snippet): camera images may only be used "to show the current traffic status".
- **Houston TranStar** (prohibits framing/linking/redistribution without TxDOT consent - from repo research), **TN** `tnsnapshots.com` thumbnails (robots `Disallow: /`), **Louisville TRIMARC**.
- **CalOES California Webcams** (4,345): licence text: ALERTCalifornia data "CC BY-NC-ND 4.0 ... may not be used for commercial purposes, redistributed commercially, or used to create derivative products"; 2,936 rows are the Caltrans feed (#1), 1,289 ALERTCalifornia fire cams (images work, `latest-frame.jpg`, but ND/NC), 120 Nevada seismo-lab cams.
- **Not usable as image sources**: Idaho `Webcams` layer (page URLs only), Ontario MTO layer (1,087; `511on.ca/map/Cctv/..` returned the placeholder), Quebec MTQ WFS `infos_cameras` (680, CC BY 4.0 but only a video-window URL), Baton Rouge/NOLA/Calgary-enforcement/Maryland Socrata sets (video pages or enforcement), DC DDOT (235 locations only, no image), Salem OR (23; images last modified 2025-2026), Lexington KY (108; thumbnails from a Wowza server, PNG placeholders), Teton County WY (65; mostly 404/timeouts), Lincoln NE (page URLs), MoCo TX (private IPs), Philadelphia/Riverside/Raleigh layers (no image field), Georgia GDOT layer (3,216 rows, `navigator-c2c.dot.ga.gov/snapshots/*.jpg` timed out twice - **unverified**), Durham/Lancashire (UK, page URLs).
- **Not verified**: NJ 511/NJDOT (HTTP 403 Access Denied to curl), Virginia VDOT (no public endpoint found; `511.vdot.virginia.gov/services/...` 404), Massachusetts MassDOT CCTV layer (845 locations, no image field), Tennessee SmartWay (SPA, no catalogue found; TDOT mirror gives video + tnsnapshots thumbs), Texas (DriveTexas `api/conditions.geojson` HTTP 500, TxDOT ITS endpoints 404; no open camera layer found), North Carolina (old TIMS endpoint replaced; DriveNC API keyed), Arizona/Nevada/Alaska/Idaho/Georgia/Florida official catalogues (key), Minnesota/Indiana/Alabama/Arkansas/Mississippi/Oklahoma/Kansas/Nebraska/Dakotas/Montana/Wyoming/NM (no keyless catalogue located), Hawaii HDOT official feed, USGS/NPS/NOAA/ski/airport cams (no keyless catalogue found beyond NDBC buoycam).

## Implementation notes for the Hub
1. Generic adapters needed: **ArcGIS FeatureServer** (query with `outSR=4326`, paginate by `resultOffset` / `exceededTransferLimit`), **Socrata**, **GeoJSON/JSON array** with per-source `fieldMap`, plus special cases: Caltrans (12 files, `data[].cctv`), Singapore (per-poll image URL), Digitraffic (presets -> URL template, gzip header), Hong Kong (UTF-16 TSV).
2. Validate each fetched image by magic bytes, not Content-Type (Toronto serves PNG as image/jpeg; 511 platform serves PNG "no image" placeholder of exactly 15,136 bytes).
3. Record the camera's native resolution, `Last-Modified` and (where given) the agency's refresh period; never poll faster than the agency floor (Caltrans 2-5 min, WSDOT 5 min, DriveBC ~15 min, Iowa >=5 min with global rate cap).
4. Attribution strings required: Caltrans ("Camera: Caltrans"), Iowa DOT (CC BY 4.0), Toronto (OGL-Toronto statement), HK (DATA.GOV.HK), Digitraffic ("Source: Fintraffic / digitraffic.fi, license CC 4.0 BY"), OGL-BC, NL OGL, Singapore licence.
5. Everything above is catalogue-level only; per `docs/LEGAL-ETHICS.md` the Hub must still redact/skip un-redacted private-citizen plates, and `automatedUseAllowed` should stay false until a person has read each terms URL (several terms pages here are JS-rendered and could not be read by curl).
