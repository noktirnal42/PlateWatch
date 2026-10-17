# PlateWatch Android client

This first Android target is a read-only public-fleet consumer of the shared
REST DTO contract. It connects to `GET /v1/sightings`, displays published
agency/unit sightings, and never requests plates, raw frames, review crops, or
exact coordinates. The endpoint field defaults to the Android emulator's
`10.0.2.2:8083` bridge for the local reference server; production deployments
must use HTTPS.

Build from this directory with the locally installed Android SDK and Gradle:

```sh
gradle --offline assembleDebug
```

ONNX capture inference is intentionally a separate milestone. The Android
client must not claim local detection until an ONNX model, license, input
normalization, and measured benchmark are added to the model registry and
verified on a physical device.
