# Selected HLS Live: bounded body-type estimates

This is WS2 Hub work. It adds display-only body-type estimates to the selected
HLS camera when the optional local type model is available. It does not change
fleet scoring, plate policy, records, evidence crops or upload boundaries.

## Scheduling and lifecycle

- At most four type-classification requests per completed full-analysis pass.
- Each spatial track waits at least two seconds between attempts, including
  uncertain results. Due work is ordered by age, so later vehicles in a crowded
  frame are not permanently excluded by the first four detections.
- Positive display types expire after three seconds. Spatial tracks expire
  after five seconds without observation; metadata is bounded to 64 tracks.
- Crops must be at least 48 pixels on both visible sides. The scheduler may
  refine a generic `car` or an untyped vehicle. Existing specific types remain.
- Association uses one-to-one IoU matching, with stricter overlap when the
  detector body seed changes. It is a short-lived display association, not a
  claim of vehicle identity or a cross-camera re-identification service.
- Source changes, reopening, Stop and Retry invalidate the Live session token.
  Old inference results cannot update a new session. Retry also resets overlay
  votes and timing readouts. Cancelled pending inference cannot populate cache.

The original full frame passes the recording gate **before** body-type
inference. A separate value copy receives display attributes. The estimate
cannot become fleet evidence or alter a submitted record. Changed body labels
are marked `(estimate)`; detector confidence is not presented as confidence in
that estimate. Label smoothing resets when entering/leaving estimated output,
so it cannot preserve an expired estimate or attach an old estimate to a new
score. Fast detector-only frames retain the last full display verdict as before.

## Released model compatibility: finding and fix

The released `vehicle-type-classifier` is a ViT **tensor-input** CoreML model:
`pixel_values`, float32 NCHW `[1,3,224,224]`. The registry's historical image
input description and the Vision-only consumer were inconsistent with the
artifact. Native Vision testing returned:

> The model does not have a valid input feature of type image

Hub now supports this legacy tensor contract locally. Image-input models retain
the shared Vision path. The tensor adapter resizes the crop to 224×224 RGB and
uses scale `1/255`, channel means `[0.5,0.5,0.5]` and standard deviations
`[0.5,0.5,0.5]`, as recorded by the upstream
[processor configuration](https://huggingface.co/dima806/vehicle_10_types_image_detection/blob/7619f8df8750db3a01bdf01e66d147af21a560d5/preprocessor_config.json).
The local artifact's final graph operations are `linear → cast → classify`,
without softmax. Its dictionary values are logits; stable softmax is applied
before the existing 0.45 acceptance threshold. Unknown classes and weak scores
abstain. No threshold was lowered to make the smoke test pass.

The released appearance classes `taxi`/`racing car`, `jeep`, and `fire engine`
map to coarse `car`, `suv`, and `truck` display labels respectively. None
establishes a fleet class. Other supported coarse labels use the shared mapper.
Model weights and their existing Apache-2.0 registry licence are unchanged.
This adapter is Hub-only: shared/iOS tensor-model compatibility remains a WS3
follow-up, along with correcting the registry input description.

## Evidence and limits

- Hub hostless suite: 80 tests, five opt-in skips, zero failures.
- FeedIngest: 171 tests, four opt-in skips, zero failures.
- Tests cover finite crowded-scene coverage, overdue-work priority, cooldown,
  cache expiry, metadata bounds, source-session isolation, cancellation,
  original fleet-evidence preservation, estimate labels and label-vote expiry.
- Tensor tests cover RGB channel order, NCHW shape, scaling/normalization,
  top-left orientation, stable-softmax thresholds and unsupported-label refusal.
- The separate native opt-in test passed 1/1 using the cached released model and licensed
  corpus entry 0 (the public Mint police-car photo; attribution is retained in
  `eval/manifest.json`). The old Vision route rejected the tensor model.
  The tensor route executes its ten output scores. On this fixture, those
  scores are weak and the adapter abstains. This is runtime/abstention evidence,
  not evidence of accepted classification accuracy. Positive cache behavior is
  tested deterministically with an injected classifier.
- A 100-tick synthetic scheduling test covers all ten stationary tracks and
  enforces the four-request cap and cooldown. It is not a saved-video tracking
  benchmark or a sustained live CPU/FPS measurement.
- Run only one camera-consuming app at a time. TrafficView source can be read
  while PlateWatch runs; do not launch both against the providers for comparison.

Native smoke (local paths supplied by the operator; no downloads):

```sh
PLATEWATCH_VEHICLE_TYPE_MODEL="$TYPE_MODEL" \
PLATEWATCH_TYPE_IMAGE="$LICENSED_PHOTO" \
xcrun xctest \
  -XCTest 'PlateWatchHubTests.LiveTypeTests/testInstalledTypeModelInferenceAndCooldown' \
  "$HUB_TEST_BUNDLE"
```

Xcode's test launcher did not inherit the optional path variables in this
session; direct hostless xctest was used so the native test actually runs
rather than silently skipping. The selected-camera real-video benchmark,
body-type quality evaluation and full physical/deployment acceptance remain
open in the project audit.

## Remote CI follow-up captured during this work

For development commit `bf7f6be`, run `40027280489` passed every package,
server, model-pipeline, MCP and eval-harness job. The iOS UI job failed
`ReviewFlowTests.testWatchlistValidationAddMuteAndDelete` at line 52:
`Neither element nor any descendant has keyboard focus` while replacing
`demo1` in `fleet-plate-input`. That exact WS1 diagnostic is separate from
these Hub tests. The apps job was still running when inspected; no complete
remote green claim is made for this checkpoint.
