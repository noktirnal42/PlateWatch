# NVIDIA NIM options for PlateWatch — October 16, 2026

Research only. No NVIDIA credential was accessed, no inference request was made and
no remote provider is enabled. Finish the current local repair/runtime checkpoint
first. The owner requested an implementation choice before adding NVIDIA integrations.
The recommendations below are design inferences from the linked official documentation,
not measured PlateWatch accuracy or service availability for this account.

## Useful roles

| Priority | Candidate | Where and how it would fit | Acceptance gate |
|---|---|---|---|
| 1 | Nemotron-3-Nano-30B-A3B LLM agent | Optional `AgentModel` adapter in HubAgents. Reuse the current strict commands, results panel, Stop, deadline and journal. Start with public feed metadata and public cited records. | Exact deployed model supports the selected JSON/tool schema; fixed task/injection fixtures, live completion, cancellation, timeout and rate-limit tests. |
| 2 | Llama Nemotron embedding + reranking | Semantic Records & FOIA search over public documents; retrieve passages, rerank them, show original citation/page/snippet. A local index can retain vectors plus source IDs. | A labeled retrieval set beats keyword baseline; unchanged citations, reproducible chunk/model versions, incremental deletion and no name-only identity confirmation. |
| 3 | Nemotron Parse and OCR v2 | Extract public scanned FOIA pages, fleet inventories, tables and rosters into pending candidates. Preserve page number, bounding box, source text and `SourceCitation`; show extraction next to the original. | Evaluate exact fields/table alignment on representative documents. Human review precedes acceptance; OCR text is evidence to check, not a verified fact. |
| 4 | NV-Grounding-DINO | Offline comparison against the vehicle detector on a licensed labeled camera holdout. Test car/SUV/truck/bus boxes and appearance hypotheses, then compare recall/false positives/latency. | An annotated holdout demonstrates improvement. A lightbar/pushbar hypothesis never automatically establishes fleet status. No production-model replacement from a demo screenshot. |
| Later edge project | TAO / DeepStream TrafficCamNet, LPDNet, LPRNet | NVIDIA GPU edge worker for vehicle → plate detection → recognition, evaluated against the shared protocol. These are related NVIDIA models/tools, **not a claim that all have hosted NIM endpoints**. | Hardware/deployment proof, licenses, fleet gate, plate exact-match/CER, source policy, bounded capture and protocol compatibility. |

The [Nemotron Nano model reference](https://docs.api.nvidia.com/nim/reference/nvidia-nemotron-3-nano-30b-a3b)
describes agent/RAG uses and structured-output/tool-use training. That does not prove a
specific endpoint's tool parser or PlateWatch task quality. NVIDIA's
[function-calling guide](https://docs.nvidia.com/nim/large-language-models/1.11.0/function-calling.html)
is versioned and model-dependent; pin and test the deployed model rather than assuming
all OpenAI-compatible endpoints support identical features. Model/service terms apply;
trial access is not a promise of free production hosting.

The [retrieval API catalogue](https://docs.api.nvidia.com/nim/reference/retrieval-apis)
lists embedding and reranking models, including 1B-v2 families. A
[reranker](https://docs.api.nvidia.com/nim/reference/nvidia-llama-nemotron-rerank-1b-v2)
scores query/passage relevance. Embeddings and reranking improve retrieval; neither
supplies missing provenance or proves that a person and record refer to the same identity.
Exact dimensions/context limits must follow the selected model version.

[Nemotron Parse](https://build.nvidia.com/nvidia/nemotron-parse/modelcard) targets
document structure/text extraction. [OCR v2](https://build.nvidia.com/nvidia/nemotron-ocr-v2/modelcard)
covers document and scene text with detection/recognition outputs. Neither has been
validated here as a replacement ALPR model. Prioritize public document extraction before
considering camera/evidence OCR.

[NV-Grounding-DINO](https://docs.api.nvidia.com/nim/reference/nvidia-nv-grounding-dino)
is an open-vocabulary detector; the [inference endpoint](https://docs.api.nvidia.com/nim/reference/nvidia-nv-grounding-dino-infer)
accepts an image or uploaded asset reference. Hosted inference therefore sends pixels
away from the Mac. The [TAO/DeepStream integration guide](https://docs.nvidia.com/tao/tao-toolkit/latest/text/ds_tao/deepstream_tao_integration.html)
and [NVIDIA LPR example](https://github.com/nvidia-ai-iot/deepstream_tao_apps/blob/master/apps/tao_others/deepstream_lpr_app/README.md)
describe the separate vehicle/plate recognition pipeline.

## Deployment and payload choices

**Hosted NVIDIA API:** Swift calls the selected HTTPS endpoint; API key stays in Keychain.
Use explicit provider/model selection, request budgets, bounded responses, cancellation,
429 backoff and clear account/network errors. No hidden fallback from local to hosted.
Begin with public text and public feed metadata only. Strip credentials, queued images,
private plates/precise locations and private records before any remote request. Separate
provider output from verified app results. Do not send full local MCP responses by default.

**Self-hosted NIM:** a separately operated compatible NVIDIA GPU/Linux/container host
provides the inference service. The [NIM deployment playbook](https://build.nvidia.com/playbooks/nim-llm/overview)
illustrates this deployment class. Hardware, drivers, memory, licensing and capacity are
model-specific. Apple-silicon MLX is the local Mac provider; NVIDIA GPU containers are a
separate server/edge deployment. A private host still needs an explicit data-boundary and
authentication design; it is not permission to upload all evidence.

The owner's intact-local-Review exception does not authorize remote image transmission.
Any camera/evidence vision integration needs a separately selected, reviewable payload
policy. No raw-frame telemetry, automated acceptance/publication, biometric matching or
personal tracking is proposed. Keep model licenses and revisions in registry metadata;
never commit weights or credentials. Public documents remain untrusted input and can
contain misleading instructions; the tool allowlist and human review remain enforced.

## Suggested sequence and owner decision

1. Finish local MLX/Apple runtime QA and current feed/evidence repairs.
2. If selected, add the optional text-only NIM agent behind the existing typed executor.
3. Add cited public-document retrieval (embedding + reranker), followed by document extraction.
4. Run a separate vision/edge benchmark before choosing any recognition deployment.

Choose any subset: text agent, cited search, public-document OCR/extraction, vehicle
benchmark, or NVIDIA edge pipeline. Also choose hosted API versus an available private
NVIDIA GPU host before implementation. Account quotas, credentials, costs, current endpoint
access and model-specific terms have not been checked. Research does not imply deployment.
