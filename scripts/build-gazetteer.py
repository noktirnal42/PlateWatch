#!/usr/bin/env python3 -I
"""Build PlateKit's place gazetteer from the US Census Gazetteer (public domain).

Usage: python3 -I scripts/build-gazetteer.py <dir-with-2023_Gaz_*_national.txt> <out.tsv>
Inputs: 2023_Gaz_place_national.txt, 2023_Gaz_cousubs_national.txt, 2023_Gaz_counties_national.txt
        from https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2023_Gazetteer/
Output columns (TSV, sorted): state  name  kind  lat  lon  geoid  area_sqmi
Used by AgencyInference to validate OCR'd place names against real places in the plate's state.
"""
import csv, re, sys, os

src, out = sys.argv[1], sys.argv[2]
# LSAD suffixes the Census appends to names; longest first.
SUFFIXES = ["city and borough", "census designated place", "consolidated government", "unified government",
            "metropolitan government", "charter township", "urban county", "municipality", "plantation",
            "reservation", "borough", "township", "village", "town", "city", "CDP", "county", "parish",
            "island", "county equivalent", "(balance)"]
KIND = {"city": "city", "town": "town", "village": "village", "borough": "borough", "township": "township",
        "CDP": "cdp", "county": "county", "parish": "county", "municipality": "city", "plantation": "town"}

def clean(name):
    n = name.strip()
    n = re.sub(r"\s*\(balance\)$", "", n)
    kind = "place"
    for s in sorted(SUFFIXES, key=len, reverse=True):
        if n.lower().endswith(" " + s.lower()):
            kind = KIND.get(s, KIND.get(s.split()[-1], "place"))
            n = n[: -(len(s) + 1)].strip()
            break
    return n, kind

rows = {}
def read(fname, force_kind=None):
    with open(os.path.join(src, fname), encoding="latin-1") as f:
        r = csv.reader(f, delimiter="\t")
        header = [h.strip() for h in next(r)]
        ix = {h: i for i, h in enumerate(header)}
        for row in r:
            if len(row) < len(header): continue
            state, geoid = row[ix["USPS"]].strip(), row[ix["GEOID"]].strip()
            name, kind = clean(row[ix["NAME"]])
            if force_kind: kind = force_kind
            if not name or name.lower().startswith(("county subdivisions not defined", "not defined")): continue
            lat, lon = row[ix["INTPTLAT"]].strip(), row[ix["INTPTLONG"]].strip()
            area = row[ix["ALAND_SQMI"]].strip() if "ALAND_SQMI" in ix else "0"
            key = (state, name.lower(), kind)
            rows.setdefault(key, (state, name, kind, lat, lon, geoid, area))

read("2023_Gaz_counties_national.txt", "county")
read("2023_Gaz_place_national.txt")
read("2023_Gaz_cousubs_national.txt")           # New England / Mid-Atlantic towns & townships
with open(out, "w", encoding="utf-8") as f:
    for key in sorted(rows):
        f.write("\t".join(rows[key]) + "\n")
print(len(rows), "rows ->", out, os.path.getsize(out), "bytes")
