#!/usr/bin/env python3 -I
"""Export locally queued, agency-resolved fleet vehicle crops from the running Hub as LABELLED training material.

Usage: python3 -I scripts/export_fleet_plate_crops.py <out dir> [--dry-run]
Talks to the Hub's authenticated loopback bridge (same discovery file the MCP server uses): `review.list` then
`review.evidence`. The label is the STATE of the resolved agency key (`US-<ST>-...`); records without a resolved agency are
skipped. Output: <out>/<StateName>/<idempotency key>.jpg + <out>/manifest.json (source "local Review", no licence claim).

Privacy (AGENTS.md rules 1 and 3): these are the operator's own intact fleet-target crops. They stay on this Mac, go into a
gitignored directory, are used only for LOCAL training/evaluation and are never uploaded, committed or sent to a hosted model.
The files are vehicle crops (<= 40 KB), not plate crops: run scripts/plate_crops.swift over the output before training.
"""
import json, os, sys, urllib.request, base64

STATES = {"AL":"Alabama","AK":"Alaska","AZ":"Arizona","AR":"Arkansas","CA":"California","CO":"Colorado","CT":"Connecticut","DE":"Delaware",
 "FL":"Florida","GA":"Georgia","HI":"Hawaii","ID":"Idaho","IL":"Illinois","IN":"Indiana","IA":"Iowa","KS":"Kansas","KY":"Kentucky",
 "LA":"Louisiana","ME":"Maine","MD":"Maryland","MA":"Massachusetts","MI":"Michigan","MN":"Minnesota","MS":"Mississippi","MO":"Missouri",
 "MT":"Montana","NE":"Nebraska","NV":"Nevada","NH":"New Hampshire","NJ":"New Jersey","NM":"New Mexico","NY":"New York","NC":"North Carolina",
 "ND":"North Dakota","OH":"Ohio","OK":"Oklahoma","OR":"Oregon","PA":"Pennsylvania","RI":"Rhode Island","SC":"South Carolina","SD":"South Dakota",
 "TN":"Tennessee","TX":"Texas","UT":"Utah","VT":"Vermont","VA":"Virginia","WA":"Washington","WV":"West Virginia","WI":"Wisconsin","WY":"Wyoming","DC":"Washington, D.C."}

def bridge():
    path = os.path.expanduser("~/Library/Application Support/PlateWatchHub/AgentBridge/connection.json")
    d = json.load(open(path))
    def call(cmd, **args):
        req = urllib.request.Request(f"http://127.0.0.1:{d['port']}/v1/command", method="POST",
            data=json.dumps({"command": cmd, "arguments": args}).encode(), headers={"Authorization": "Bearer " + d["token"]})
        return json.load(urllib.request.urlopen(req, timeout=30))
    return call

def state_of(agency):
    parts = (agency or "").split("-")
    return STATES.get(parts[1]) if len(parts) >= 3 and parts[0] == "US" and parts[1] in STATES else None

out = sys.argv[1]; dry = "--dry-run" in sys.argv
call = bridge(); offset = 0; kept = skipped = 0; manifest = []
while True:
    page = call("review.list", limit=100, offset=offset)
    for item in page["items"]:
        state = state_of(item.get("agency"))
        if not state or not item.get("has_evidence"): skipped += 1; continue
        kept += 1
        if dry: continue
        ev = call("review.evidence", id=item["id"])
        os.makedirs(os.path.join(out, state), exist_ok=True)
        name = f"{item['id']}.jpg"
        open(os.path.join(out, state, name), "wb").write(base64.b64decode(ev["jpeg_base64"]))
        manifest.append({"file": f"{state}/{name}", "class": state, "title": item["id"], "sourcePage": "local Review queue",
                         "license": "operator-owned local evidence", "author": "local capture"})
    offset += len(page["items"])
    if offset >= page["total"] or not page["items"]: break
if not dry and manifest:
    json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1)
print(f"{'would export' if dry else 'exported'} {kept} labelled crops, skipped {skipped} (no resolved agency state or no evidence)")
