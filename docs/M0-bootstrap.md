# M0 — Repo bootstrap and local model server

Technical documentation for the first milestone. It is written so that someone new to the project can understand what was built, why each choice was made, and how to reproduce it.

**Contents**
1. [Goal](#1-goal)
2. [Concepts](#2-concepts): how LLM inference works, quantization and GGUF, llama.cpp
3. [Choices and rationale](#3-choices-and-rationale): toolchain, model, ports
4. [What was built](#4-what-was-built)
5. [The llama.cpp server configuration, flag by flag](#5-the-llamacpp-server-configuration)
6. [Verification and baseline](#6-verification-and-baseline)
7. [Gotchas we hit](#7-gotchas-we-hit)
8. [References](#8-references)

---

## 1. Goal

Have a reproducible local environment with:
- a compiling Go module and the repository layout the later milestones fill in;
- a small instruct model served over an OpenAI-compatible HTTP API by `llama.cpp`;
- `make` targets and CI so that every later change is checked the same way.

M0 deliberately contains almost no gateway code. Its output is a working *upstream* to build the gateway against, and a **baseline** (time to first token, tokens/second) that every later benchmark is compared with.

## 2. Concepts

### 2.1 How LLM inference works: prefill vs decode

Generating text from a transformer happens in two phases with very different performance profiles.

| Phase | What happens | Bound by | Scales with |
|---|---|---|---|
| **Prefill** | The whole prompt is processed in one pass; attention keys/values for every prompt token are computed and stored (the *KV cache*). | Compute: many tokens are processed in parallel as large matrix multiplications. | Prompt length |
| **Decode** | One new token is produced per step. Each step reads *all* the model weights and the KV cache, but does little arithmetic. | Memory bandwidth. | Number of tokens generated |

Consequences that shape the whole project:
- The **first token** can only be emitted after prefill completes, so **time to first token (TTFT)** grows with prompt length. Later tokens arrive at a steady cadence set by decode speed, the **inter-token latency (ITL)**.
- TTFT and tokens/second are therefore *separate* metrics. A system can have excellent throughput and poor TTFT, or the reverse. The gateway reports both (see DESIGN §5).
- The KV cache is memory the server must hold per active sequence. This is why a server has a limited number of concurrent *slots* (§5), and why admission control (M5) matters.

### 2.2 Quantization and GGUF

A model's weights are normally stored as 16-bit floats. **Quantization** stores them in fewer bits (here roughly 4.8 bits per weight on average) with small per-block scale factors, trading a little accuracy for large savings in memory and bandwidth.

Why that matters for decode: decode is memory-bandwidth bound, so reading ~4x fewer bytes per token makes it roughly that much faster, and the model fits on a laptop.

Back-of-envelope for our model: 1.54 billion parameters × ~4.8 bits ≈ 0.9 GB for the weights; the file on disk is 1.12 GB (some tensors, such as embeddings, are kept at higher precision).

**GGUF** is llama.cpp's single-file model format: weights, tokenizer, and metadata such as the chat template, in one file that can be memory-mapped. **Q4_K_M** is a 4-bit "K-quant" mix that is the usual quality/size sweet spot.

### 2.3 llama.cpp server

`llama-server` is a C++ inference server with an OpenAI-compatible API (`/v1/chat/completions`, `/v1/models`, plus `/health` and `/metrics`). It treats the model as a black box behind that API, which is exactly how Crucible wants to see every backend (SRS §7, ADR-2): the same gateway code should work when the backend is later swapped for vLLM.

## 3. Choices and rationale

### 3.1 Where tooling runs: containers, nothing on the host
Go, the linter and the tests all run inside Docker containers started by the `Makefile`. Reasons:
- **The host stays clean.** Nothing needs installing or upgrading on the developer's machine.
- **Reproducibility.** The Go and linter versions are pinned in the Makefile and CI, so "works on my machine" and "green in CI" mean the same thing.
- A named volume (`crucible-gocache`) caches modules and build output between runs, so repeated runs are fast.

*Trade-off:* a container start adds ~1 s per command, and Docker Desktop's VM has a fixed memory budget (7.75 GiB on the reference machine) that every later service shares. This is a deliberate constraint to keep in mind in M2 and M4, when Postgres, Redis, Prometheus and Grafana join the stack.

Kubernetes work (M6) will use **minikube**, since it is already available on the reference machine; Helm charts and KEDA are cluster-agnostic.

### 3.2 Model: Qwen2.5-1.5B-Instruct, Q4_K_M
Requirements for the development model: runs at interactive speed on CPU, follows instructions, can produce structured JSON (the M9 eval use case), and has a licence that allows publishing results.

| Candidate | Size (Q4_K_M) | Licence | Notes |
|---|---|---|---|
| **Qwen2.5-1.5B-Instruct** (chosen) | ~1.1 GB | Apache-2.0 | Strong instruction following and JSON output for its size; 32k native context. |
| Llama-3.2-1B-Instruct | ~0.8 GB | Llama community licence | Smaller, but weaker at structured output, and a custom licence. |
| SmolLM2-1.7B-Instruct | ~1.1 GB | Apache-2.0 | Good, but a less mature ecosystem and weaker instruction following in my judgement. |
| Qwen2.5-0.5B-Instruct | ~0.4 GB | Apache-2.0 | Too weak for the main pool, but **useful later** as a deliberately worse model for the canary (M7) and the "eval gate must fail" test (M9). |

Choosing the same family at two sizes means the canary and degraded-model experiments change only the model size, not the prompt format or tokenizer.

### 3.3 Ports
llama.cpp is published on host port **8081**. Port 8080 is reserved for the gateway, so clients will point at 8080 from M1 onward and never talk to the model server directly.

## 4. What was built

```
go.mod                          module github.com/pratishtha-abrol/crucible (Go 1.22)
cmd/gateway/main.go             compiling stub with JSON structured logging (log/slog)
Makefile                        dev, down, logs, test, build, lint, model (Go targets run in Docker)
deploy/compose/docker-compose.yml   llama.cpp server with a health check
.github/workflows/ci.yml        lint + test + build on every push
.gitignore                      secrets, model weights, build output
```

Empty directories from the layout (`internal/*`, `migrations`, `observability`, …) hold `.gitkeep` files so the structure is visible from the first commit.

Everyday commands:

```bash
make model   # download the GGUF into ./models (override the location with MODEL_DIR=...)
make dev     # start llama.cpp; ready when `docker ps` shows (healthy)
make test    # go test ./...   (in a golang container)
make lint    # golangci-lint   (in a pinned container)
make down
```

## 5. The llama.cpp server configuration

From `deploy/compose/docker-compose.yml`:

| Flag | Value | What it controls | Why this value |
|---|---|---|---|
| `--model` | `/models/qwen2.5-1.5b-instruct-q4_k_m.gguf` | Which GGUF to load. The host directory is mounted read-only. | |
| `--alias` | `qwen2.5-1.5b` | The model name the API reports and accepts. | Clients never see the file name. |
| `--ctx-size` | `8192` | **Total** KV-cache budget in tokens, shared by all slots. | Memory use grows with this number. |
| `--parallel` | `4` | Number of slots = sequences generated concurrently. | Matches `max_concurrency_per_replica` in DESIGN §2.5; the gateway queue (M5) will admit at most this many requests per replica. |
| `--threads` | `6` | CPU threads used for generation. | More threads help until memory bandwidth saturates; the VM has 10 CPUs and the rest are left for other services. |

The important relationship is **per-slot context = `ctx-size` ÷ `parallel` = 2048 tokens**. A single request whose prompt plus output exceeds 2048 tokens is rejected with HTTP 400 (`exceed_context_size_error`). The gateway will need to map this to a clear OpenAI-style error rather than pass it through blindly.

All values can be overridden through environment variables (`LLAMA_CTX`, `LLAMA_SLOTS`, `LLAMA_THREADS`, `MODEL_FILE`, `MODEL_DIR`) without editing the file.

## 6. Verification and baseline

**Checklist**
- [x] `make dev` starts llama.cpp and the container becomes healthy.
- [x] `POST /v1/chat/completions` returns text.
- [x] With `"stream": true` and `curl -N`, tokens arrive incrementally, about 12 ms apart.
- [ ] CI is green: the workflow is written; this item passes once the first push runs.

**Baseline** (details and hardware in [`notes/M0.md`](notes/M0.md))

| Measure | Result |
|---|---|
| Decode speed | ~84 tokens/s (ITL median 11.9 ms, p95 12.9 ms) |
| Prefill speed | ~235 prompt tokens/s |
| TTFT, ~90-token prompt, cold | ~275 ms |
| TTFT, ~550-token prompt, cold | ~2.3 s |
| 200-token answer end to end | ~2.5 s |

These are CPU-in-a-container numbers. Absolute values are modest by design (SRS §7); the project cares about *relative* changes.

## 7. Gotchas we hit

These cost time, and each one affects later milestones.

1. **`--flag=value` corrupts file names with underscores.** llama.cpp rewrites `_` to `-` inside the whole `--flag=value` token, so `q4_k_m` became `q4-k-m` and the container crash-looped. Passing the flag and value as separate arguments fixes it.
2. **The first SSE event is not the first token.** llama.cpp emits `{"delta":{"role":"assistant","content":null}}` *before* prefill finishes. Measuring "time to first byte of the stream" gives ~3 ms, which is meaningless. TTFT must be measured at the first event whose `delta.content` is non-empty. This is the definition in SRS §4, and the proxy (M1) must implement it that way.
3. **Prompt caching makes repeated prompts look unrealistically fast.** The server reuses the KV cache for an identical prompt prefix, so a repeated prompt showed TTFT ≈ 16 ms. Benchmarks must use varied prompts (and say so), or they measure the cache instead of prefill.
4. **Measure from the right clock.** A timer started inside a downstream process in a pipeline starts *after* the request; the client doing the measuring must start the clock before sending.
5. **A stale registry login can break public pulls.** A saved but expired `ghcr.io` credential made `docker pull` of a public image fail with `denied`. `docker logout ghcr.io` fixed it.

## 8. References

- llama.cpp server README: <https://github.com/ggml-org/llama.cpp/tree/master/tools/server>
- GGUF format: <https://github.com/ggml-org/ggml/blob/master/docs/gguf.md>
- Qwen2.5 model card (GGUF): <https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF>
- Docker Compose file reference: <https://docs.docker.com/reference/compose-file/>
- golangci-lint: <https://golangci-lint.run/>
- Go modules reference: <https://go.dev/ref/mod>
