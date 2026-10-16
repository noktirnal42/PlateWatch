# Local MLX and agent reuse audit — 2026-10-15

The owner authorized adapting the other local development projects for PlateWatch.
Source projects were inspected read-only. Paths below are relative to their sibling
project roots; none is a build dependency or a machine-specific runtime location.

| Project | Inspected code | PlateWatch use / change needed |
|---|---|---|
| Axiom RE (`ghidraclone`) | `Sources/AxiomCore/Intelligence/ModelStore.swift`, `docs/UNIVERSAL_MODEL_STORE.md` | Reuse cache resolution, pinned snapshot discovery and blob hashing. Make PlateWatch's resolver read-only: refuse missing drives, no replacement store, downloads or shared-model deletion. |
| System5 | `macOS/Sources/System5Native/MLXService.swift`, `macOS/Sources/System5Engine/RunLoop.swift`, `Providers.swift` | Adapt one resident model and serial generation; narrow tools to PlateWatch's app-owned commands. Do not inherit coding tools, shell/filesystem authority, provider credentials or process-control tools. |
| AILab | `Packages/ModelLabCore/Sources/ModelLabCore/Providers/MLXInferenceProvider.swift`, `FoundationModelsInferenceProvider.swift` | Reuse availability reporting and cancellation/streaming patterns. Avoid its automatic first-use model download. Its newer MLX dependencies require a compatibility decision before changing Hub deployment support. |

System5's resolved native stack is mlx-swift-examples 2.29.1 / mlx-swift 0.29.1
(macOS 14 support). AILab resolves mlx-swift-lm 3.31.4 / mlx-swift 0.31.6 and
has a documented graph-compilation-cache workaround. These are inspected local
versions, not claims of latest upstream releases or PlateWatch runtime readiness.

The shared Hugging Face store already contains small Qwen, SmolLM and Llama
snapshots. Their presence is inventory only: select a pinned revision, verify
its model license and file integrity, and prove local inference before reporting
an MLX provider ready. No model weights were copied, downloaded or removed by
this audit. No blanket license file was found at the inspected project roots;
record adaptation provenance and preserve applicable upstream dependency licenses.

## Integration acceptance

1. Provider capability is separate from task execution. Missing OS support,
   disabled Apple Intelligence, missing volume/model and inference failures stay visible.
2. An in-app task can use only typed, validated app commands. Terms confirmation,
   record acceptance and publication keep their human review boundary.
3. Each run has a bounded step/time/output budget, cancellation and an activity
   journal containing command names/outcomes without images, private plates or secrets.
4. Source excerpts and tool results remain untrusted input. Model-generated
   tool names/arguments cannot become arbitrary selectors, paths or shell commands.
5. On-device Foundation Models and local MLX are first. PCC remains gated by a
   signed, authorized bundle and an explicit remote-data boundary.
6. Tests cover unsupported commands, prompt injection, missing drives, cancellation,
   and budget exhaustion; final inference proof comes from the packaged Hub.
