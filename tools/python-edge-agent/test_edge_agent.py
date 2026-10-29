import datetime
import http.server
import json
import threading
import unittest

from edge_agent import EdgeAgent, PolicyError, idempotency_key, prepare_observation


def observation():
    return {
        "capturedAt": "2026-10-17T20:00:00.000Z",
        "geohash6": "9q8yyk",
        "deviceIDHash": "device-public-hash",
        "fleetConfidence": 0.91,
        "vehicle": {"vehicleClass": "police_suv", "classConfidence": 0.88},
        "markings": {"agencyText": "Example Police", "unitNumber": "12"},
        "plate": {"text": "ABC123", "country": "US", "plateDesign": "government", "confidence": 0.9},
        "userConfirmed": True,
    }


class RecordingHandler(http.server.BaseHTTPRequestHandler):
    received = None
    headers = None

    def do_POST(self):  # noqa: N802
        self.__class__.headers = dict(self.headers)
        self.__class__.received = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        body = json.dumps({"moderationState": "fleetConfirmed", "idempotencyKey": self.headers["Idempotency-Key"]}).encode()
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class EdgeAgentTests(unittest.TestCase):
    def test_preparation_rejects_exact_coordinates_and_omits_media(self):
        with self.assertRaises(PolicyError):
            prepare_observation(observation() | {"exactLatitude": 40.0, "exactLongitude": -75.0})
        prepared = prepare_observation(observation() | {"cropHashSHA256": "abc"})
        self.assertNotIn("cropJPEGBase64", prepared)
        self.assertEqual(prepared["cropHashSHA256"], "abc")

    def test_rejects_unconfirmed_or_media(self):
        with self.assertRaises(PolicyError):
            prepare_observation(observation() | {"userConfirmed": False})
        with self.assertRaises(PolicyError):
            prepare_observation(observation() | {"cropJPEGBase64": "aGVsbG8="})

    def test_idempotency_is_stable(self):
        self.assertEqual(idempotency_key(observation()), idempotency_key(observation()))
        self.assertNotEqual(idempotency_key(observation()), idempotency_key(observation() | {"geohash6": "9q8yyj"}))

    def test_submit_uses_wire_header_and_no_media(self):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RecordingHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            receipt = EdgeAgent(f"http://127.0.0.1:{server.server_port}").submit(observation())
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        self.assertEqual(receipt["moderationState"], "fleetConfirmed")
        self.assertEqual(RecordingHandler.headers["Idempotency-Key"], idempotency_key(observation()))
        self.assertNotIn("cropJPEGBase64", RecordingHandler.received)


if __name__ == "__main__":
    unittest.main()
