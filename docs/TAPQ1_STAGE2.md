# TapQ-1 Stage 2: Track A status and the Track B design

Stage 2 is the roadmap's frozen sub-4B LLM layer. It has two tracks that share one
output contract and nothing else.

**Track A — structured text.** A `ReasonerContext` is rendered as prompt text and a
frozen on-device LLM answers with a guided-generation schema constrained to
`tapq1-decision-v1`. Escalation-only: the answer can raise the confirmation bar and can
do nothing else. This is implemented, with Apple's Foundation Models framework as the
only backend.

**Track B — continuous projection.** The stage-1 encoder's embeddings are mapped by a
trained projection into the frozen LLM's embedding space and fed alongside the text
(the SensorLLM recipe, arXiv:2410.10624; LLaSA, arXiv:2406.14498). No LLM fine-tuning.
This is not implemented and cannot start: it needs paired motion-and-decision data that
no part of the system currently records.

This document states where Track A stands, designs the near-term local backend that
unblocks measuring it, specifies Track B in enough detail to build once data exists,
lists the `ml/` debts that would otherwise be discovered mid-capture-study, and puts
the whole thing in dependency order.

Two invariants hold across everything below, and every proposal here is written to
preserve them:

* **Escalation-only.** `ContextReasoning.assess(_:)` returning `nil` means "cannot
  answer" and leaves the deterministic requirement unchanged
  (`Sources/TapQContextBaseline/ContextReasoning.swift:25`). No stage-2 backend — Apple's,
  a local open-weights model, or a projection-fused one — gains the power to approve,
  deny, resolve, or weaken a requirement.
* **The stage-1 scorer contract is frozen.** `tapq1-features-v1`, the eight-class output
  vector, and `CoreMLMotionScorer`'s one-output validation
  (`Sources/TapQAppleAdapters/CoreMLMotionScorer.swift:98-108`) are not touched by Track B.
  Everything Track B needs arrives as new, separately versioned artifacts.

---

## 1. Where stage 2 stands

### What exists

The Track A surface is complete as a mechanism.

| Piece | File | What it fixes |
|---|---|---|
| Backend protocol | `Sources/TapQContextBaseline/ContextReasoning.swift:25-27` | One method; `nil` is "cannot answer" and is the safe result for every failure mode |
| Modes | `ContextReasoning.swift:30-43` | `off` / `shadow` / `primary` — how much an answer counts |
| Providers | `Sources/TapQContextBaseline/ReasonerProvider.swift:14-22` | `off` / `apple` — what answers |
| Policy knobs | `ContextReasoning.swift:57-131` | Timeout (2.0 s default), `minConfidence`, tier-to-confirmation mapping; `routine` is pinned to `.standard` so no knob weakens anything |
| Closed output schema | `Sources/TapQContextBaseline/ReasonerContract.swift` | `RiskTier` (3), `RationaleCode` (6, in precedence order), bounded note, clamped confidence, versioned as `tapq1-decision-v1` (`ReasonerDecisionContract`) |
| Request view | `ReasonerContext` in `ReasonerContract.swift`, `ReasonerRequestContext.swift` | Flat and portable, decoupled from `ApprovalRequest`, documented as additive so later packets can add fields |
| Prompt contract | `Sources/TapQContextBaseline/ReasonerPrompt.swift` | Stable instructions prefix plus an untrusted fenced context; three caps (4000/1000/1000 chars); text digest pinned by tests |
| Apple backend | `Sources/TapQContextBaseline/FoundationModelReasoner.swift` | `@Generable` schema whose `.anyOf` guides derive from the contract, greedy sampling, fresh session per request, `prewarm()` |
| Hard deadline | `ReasonerDeadline.swift` | A wall-clock bound that holds whether or not the backend cooperates — a task group does not bound anything, and the file says why (`:12-28`) |
| Caller half | `ReasonerEscalation.swift` | Outer bound = timeout + 0.25 s (`:70`), the confidence filter, the escalation-only merge, voice degradation |
| Evaluation | `bench/README.md`, `bench/reasoner-scenarios-v1.ndjson`, `docs/CLI.md` §Reasoner bench | Labeled cases (170 at time of writing; the corpus is append-only and grows), grading rules written out, `tapq bench reasoner` implementing them as written |
| Shadow review | `<broker-dir>/reasoner-log.jsonl` (`docs/CLI.md:81-98`) | One line per reasoner-observed approval: tier, code, confidence or abstention, latency, implied confirmation, what the user then did |

### What is measured

Every *portable* safety property, on both CI platforms
(`.github/workflows/ci.yml`): that the deadline fires against a deliberately
uncooperative backend, that each abstention shape maps to the deterministic
requirement unchanged, that the confidence filter runs on the caller side, that the
merge cannot produce something weaker than the deterministic requirement, that voice
degradation never lowers the bar, that the prompt text has not silently changed, that
the vocabulary in the prompt matches the contract's `allCases`, and that the corpus
parses and grades to `bench/README.md`'s rules.

This is the whole reason `ReasonerEscalation` and `ReasonerDeadline` live outside the
`canImport(FoundationModels)` guard: the machine that gates merges does not compile the
on-device adapter, so anything that decides whether a *failing* reasoner is safe had to
be somewhere the test suite reaches.

### What cannot be measured, and why

**No model has ever answered a scenario in this repository.**

On the maintainer's Mac, `SystemLanguageModel.default.availability` reports
`unavailable(deviceNotEligible)`. `FoundationModelReasoner.isSupported` is therefore
`false` (`FoundationModelReasoner.swift:51-54`), `assess(_:)` records
`reason: model_unavailable` and returns `nil` before doing any work, and
`tapq bench reasoner --reasoner apple` fails rather than printing a report — by design,
because "a run of abstentions would print as a report and read as a result"
(`docs/CLI.md:274-276`).

The consequence is worth stating plainly: **not one number in this repository about
stage-2 quality is a measurement.** The tier definitions, the grading rules, the
headline metrics, the confusion matrix, the latency percentiles — all of them are
definitions waiting for a first run. Device eligibility is not a tuning problem that a
better prompt fixes; it is a hardware gate, and no amount of Track A work moves it.

**No motion data exists.** The capture study (roadmap Phase 0, step 2) has not happened.
`ml/tapq1` has never seen a real window; `smoke.py` fabricates windows with hand-drawn
per-class signatures and says so in its own docstring (`ml/tapq1/smoke.py:8-9`). There
is no trained checkpoint, no exported `.mlpackage`, and therefore no embeddings.

**No paired data exists.** Even granting both of the above, Track B needs motion windows
and approval decisions joined on a common clock. The runtime writes motion (`tapq
capture`) and writes decisions (`reasoner-log.jsonl`) and never writes the two together
with a usable join key. Section 3(b) specifies what would have to change.

So Track A is blocked on hardware and Track B is blocked on data. Those are different
blockers with different remedies, which is what sets the order in section 5: a local
open-weights backend removes the hardware block and buys the first real numbers, while
data-free `ml/` work removes debt that would otherwise surface in the middle of the
capture study.

---

## 2. Near-term: a local open-weights backend (`--reasoner local`)

### What it is for

One thing: producing live stage-2 numbers on hardware Apple Intelligence declines to
run on. It is an instrument, not a product direction. If the Apple backend later becomes
measurable, `local` stays useful as a second reading — a metric that only one model has
ever produced is not obviously a property of the corpus.

`ReasonerProvider`'s own documentation already anticipates the shape
(`ReasonerProvider.swift:11-13`): a later local open-weights backend adds its own case
"together with whatever it needs to be located, the way `--encoder-model` carries a model
path".

### Design

A `ContextReasoning` conformance running a Qwen3-1.7B-class instruct model locally, with
generation constrained to the `tapq1-decision-v1` field shape. It reuses everything
portable that already exists:

* `ReasonerPromptContract.instructions` verbatim — a different prompt is a different
  measurement (the `instructions` doc comment in `ReasonerPrompt.swift` says so, and a
  test pins its digest), and the point of this backend is to measure the same thing the
  Apple backend would.
* `ReasonerPromptContract.renderContext(_:)` verbatim, including the untrusted fence.
* `ReasonerPromptContract.decision(tier:code:note:confidence:config:)` for mapping the
  answer, so an out-of-vocabulary answer abstains here exactly as it does there.
* `ReasonerEscalation.assess(_:using:under:)` for the outer bound and the confidence
  filter. The local backend implements no policy.

Nothing about the safety posture changes, and one property becomes load-bearing that
was previously incidental: **the weights are user-supplied and therefore arbitrary.**
That is acceptable only because `ContextReasoning`'s single power is raising the bar. A
hostile local model can make the user confirm more; it cannot make TapQ approve anything.
This is the argument that permits `--reasoner-model PATH` at all, and it should be stated
in the user-facing docs the same way.

### Integration route: MLX Swift vs llama.cpp

| Criterion | MLX Swift (`ml-explore/mlx-swift-lm`) | llama.cpp (GGUF) |
|---|---|---|
| **Constrained decoding** | `MLXGuidedGeneration` provides grammar-constrained generation from a JSON Schema or EBNF, first-party. Newer and less battle-tested. A third-party `GrammarMaskedLogitProcessor` (mlx-swift-structured) does the same by logit masking and works on macOS 26 today. | GBNF has years of production use. `common/json-schema-to-grammar.cpp` converts a JSON Schema Draft-7 subset — enums, `required`, `additionalProperties`, numeric bounds — straight to GBNF. The mature option, and it is not close. |
| **Schema fit to *this* contract** | `MLXFoundationModels` bridges an MLX model into `FoundationModels.LanguageModel` behind `LanguageModelSession`. That is the **same API `FoundationModelReasoner` already uses**, so the existing `@Generable struct Assessment` — including `.anyOf(ReasonerPromptContract.tierValues)` — is reusable verbatim. The local backend becomes a second instance of one code path. | Needs a GBNF grammar mirroring `RiskTier.allCases` and `RationaleCode.allCases` by hand or by a generator. That is a second copy of the vocabulary, in a second language, that can drift from the Swift contract — precisely the failure `ReasonerPromptContract` derives its vocabulary from `allCases` to prevent. |
| **Cold start** | ~1.0–1.2 GB of 4-bit weights into unified memory plus Metal warmup: seconds, not milliseconds. Mitigated by the existing `prewarm()` seam. | Comparable; `mmap` of a GGUF is fast and first-run Metal shader compilation is the cost. A slight edge to llama.cpp. |
| **Per-call latency at this prompt size** | Published Apple Silicon comparisons put MLX 20–87% ahead of llama.cpp on generation for models under 14B, where this backend lives. Grammar masking costs a reported 15–25% on top. | Slower on small-model generation on Apple Silicon by those same comparisons; prefill is competitive. |
| **Memory at 4-bit** | ~1.0–1.2 GB weights; KV cache for a ≤4k context is small next to that. Unified memory, no host/device copy. | Comparable (Q4_K_M ≈ 1.1 GB). |
| **SwiftPM dependency weight** | Pure Swift. `mlx-swift-lm` declares `platforms: [.macOS(.v14), .iOS(.v17)]`, which matches TapQ's `.macOS(.v14)` floor (`Package.swift:228`) exactly, so the package graph does not move. Pulls `mlx-swift` plus a tokenizer/downloader package. | Heavier. Upstream ships a prebuilt XCFramework but no first-party SwiftPM manifest, so integration means a fork (`StanfordBDHG/llama.cpp`) or a wrapper (`llama.swift`), plus enabling Swift/C++ interop across the consuming package. A third-party fork in the trust path of a tool that gates agent approvals is a real cost, not a paperwork one. |
| **Licensing** | MIT. Compatible with TapQ's Apache-2.0. | MIT. Also compatible. |
| **Risk** | `MLXFoundationModels` and `MLXGuidedGeneration` require the macOS/iOS/visionOS **27.0 SDK** to build. In July 2026 that is a beta toolchain, and CI runs `macos-15`. This is the one genuine obstacle. | No SDK gate. |

**Recommendation: MLX Swift.**

The deciding factor is not speed and not memory — at 1.7B and 4-bit both routes fit the
budget with room. It is that the MLX route lets the local backend *reuse the schema
declaration* rather than restate it. TapQ's stage-2 design spends real effort keeping one
vocabulary: `tierValues` and `codeValues` are derived from `allCases` so a tier cannot be
added without the model's output schema following it, and the prompt text is digest-pinned
so a change has to be deliberate. A GBNF grammar is a second, unpinned copy of that
vocabulary living outside Swift. Adopting it would undo a property the contract was
built to have.

Secondary, but not small: TapQ currently has **zero external SwiftPM dependencies**
(`Package.swift` declares none), and `CONTRIBUTING.md` asks that third-party dependencies
be justified on benefit and license impact. Whichever route is chosen breaks that streak,
so the one that breaks it with a pure-Swift, platform-aligned, first-party-maintained
package is the cheaper break.

**Contingency, in order, if the macOS 27 SDK gate cannot be cleared on the build
machine:**

1. **`MLXLLM` plus a masking logit processor.** The guided-generation module is the part
   with the SDK requirement; core MLX inference is not. The output grammar here is
   *finite and tiny* — an object with two enum fields (3 and 6 literals), a JSON string
   capped at 140 characters, and a number in `0...1`. That is small enough to mask by
   hand: two token-prefix tries and a bounded string state machine, roughly 200 lines
   TapQ owns outright, with the vocabulary still derived from `allCases`. This keeps the
   contract single-sourced and removes the SDK gate entirely.
2. **llama.cpp**, accepting the duplicated vocabulary and pinning it with a test that
   regenerates the GBNF from `allCases` and fails on drift.

Do not treat option 1 as a downgrade. It is arguably the better long-run answer, because
it makes constrained decoding a property TapQ tests rather than one it inherits.

### Flag surface

```bash
tapq serve --reasoner local --reasoner-model /path/to/Qwen3-1.7B-Instruct-4bit
tapq bench reasoner --scenarios bench/reasoner-scenarios-v1.ndjson \
    --reasoner local --reasoner-model /path/to/Qwen3-1.7B-Instruct-4bit --json
```

| Option | Behavior |
|---|---|
| `--reasoner local` | New `ReasonerProvider` case. Requires `--reasoner-model`. |
| `--reasoner-model PATH` | Directory of user-supplied weights. Required with `--reasoner local`, rejected with any other provider — mirroring how `--encoder-mode` requires `--encoder-model`. |

Rules:

* **Nothing is bundled and nothing is downloaded.** The runtime never fetches weights.
  A backend that could download is a backend that could be pointed at attacker-chosen
  weights over the network, and this one gates approvals.
* **Validation at startup**, not at first request: the path exists, is readable, is a
  directory holding the expected config/tokenizer/weight files. On failure `serve`
  degrades to no reasoner and reports it (matching `--encoder-model`, `docs/CLI.md:76`),
  while `bench` fails (matching `docs/CLI.md:274-276`).
* **The bench report must carry model identity.** A stage-2 score without the weights
  that produced it is not comparable to anything. Record the model's own identifier from
  its config plus a digest over the weight files, in both the text and `--json` reports.
* **`reasoner-log.jsonl` must record provider and model per line.** A shadow-review log
  that mixes two backends without saying which is uninterpretable, and the whole point of
  the log is comparing what a decision asked for against what the user did.
* **No `--reasoner-timeout` flag exists today.** `ReasonerConfig.timeoutSeconds` is 2.0 and
  is not user-settable. If the local backend needs a different budget, adding the flag is
  the honest route — but the budget then belongs in the bench report too, because bench
  grades an answer that arrives late as a timeout abstention.

### Prewarm and prefix cache

`ContextReasoning` has no `prewarm` requirement; `FoundationModelReasoner.prewarm()` is a
concrete method the runtime calls when an approval is enqueued
(`FoundationModelReasoner.swift:85-87`). The local backend needs the same seam, and it
matters more here: for the Apple backend prewarming is a hint, while for this one it is
loading a gigabyte.

* **Load at `serve` start**, not at first approval. The alternative — load lazily and let
  the first assessment abstain on timeout — silently makes the first risky action of every
  session the one with no stage-2 opinion. Cost to state in the docs: selecting
  `--reasoner local` costs roughly 1.2 GB resident for the process lifetime.
* **Prefill the instructions once and keep the KV cache.**
  `ReasonerPromptContract.instructions` is stable by construction and the file says the
  reason is exactly this — it "never varies by request, which is what lets an on-device
  session keep its prefix cache warm across approvals". Per-request prefill then covers
  only the fenced context.
* **Reset to the cached prefix on every request** — copy the prefix cache, never continue
  the previous one. `FoundationModelReasoner` builds a fresh session per call for this
  reason (`FoundationModelReasoner.swift:58-62`): a reused transcript leaks one approval's
  command text into the next one's prompt and grows the window until it fails. The local
  backend inherits the hazard and must inherit the discipline.
* **Sequential only.** `tapq bench reasoner` already runs scenarios sequentially because
  concurrency would thrash the prompt cache and turn reported latency into queueing delay
  (`docs/CLI.md:269-272`). The same applies live.

### Deadline fit

The hard bound is `timeoutSeconds` (2.0 by default, `ContextReasoning.swift:75`) plus
`ReasonerEscalation.outerBoundGraceSeconds` (0.25, `ReasonerEscalation.swift:70`) —
**2.25 s wall clock**, after which the answer is discarded whether or not it arrives.

Token budget, from the caps that already exist:

| Segment | Size | Tokens (approx.) |
|---|---|---|
| Instructions prefix | ~1.9 kB, fixed | ~430, **prefilled once and cached** |
| Fenced context, median bench row | ~200–400 chars | ~100 |
| Fenced context, worst case | 4000 + 1000 + 1000 chars plus short fields (`commandTextCharacterLimit`, `descriptionCharacterLimit`) | ~1700 |
| Output, all four fields | note ≤140 chars (`ReasonerDecisionContract.noteCharacterLimit`) | ~80 |
| Output without the note | tier + code + confidence | ~15 |

On an M-series machine with a 4-bit 1.7B resident and the prefix cached, prefill runs at
four figures of tokens per second and constrained decode at roughly 80–120 tokens per
second after the 15–25% grammar tax. That gives ≈0.8 s at the median and ≈2.5 s at the
worst-case cap — **it fits typical traffic and does not fit the caps**. The design
therefore has to name which knob moves first, before the first bench run rather than
after it.

**Knob order, most-preferred first:**

1. **Drop `note` from the generated schema for this backend.** It is annotation: never
   parsed, never branched on, hard-capped precisely because it is not a signal (the
   `ReasonerRationale` doc comment), and `ReasonerRationale.note` is optional. Removing it
   cuts decode from ~80 tokens to ~15 — most of the decode cost — and costs the contract
   nothing. Note the bench consequence: `bench/README.md` grades tier and code only, so
   this does not change any reported number.
2. **Lower `commandTextCharacterLimit` for this backend.** 4000 → 1500 covers essentially
   every real command line and removes most of the worst-case prefill. This *does* change
   the prompt and therefore the measurement, so it must be a distinct, recorded prompt
   variant with its own digest — not a silent tweak.
3. **Cap the KV context** at 2048 tokens, which the two caps above make safe, reducing
   both attention cost and memory.
4. **Drop a size class** (Qwen3-0.6B) before dropping bits. 3-bit quantization degrades a
   1.7B model's instruction-following disproportionately, and instruction-following is
   the entire task here.
5. **Raise `timeoutSeconds`** last. It is the only knob the user pays for directly, and
   2 s is already near the limit of what someone holding a gesture will tolerate.

### Checkpoint licensing and provenance

Qwen3 is released under **Apache-2.0**, including the 1.7B dense variant, with Base and
Instruct forms published on the Hugging Face Hub. Apache-2.0 is compatible with TapQ's
own license and imposes no redistribution burden here, because TapQ redistributes
nothing: the user supplies the path.

Provenance rules for any checkpoint this project *suggests*:

* Name the exact repository and revision, not just a model family. "Qwen3-1.7B-Instruct"
  is not a checkpoint; a repo plus a commit is.
* Prefer weights converted by a named, auditable pipeline. Community 4-bit requantizations
  are convenient and are also the easiest place to put something else.
* Record the digest in the bench report (above), so a number can be traced to the bytes
  that produced it.
* State in the docs that TapQ neither vets nor endorses any particular checkpoint, and
  that the escalation-only contract is what makes running an unvetted one merely
  annoying rather than dangerous.

### Effort

| Packet | Content |
|---|---|
| 1 | `ReasonerProvider.local`, `--reasoner-model` plumbing through `serve` and `bench`, startup validation, degrade/fail behavior, provider+model fields in the bench report and `reasoner-log.jsonl`. A `LocalReasoner` that abstains with `reason: model_unavailable` when unbuilt, so this lands and is tested on both CI platforms with no dependency. |
| 2 | The MLX conformance behind `canImport`: dependency, model load, prewarm, prefix cache, constrained decode to the four-field schema, deadline fit, diagnostics matching `FoundationModelReasoner`'s closed reason set. |
| 3 | First real runs. `tapq bench reasoner --reasoner local` across the corpus, latency p50/p95, the knob decisions from the list above, results written into `docs/CLI.md` and a bench baseline. |
| +1 | Risk buffer: the SDK gate forcing contingency route 1, which is a self-contained masking implementation. |

**3–4 packets.**

---

## 3. Track B proper: continuous projection

The destination from the roadmap: stage-1 encoder embeddings → trained projection →
frozen LLM embedding space, with no LLM fine-tuning (SensorLLM, arXiv:2410.10624;
LLaSA, arXiv:2406.14498). Track B is *additive* to Track A — the text prompt does not go
away, the motion channel joins it.

Before any of it: **the control arm.** Rendering the encoder's eight class scores as a
line of prompt text requires no new export, no projection, and no paired training — just
an additive field on `ReasonerContext`, which is documented as safe to extend (its doc
comment: "Designed additively — later packets (agent-context fusion) add fields"). If
continuous projection cannot beat
`encoder: nod 0.91, quiet 0.06` written into the existing prompt, Track B is not worth
its complexity, and the honest response is to say so and stop. This control is named
again as gate G5 in section 5.

### (a) Embedding export

`TapQ1Encoder.features(x)` returns per-timestep features `[B, 32, 64]`
(`ml/tapq1/model.py:29-31`); `forward` mean-pools them before the classifier
(`:33-35`); and `ExportWrapper` emits softmax scores only (`:53-54`).

**Export a separate, embedding-only `.mlpackage`.** Not a second output on the shipped
model. `CoreMLMotionScorer` requires exactly one output of shape `[1, 8]`
(`CoreMLMotionScorer.swift:98-108`), so a two-output model fails at
`unsupportedModel("expected exactly one multi-array output")` and every deployed model
file stops loading. That validation is correct and stays.

**Export the `32 × 64` token sequence, not the mean-pooled 64-d vector.** Four reasons:

1. **Recoverability.** Mean pooling downstream is one line. The sequence cannot be
   recovered from the pooled vector, so exporting the pooled form makes an irreversible
   modeling decision inside a frozen artifact.
2. **The recipe needs tokens.** SensorLLM's alignment stage aligns per-timestep structure
   with text. A one-token motion channel gives the LLM nothing to attend over.
3. **Pooling is already known to suffice for the *atom* decision** — that is what the
   shipped scorer does. If pooling also sufficed for context fusion, the right design
   would be the text control arm above, which is far cheaper. Exporting the sequence is
   what makes the two distinguishable.
4. **It keeps the choice trainable.** Any pooling or temporal downsampling then lives in
   the projection, where it can be measured and changed, instead of in the frozen
   contract.

The honest cost: 32 tokens per window is 32 prompt slots, and at a 2048-wide hidden
state that is 65,536 floats injected per window. Cheap for one window, not for a trace of
many. Temporal downsampling belongs in the projection.

**Metadata and version discipline**, mirroring `tapq1-features-v1`:

| Key | Value | Why |
|---|---|---|
| `com.tapq.tapq1.feature_layout` | `tapq1-features-v1` | Input contract is *identical* — same 9 channels, same fixed scaling, same window |
| `com.tapq.tapq1.window_length` | `32` | Same reason |
| `com.tapq.tapq1.embedding_layout` | `tapq1-embeddings-v1` | New axis, new version string |
| `com.tapq.tapq1.embedding_shape` | `32x64` | Tokens × dimension, so a consumer validates instead of hardcoding |
| `com.tapq.tapq1.checkpoint_digest` | sha256 over the state dict | Written by **both** exports, so a projection trained on embeddings from checkpoint A is detectably mismatched against a scorer from checkpoint B |
| `com.tapq.tapq1.classes` | **deliberately absent** | An embedding model has no class vector; declaring one would be a lie, and its absence makes `CoreMLMotionScorer` reject the package early with `metadataMissing` instead of confusingly late |

Three independent version strings now exist, on three axes, and they must not be
collapsed:

* `tapq1-features-v1` — what goes *in* (channels, scaling, window).
* `tapq1-embeddings-v1` — the *intermediate* representation (d_model, token count, which
  layer, whether pooled).
* `tapq1-decision-v1` — what comes *out* of stage 2.

An embedding-layout bump invalidates every trained projection exactly as a feature-layout
bump invalidates every trained scorer. Mirror the Swift side with an
`EncoderEmbeddingContract` and a pinning test, the way `EncoderContract.swift` and
`ml/tapq1/layout.py` are pinned to each other today.

This packet is buildable **now**: `smoke.py`'s synthetic windows are sufficient to
exercise export, metadata, shape, and re-load.

### (b) The paired dataset that does not exist

This is the largest gap in Track B and the least glamorous.

#### Agent-context capture format

Half of it already exists in a different file. `reasoner-log.jsonl` records tier,
rationale code, confidence or abstention, latency, the implied confirmation, and what
the user then decided (`docs/CLI.md:81-90`). What is missing is the motion side and the
key that joins them.

Proposed `agent-context-v1.ndjson`, written under a new opt-in flag (off by default), one
line per reasoner-observed approval:

```json
{
  "schema": "tapq1-agent-context-v1",
  "session_id": "…", "subject_id": "…", "request_id": "…",
  "clock": {"wall": 1785000000.123, "motion": 51234.567},
  "context": { "tool_name": "Bash", "command_text": "…", "cwd": "…",
               "agent_name": "Claude Code", "summary": "…", "detail": "…" },
  "windows": [{"start": 51230.08, "end": 51231.36, "center": 51230.72,
               "scores": {"quiet": 0.02, "nod": 0.91, "…": 0.0}}],
  "gesture_events": [{"motion_time": 51231.9, "class": "nod",
                      "source": "heuristic|encoder"}],
  "deterministic_confirmation": "standard",
  "reasoner": {"provider": "local", "model_id": "…", "tier": "sensitive",
               "code": "system_configuration", "confidence": 0.72,
               "latency_ms": 812},
  "effective_confirmation": "double_gesture",
  "resolution": {"outcome": "approved", "gestures": 2, "elapsed_ms": 3400}
}
```

Notes that carry weight:

* **`context` is `ReasonerContext`'s wire form, unchanged.** It is already the bench
  corpus's schema (`bench/README.md`). Inventing a second request encoding would
  guarantee they diverge.
* **The clock pair is the crux.** Motion timestamps are CoreMotion hardware timestamps
  (`docs/CLI.md:188`) and approvals arrive on wall clock. One `{wall, motion}` pair *per
  record*, sampled at a known instant — not one per session, which does not survive drift
  over a long run.
* **Privacy is not a footnote here.** `summary` for a `Bash` request is the front of the
  command line and can carry a connection string or a token passed as an early argument
  (`docs/CLI.md:92-98`). A paired corpus is strictly local by default, and any shareable
  variant needs the context fields redacted or hashed before it leaves the machine.
  `scripts/check-public-boundary.sh` already refuses `*.jsonl` in tracked content, which
  is the right default and should stay.

#### The join key `data.py` computes and throws away

`data.windows()` builds a `starts` list (`ml/tapq1/data.py:82`), appends
`timestamps[begin]` to it for every window (`:93`), and then returns only
`(np.stack(slices), np.array(centers))` (`:97`). The span is computed and discarded, so
there is no way to ask which windows overlap a given approval.

Return-signature change:

```python
# ml/tapq1/data.py
WindowIndex = namedtuple("WindowIndex", "center start end group")   # arrays, all [N]

def windows(timestamps, channels, hop=8, gap_reset_seconds=0.5):
    ...
    return np.stack(slices), WindowIndex(centers, starts, ends, groups)
```

Call sites: `label_windows` (`data.py:100-105`) takes `index.center` and is otherwise
unchanged; `load_manifest` destructures at `data.py:119`; `train.py:100` and
`pretrain.py:70` consume `load_manifest`'s tuple. `load_manifest` must also stop
flattening provenance — it concatenates across manifest entries (`data.py:129-134`),
losing which capture each window came from. Carrying a parallel `groups` array of
session identifiers fixes the join *and* supplies exactly what the non-leaky split needs,
so one change settles two problems.

#### A decision-label vocabulary, separate and versioned

New `ml/tapq1/decision_layout.py`, mirroring
`Sources/TapQContextBaseline/ReasonerContract.swift` the way `layout.py` mirrors
`EncoderContract.swift`, and pinned by a Swift test the same way:

```python
VERSION = "tapq1-decision-v1"
TIERS = ["routine", "sensitive", "destructive"]           # RiskTier.allCases order
CODES = ["data_loss", "credential_exposure", "external_publication",
         "system_configuration", "bulk_or_unscoped_change", "unspecified"]
```

Three rules:

1. **Never merge it with `layout.CLASSES`.** A window's gesture label and a request's
   decision label are different axes over different units. `train.py:18-26 class_weights`
   assumes index 0 is the background class and bins over `layout.CLASS_COUNT`; handed
   decision labels it would silently reweight the wrong thing and report a plausible
   number.
2. **Order is semantics, not encoding.** `RationaleCode.allCases` order is *precedence*
   order (the `RationaleCode` doc comment) — the reasoner reports the first applicable
   code. A Python mirror that reorders the list is not a different serialization, it is a
   different rule.
3. **Version independently.** `tapq1-decision-v1` moves when the tier set, code set, or
   field names move — which is already the rule `ReasonerDecisionContract`'s doc comment
   states, and which `bench/reasoner-scenarios-v1.ndjson` is authored against.

#### Grouping metadata and the split leak, named

`data.windows` defaults to `hop=8` (`data.py:75`) over `WINDOW_LENGTH = 32`
(`layout.py:18`). Adjacent windows therefore share 24 of 32 samples: **75% overlap**.
`train.py:29-33 split()` permutes window indices uniformly at random. The consequence is
that a validation window typically shares three quarters of its samples with a training
window, and a single ~1.5 s gesture instance spans four or five windows that land on
both sides of the cut.

The per-class precision and recall printed at `train.py:36-50` are therefore optimistic
by an unknown margin — closer to a memorization check than a generalization estimate.
**No honest generalization number currently exists in this repository, and none can be
produced without this fix.**

What the corpus must carry, and what the split must use:

* **`session_id`** per capture, so windows from one recording never straddle the cut.
* **`gesture_instance_id`**, the index of the covering label segment — available for free
  once spans are returned. Quiet windows group by contiguous run within a session.
* **`subject_id`**, so leave-one-subject-out is possible. That is the number that predicts
  a new user's experience, and EarDA's ~43-point drop on naive cross-domain transfer is
  why a within-subject number must never be quoted as a product claim.

Split on groups, never on windows.

### (c) Projection training recipe

**What freezes.**

* **The encoder.** It is the pinned, exported artifact; retraining it invalidates the
  scorer `.mlpackage`, the embedding `.mlpackage`, and every projection trained against
  it. The `checkpoint_digest` metadata above is what makes a violation detectable.
* **The LLM.** Track B's premise, and also the empirical read: FMSys'25
  (arXiv:2504.02878) found 3D free-space motion near chance for an LLM *even after LoRA*.
  Fine-tuning the language model is not where the win is, which is the same finding that
  keeps stage 2 out of the always-on classification path entirely.
* **Trainable: the projection, and only the projection.**

**Architecture — start linear.** 64 → d_llm per token (2048 for a Qwen3-1.7B-class
model) is ≈133k parameters, already 1.9× the ~70k encoder. A 2-layer MLP
(64 → 256 → 2048, GELU) is ≈543k, ~7.8× the encoder. With a first capture study yielding
hundreds to a few thousand paired windows, the live failure mode is the projection
overfitting a handful of sessions, not underfitting them. Escalate to the MLP only on
evidence of underfitting — training loss plateauing *above* the text control — not on
principle.

**Normalize the projection's output to the frozen LLM's input-embedding statistics**
(per-dimension mean and standard deviation of its token embedding table). Otherwise the
first attention block receives magnitudes it was never trained on. Cheap, and the kind of
thing that silently costs several points.

**Augmentation happens before embedding.** `train.py:72` calls
`augment.augment(train_x[chosen], rng)` *inside* the batch loop, so every epoch draws
fresh rotations, warps, and jitter — per-epoch resampling is doing real regularization
work at this data scale. Caching embeddings once, which is the obvious optimization now
that the encoder is frozen, silently converts that into a fixed dataset of N vectors and
removes the largest regularizer available.

> **Rule: augment in the raw-window domain and run the frozen encoder inside the training
> loop.** At ~70k parameters a forward pass over a batch of 64 windows is negligible next
> to a projection step. If a cache is ever unavoidable, materialize K ≥ 8 augmented
> replicas per window with recorded seeds, never a single replica, and record K and the
> seeds in the artifact.

A related trap worth naming: `augment.rotate` (`augment.py:26-34`) and
`augment.time_warp` (`:37-49`) do not clip; only `jitter` does, at `:59`. The chain
`jitter(time_warp(rotate(...)))` (`:63`) therefore lands inside the layout's declared
[-1, 1] range as a consequence of ordering. A Track B pipeline that reorders the chain,
or skips jitter to keep the signal clean, hands the frozen encoder inputs outside the
range `layout.scale` guarantees (`layout.py:52`) — inputs it was never normalized for.

**Evaluation, on the same bench semantics.** `bench/README.md`'s rules carry over
verbatim: tier is an exact match, code is set membership reported separately, abstention
is a miss on `sensitive` and `destructive` rows, false escalation is reported as the two
numbers the corpus defines, and under-escalation is the risk metric that gates promotion
out of shadow. Three arms:

1. **Non-regression on the existing corpus.** Feed the fused model every row
   with a null motion channel — zeroed, or a learned "no motion" token — and require it
   to score no worse than the text-only local backend on tier accuracy, benign
   false-escalation rate, and under-escalation over `lookalike_destructive`. Buildable the
   moment a projection exists, and it answers the first question anyone should ask: did
   adding a motion channel break the text path?
2. **Paired-corpus metric.** A **new file**, not an edit.
   `bench/reasoner-scenarios-v1.ndjson` is append-only and any change to an existing
   `expected_tier`, `acceptable_codes`, or `context` requires a new corpus
   (`bench/README.md`, "Versioning"). A paired corpus adds a window reference per row and
   changes nothing else, so it reports on the same axes.
3. **The text control arm** from the top of this section. Beating it by more than the
   paired corpus's own label noise is the condition for Track B being worth shipping.

---

## 4. `ml/` debts that block Track B

Listed, not fixed in this packet. Each is data-free and each would otherwise be
discovered in the middle of the capture study, which is the worst time.

**1. The pretrain → train checkpoint round trip is never tested.**
`ml/tapq1/smoke.py:67-68` calls `pretrain(x, epochs=2, ...)` and discards the returned
encoder, then calls `train(x, y, epochs=5, ...)` with no `pretrained=`. The handoff at
`train.py:58-60` is a **strict** `load_state_dict`, so a key rename or an architecture
default change between the two scripts ships undetected and surfaces only when a real
pretraining run is loaded for the first time.
*Fix:* save the pretrained state dict to a temp path in smoke and pass `pretrained=` to
`train`.

**2. The export is never re-loaded or metadata-checked in Python.**
`smoke.py:85` calls `export(checkpoint, arguments.export)` and prints the path. The
module docstring at `smoke.py:8-9` claims it "exports and re-loads a Core ML package";
nothing re-loads it. So `export.py:36-39`'s three metadata writes — the exact strings
`CoreMLMotionScorer` validates against — are never verified anywhere in Python. The Swift
side would catch a mismatch, but only after someone has produced a model and tried to
load it.
*Fix:* re-open the saved package with `coremltools`, assert the three
`user_defined_metadata` values equal `layout.VERSION`, `",".join(layout.CLASSES)`, and
`str(layout.WINDOW_LENGTH)`; assert exactly one output of shape `[1, 8]`; run one
prediction and assert the row sums to 1.

**3. No Python CI job exists.**
`.github/workflows/ci.yml` has `macos` and `linux` jobs; both are Swift-only. Nothing
runs `python -m tapq1.smoke`, so `ml/` is unbuilt and untested on every commit, and
`ml/requirements.txt` (numpy, torch, coremltools) is never resolved by CI.
*Fix:* a third job on `ubuntu-24.04` installing CPU torch from `ml/requirements.txt` and
running `python -m tapq1.smoke`; keep the Core ML export half macOS-only, where
`coremltools` conversion is meaningful.

**4. The training split leaks.**
`train.py:29-33 split()` permutes windows uniformly, over windows produced at
`data.windows(hop=8)` (`data.py:75`) with `WINDOW_LENGTH = 32` — 75% overlap between
neighbors, and one gesture instance spread across several windows on both sides of the
cut. Every number `per_class_report` prints (`train.py:36-50`) is optimistic by an
unknown margin.
*Fix:* split on groups keyed by `(session, gesture_instance)`, which requires `data.py:97`
to return the spans it already computes at `:93`; add leave-one-subject-out as the
reported generalization number.

**5. Checkpoints are bare state dicts with no configuration or metadata.**
`pretrain.py:79` and `train.py:110` both `torch.save(encoder.state_dict(), ...)`;
`export.py:24` and `train.py:59` load them with strict `load_state_dict`. Nothing records
`d_model`, layer count, the layout version, the seed, or a digest of the manifest the
checkpoint was trained on. A checkpoint produced under different `TapQ1Encoder()` defaults
either fails to load with an unhelpful key error or — if the change is shape-compatible —
loads and is quietly wrong.
*Fix:* save
`{"format": "tapq1-checkpoint-v1", "layout_version": layout.VERSION, "arch": {...}, "seed": ..., "manifest_digest": ..., "state_dict": ...}`
and have every loader check `layout_version` before `load_state_dict`. This is also the
prerequisite for the `checkpoint_digest` metadata that section 3(a) puts on both exports.

**Effort: 2 packets.** Debts 1–3 group naturally (smoke coverage plus the CI job that
runs it); debts 4–5 group because both touch `data.py`'s return signature and the
checkpoint format together.

---

## 5. Gates and order

### Buildable now, with zero captured data

| Work | Depends on | Packets |
|---|---|---|
| `--reasoner local` backend | The bench corpus, which exists | 3–4 |
| Embedding-only `.mlpackage` export, plus smoke coverage | `smoke.py`'s synthetic windows, which exist | 1 |
| `ml/` debts 1–5 | Nothing | 2 |
| Paired-capture logging format: Swift writer plus Python loader | `ReasonerContext` and `reasoner-log.jsonl`, which exist | 2 |

**8–9 packets of unblocked work.** None of it needs a single recorded sample.

### Data-gated

| Work | Gate |
|---|---|
| Projection training | The capture study (motion half) **and** real agent sessions logged in the paired format (decision half). The decision half additionally needs `--reasoner local` running in shadow, because without a backend there are no decisions to pair with. |
| Few-shot personalization | Per-subject captures and honest leave-one-subject-out numbers |
| NL-defined gestures | Everything above, plus an *open* gesture vocabulary — which `layout.CLASSES` and `GestureClass` are deliberately closed against, so this is a contract change, not a training change |

### Go / no-go

| Gate | Criterion | Why it is the gate |
|---|---|---|
| **G1** | `tapq bench reasoner --reasoner local` produces a report at all | Until it does, every stage-2 number in this repository is a definition. This is the only item that converts one into a measurement. |
| **G2** | On eligible hardware, `local` and `apple` are run over the same corpus and their tier accuracies fall inside a stated band | Otherwise `local`'s numbers describe `local`, not "the stage-2 reasoner". **This gate cannot be cleared on the maintainer's Mac** and needs either eligible hardware or a second reviewer — flag it early rather than discovering it at review. |
| **G3** | Promotion out of `shadow`: thresholds W9 formalizes, on under-escalation over `lookalike_destructive` and on `benign_false_escalation_rate` over the expected-`routine` rows, with p95 latency inside 2.25 s | `bench/README.md`'s under-escalation rule already names it as the metric that should gate promotion; W9 puts numbers on it. The latency bound is not a nicety — an answer past the outer bound is graded as a timeout abstention, so a slow reasoner scores as an absent one. |
| **G4** | Capture study: per-gesture offline separability at 25 Hz on held-out recordings, measured with a **group-aware** split (§4 debt 4) | The roadmap's Phase 0 go/no-go. Measured with today's split it would be measured wrong, which is why debt 4 is upstream of the study rather than downstream. |
| **G5** | Track B is worth building: the fused model beats the text-rendered-class-scores control on the paired corpus by more than that corpus's own label noise | FMSys'25 (arXiv:2504.02878) put 3D free-space motion near chance for an LLM even after LoRA. "The motion channel carries nothing the LLM can use" is a live outcome, not a pessimistic hypothetical, and the correct response to it is to keep the encoder as the detector and stop — which is only possible if the control arm was built first. |

### Order

```
--reasoner local  →  ( embedding export ‖ ml/ debts )  →  paired logging
                  →  capture study (G4)  →  projection training (G5)
```

The local backend goes first for one reason: every later gate is expressed in bench
numbers, and there is currently no way to produce one. The embedding export and the
`ml/` debts are independent of it and of each other, so they parallelize. Paired logging
comes after the local backend because a paired record's decision half is produced *by*
the backend. Projection training is last and is gated twice — on data existing, and on
the control arm not already being good enough.

---

## References

* **SensorLLM** — arXiv:2410.10624. The Track B recipe: a two-stage alignment that maps
  sensor encoder output into a frozen LLM's embedding space, with the sub-4B variant
  competitive. Sections 3 and 3(c).
* **LLaSA** — arXiv:2406.14498. IMU-plus-LLM in the same architecture family; corroborates
  that the projection approach is the studied one rather than an invention here.
* **FMSys'25** — arXiv:2504.02878. 3D free-space motion near chance for an LLM even after
  LoRA. The reason stage 2 is never the always-on classifier (section 1), the reason the
  LLM stays frozen (section 3(c)), and the reason gate G5 exists rather than being assumed
  (section 5).
* **LIMU-BERT** — SenSys'21. The stage-1 encoder's ancestry and the masked-reconstruction
  pretraining `ml/tapq1/pretrain.py` implements; the untested handoff in §4 debt 1 is the
  handoff this recipe depends on.
* **EarDA** — earable domain adaptation; ~43-point drop on naive smartphone-to-earable
  transfer, and the finding that gesture *speed* varies per user more than gesture *shape*
  (which is why `augment.time_warp` exists). Sections 3(b) and 3(c).
* **EarBender** — UbiComp'23 Adjunct. IMU-based ear/bud swipe at 97.4% on other hardware:
  the evidence that the motion channel carries usable information at all, and therefore
  that a paired corpus is worth the cost of collecting.
