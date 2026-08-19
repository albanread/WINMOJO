# DragonMax

Bringing MAX-class inference to Snapdragon silicon on native Windows ARM64 —
Hexagon NPU, Adreno GPU, Oryon CPU.

Started 2026-08-19. Trunk `C:\projects\DRAGONMAX`, branch `main`.
Running record: [`DRAGONMAX-JOURNAL.md`](DRAGONMAX-JOURNAL.md).

## Relationship to WINMOJO

Separate project, deliberately. [WINMOJO](../WINMOJO) ports the **Mojo
compiler** to Windows ARM64 and explicitly excludes `max/` and GPU. DragonMax
is the GPU/NPU layer that WINMOJO left out.

This tree is forked from WINMOJO rather than from Modular, so it inherits the
Windows ARM64 build work instead of repeating it. Three remotes:

| Remote | Points at | Role |
|---|---|---|
| `origin` | *(not yet created)* | DragonMax's own |
| `winmojo` | `C:/projects/WINMOJO` | Windows ARM64 port; fixes flow **in** |
| `upstream` | `github.com/modular/modular` | never pushed to |

Forked at WINMOJO `dde8f83773` (its G3).

**Dependency, and why it does not block:** DragonMax eventually needs a working
`mojo.exe`, which is WINMOJO's G6 and not done. But the early gates below need
no Mojo at all — they characterise hardware and drive vendor runtimes directly
from C++/Python. D0–D2 run in parallel with WINMOJO G3–G6.

## What we are up against

Read [`dragon/recon/MAX-ANATOMY.md`](dragon/recon/MAX-ANATOMY.md) before
planning anything. The short version:

**MAX's engine and GPU device runtime are closed source.** `max/python/max/_core`
is `.pyi` stubs only, and the `AsyncRT_DeviceContext_*` symbols that
`device_context.mojo` calls are absent from the open `AsyncRT/` tree, which
ships a CPU device and nothing else. A Snapdragon backend cannot be added by
editing MAX's runtime; that source is not public.

**What is open is still substantial:** the whole Mojo GPU programming model,
the MLIR target tables in `info.mojo`, the entire `max/kernels` library in
Mojo, and the Python graph/nn/pipelines stack. Modular even ships
`mojo/stdlib/docs/adding-gpu-targets.md`, a step-by-step guide to adding a new
GPU architecture — and Apple Metal already exists there as a third, non-CUDA,
non-HIP, tile-based, unified-memory backend. That is the closest architectural
analogue to Adreno and the diff worth imitating.

So: **compile side open, run side closed.** That split shapes every decision.

## The performance fact that steers the design

Measured on this box, decode / prefill tok/s:

| Path | Decode | Prefill |
|---|---|---|
| QAIRT NPU-native, Qwen3-1.7B | **35.6** | **766** |
| CPU, Gemma-4-E4B | 25.3 | 157 |
| llama.cpp NPU offload, Gemma-4-E4B | 13.8 | 431 |

Naive NPU offload *lost to the CPU* on decode. Only an ahead-of-time compiled
QNN graph beat it. The Hexagon NPU is not a kernel-dispatch device — it pays
off only when handed a whole graph at once. Adreno, by contrast, is a natural
kernel-dispatch target but is the weakest of the three in raw throughput on
this part (X1-45, the cut-down variant).

Design consequence: the NPU wants a **graph compiler target**, the GPU wants a
**device backend**. These are different mechanisms and the project should not
pretend otherwise.

## Gate ladder

Evidence first. The strategy decision sits at D3, *after* measurement, not
before it.

| Gate | Deliverable | Status |
|---|---|---|
| **D0** | Recon: hardware measured, MAX anatomy mapped, licensing recorded | **done** |
| **D1** | Probe harness — drive all three surfaces from native Win ARM64 | next |
| **D2** | Baseline: one reference workload timed on NPU / GPU / CPU | |
| **D3** | **Strategy gate** — pick the spine on D2's evidence | |
| D4+ | *(defined by D3)* | |
| **GOAL** | A real model runs end-to-end on Snapdragon, beating CPU-only | |

### D1 — probe harness (no Mojo required)

Three standalone probes under `dragon/probe/`, each proving we can reach the
silicon from a native ARM64 process:

- `adreno_cl` — load Adreno OpenCL **directly from the driver store** (no ICD is
  registered under `HKLM\SOFTWARE\Khronos\OpenCL\Vendors`, so the generic
  loader finds nothing), enumerate, run a trivial kernel
- `adreno_vk` — Vulkan compute dispatch via the Qualcomm ICD
- `htp_qnn` — load `QnnHtp.dll` + `QnnSystem.dll` from the QAIRT bundle, build a
  context, execute a trivial graph on HTP V81

Exit criterion: each prints real device properties and a correct numerical
result. Cheap, and it kills the biggest unknowns early.

### D3 — the strategy gate

Three candidate spines. D2's numbers decide, and the choice is the user's.

**A. Reimplement the device ABI.** Provide `AsyncRT_DeviceContext_*` over
OpenCL/Vulkan for Adreno, so Modular's own stack sits on top unmodified.
Highest compatibility; bets on a closed engine accepting a foreign device, which
we cannot verify from source.

**B. Independent runtime.** Take the open parts — Mojo kernels, graph API, nn
layers — and execute them on our own engine across all three surfaces. Most
work, no dependency on closed binaries, fully ours.

**C. NPU-first, narrow.** Skip the GPU. MAX graph → QNN graph lowering, AOT
context binaries, HTP execution. Smallest scope, best payoff per the table
above, and it matches what the hardware actually rewards.

## Rules carried in from prior ports

- Assume every offset, size, and capability from documentation is wrong until
  measured on this box. The recon docs record measurements, not specs.
- Journal in-repo, not in chat.
- Finish, commit, start the next — in the same turn.
- GUI/visual results need a camera, not an assertion.
