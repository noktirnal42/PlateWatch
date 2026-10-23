#!/usr/bin/env python3
"""Submit operator-confirmed fleet observations to the PlateWatch REST mirror.

This is deliberately a reference edge client, not an image-processing agent.
It accepts JSON produced by a local, already-gated detector and sends only the
structured observation. Raw frames, review crops, exact coordinates, and
private-citizen observations are rejected before any network request.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import hashlib
import json
import struct
import sys
from typing import Any, Mapping
from urllib import error as urlerror
from urllib import request as urlrequest


class PolicyError(ValueError):
    """The observation cannot cross the edge-agent privacy boundary."""


def _utc_datetime(value: str) -> _datetime.datetime:
    if not isinstance(value, str) or not value:
        raise PolicyError("capturedAt must be an ISO-8601 string")
    try:
        parsed = _datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise PolicyError("capturedAt must be an ISO-8601 string") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_datetime.timezone.utc)
    return parsed.astimezone(_datetime.timezone.utc)


def _required_string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PolicyError(f"{name} must be a non-empty string")
    return value.strip()


def _has_fleet_markings(markings: Any) -> bool:
    if not isinstance(markings, Mapping):
        return False
    return bool(markings.get("agencyText") or markings.get("unitNumber"))


def _has_government_plate_design(plate: Any) -> bool:
    if not isinstance(plate, Mapping):
        return False
    design = str(plate.get("plateDesign") or "").lower()
    return "gov" in design or "exempt" in design


def prepare_observation(observation: Mapping[str, Any]) -> dict[str, Any]:
    """Validate and minimize a local observation for REST submission.

    The server remains the final moderation boundary. The client-side checks
    intentionally fail closed so a misconfigured edge process cannot upload
    raw media, exact coordinates, or an unconfirmed observation.
    """

    if not isinstance(observation, Mapping):
        raise PolicyError("observation must be a JSON object")
    if observation.get("cropJPEGBase64"):
        raise PolicyError("review crops and raw image bytes never leave the Hub")
    if observation.get("exactLatitude") is not None or observation.get("exactLongitude") is not None:
        raise PolicyError("exact coordinates are not accepted by the edge client")
    if observation.get("userConfirmed") is not True:
        raise PolicyError("edge submissions require explicit operator confirmation")

    confidence = observation.get("fleetConfidence")
    if not isinstance(confidence, (int, float)) or confidence < 0.8:
        raise PolicyError("fleetConfidence must be at least 0.80")

    captured_at = _required_string(observation.get("capturedAt"), "capturedAt")
    _utc_datetime(captured_at)  # validate before calculating the content key
    geohash = _required_string(observation.get("geohash6"), "geohash6")
    device_hash = _required_string(observation.get("deviceIDHash"), "deviceIDHash")
    vehicle = observation.get("vehicle")
    if not isinstance(vehicle, Mapping):
        raise PolicyError("vehicle must be an object")
    vehicle_class = _required_string(vehicle.get("vehicleClass"), "vehicle.vehicleClass")
    class_confidence = vehicle.get("classConfidence")
    if not isinstance(class_confidence, (int, float)):
        raise PolicyError("vehicle.classConfidence must be numeric")
    markings = observation.get("markings")
    plate = observation.get("plate")
    if not (_has_fleet_markings(markings) or _has_government_plate_design(plate)):
        raise PolicyError("fleet markings or a government plate design are required")

    # Copy only fields in the stable wire DTO. Exact location and crop bytes
    # are deliberately omitted even when present in a caller's object.
    result: dict[str, Any] = {
        "capturedAt": captured_at,
        "geohash6": geohash,
        "deviceIDHash": device_hash,
        "fleetConfidence": float(confidence),
        "vehicle": {
            "vehicleClass": vehicle_class,
            "classConfidence": float(class_confidence),
        },
        "userConfirmed": True,
    }
    attributes = vehicle.get("attributes")
    if isinstance(attributes, Mapping):
        result["vehicle"]["attributes"] = dict(attributes)
    if isinstance(markings, Mapping):
        result["markings"] = {
            key: markings[key]
            for key in ("agencyText", "unitNumber", "serviceClassText")
            if markings.get(key) is not None
        }
    if isinstance(plate, Mapping):
        result["plate"] = {
            key: plate[key]
            for key in ("text", "issuingRegion", "country", "plateDesign", "confidence")
            if plate.get(key) is not None
        }
    for key in ("headingDegrees", "roadClass", "cropHashSHA256"):
        if observation.get(key) is not None:
            result[key] = observation[key]
    return result


def idempotency_key(observation: Mapping[str, Any]) -> str:
    """Match ``OutboxDrainer.idempotencyKey(for:)`` in PlateSync."""

    prepared = prepare_observation(observation)
    timestamp = _utc_datetime(prepared["capturedAt"]).timestamp()
    data = bytearray(struct.pack(">d", timestamp))
    vehicle = prepared["vehicle"]
    for component in (
        prepared["geohash6"],
        (prepared.get("plate") or {}).get("text", ""),
        vehicle["vehicleClass"],
        prepared.get("cropHashSHA256", ""),
    ):
        data.extend(str(component).encode("utf-8"))
        data.append(0)
    return hashlib.sha256(data).hexdigest()[:32]


class EdgeAgent:
    """Small standard-library HTTP client for the reference REST mirror."""

    def __init__(self, endpoint: str, timeout: float = 15.0):
        self.endpoint = endpoint.rstrip("/") + "/v1/sightings"
        self.timeout = timeout

    def submit(self, observation: Mapping[str, Any]) -> dict[str, Any]:
        prepared = prepare_observation(observation)
        key = idempotency_key(prepared)
        payload = json.dumps(prepared, separators=(",", ":")).encode("utf-8")
        request = urlrequest.Request(
            self.endpoint,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Idempotency-Key": key,
                "User-Agent": "PlateWatchEdgeAgent/1",
            },
            method="POST",
        )
        try:
            with urlrequest.urlopen(request, timeout=self.timeout) as response:
                body = response.read()
        except urlerror.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"PlateWatch server returned HTTP {exc.code}: {detail}") from exc
        except urlerror.URLError as exc:
            raise RuntimeError(f"PlateWatch server unavailable: {exc.reason}") from exc
        try:
            return json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RuntimeError("PlateWatch server returned invalid JSON") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True, help="REST mirror base URL, e.g. http://127.0.0.1:8083")
    parser.add_argument("input", help="JSON observation file, or - for stdin")
    args = parser.parse_args(argv)
    source = sys.stdin if args.input == "-" else open(args.input, encoding="utf-8")
    try:
        observation = json.load(source)
        receipt = EdgeAgent(args.endpoint).submit(observation)
    except (OSError, json.JSONDecodeError, PolicyError, RuntimeError) as exc:
        print(f"edge-agent: {exc}", file=sys.stderr)
        return 2
    finally:
        if source is not sys.stdin:
            source.close()
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
