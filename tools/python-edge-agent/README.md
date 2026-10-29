# PlateWatch Python edge agent

This is a small reference client for a Raspberry Pi, OAK device, or another
local processor that has already produced a **fleet-confirmed** observation.
It implements the REST mirror's `POST /v1/sightings` contract using only the
Python standard library.

The client fails closed unless the observation has explicit operator
confirmation, `fleetConfidence >= 0.80`, and agency/unit markings or a
government/exempt plate design. It never accepts or sends `cropJPEGBase64`,
raw frames, exact coordinates, credentials, or unconfirmed observations. The
server remains the final moderation boundary.

```sh
python3 tools/python-edge-agent/edge_agent.py \
  --endpoint http://127.0.0.1:8083 observation.json
```

The request includes a content-addressed `Idempotency-Key` compatible with
`PlateSync.OutboxDrainer`, so retries after an offline interval are safe. The
agent is intentionally not a detector or model runner; use the local Hub or a
separately reviewed, on-device pipeline to create the input observation.

Run the fixture tests without third-party dependencies:

```sh
python3 -m unittest discover -s tools/python-edge-agent -p 'test_*.py'
```
