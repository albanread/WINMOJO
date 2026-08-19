# Porting plan and support matrix

What we intend to support, in what order, and what each step depends on.
Companion to `ARCHITECTURE.md`; the gate ladder itself lives in
`../../DRAGONMAX.md`.

## Support matrix — the target state

Honest about tiers. Not everything is worth supporting, and saying so early
prevents pretending later.

| Capability | Oryon CPU | Adreno GPU | Hexagon NPU |
|---|---|---|---|
| Mojo kernels compile | ✅ WINMOJO G6 | 🎯 via SPIR-V | ❌ not a kernel target |
| Kernel dispatch | ✅ AsyncRT CPUDevice | 🎯 GAP 2 runtime | ❌ wrong model |
| Whole-graph execution | 🎯 | 🎯 | 🎯 QNN AOT |
| fp32 | ✅ | 🎯 | ⚠️ poor — HTP is int-first |
| fp16 | ✅ | 🎯 shader fp16 | 🎯 |
| int8 / int4 quantised | ✅ | 🎯 | 🎯 **the NPU's reason to exist** |
| Unified zero-copy memory | ✅ | 🎯 integrated GPU | 🎯 |
| Graph capture / replay | n/a | ⏸️ deferred | n/a — AOT already |
| Multi-device / peer | n/a | ❌ one GPU | ❌ |

✅ works · 🎯 in scope · ⏸️ deferred · ⚠️ possible but unattractive · ❌ out

**The NPU column is the point of the project.** Its int8 cell is the only place
in this table where Snapdragon beats a laptop CPU by a margin worth the work.

## Dependency order

```
  WINMOJO G3..G6 ──────────────► mojo.exe on Windows ARM64
                                        │
  D1 probes ──► D2 baseline ──► D3 ──────┼──► SPIR-V codegen ──┐
   (no Mojo)     (no Mojo)    strategy   │                     ├──► kernels
                                         └──► device runtime ──┘      │
                                                                      ▼
  QNN harness ──► graph lowering ──► AOT context binaries ──► GOAL: model runs
```

Two chains run independently for a long time. **The QNN chain never needs
`mojo.exe` at all** — it is graph lowering and vendor-runtime work in C++/Python.
If WINMOJO stalls, the NPU line keeps moving. That is deliberate insurance, and
it argues for starting the QNN harness earlier than a strict gate order implies.

## Work breakdown

### W1 · Extract the device ABI specification
**Blocks:** everything in GAP 2. **Needs:** nothing. **Can start now.**

109 `AsyncRT_*` symbols are declared across `max/mojo/max/gpu/host/*.mojo` with
full signatures. Produce a machine-checkable specification: name, parameters,
return, ownership, and which tier it falls in.

Deliverable: `dragon/runtime/ABI.md` plus a generator that re-derives it, so it
cannot drift when we rebase onto upstream.

Done when: every symbol is classified core / vendor / graph / multi-GPU, and
the ~30-symbol bring-up subset is named explicitly.

### W2 · Adreno device runtime, bring-up subset
**Blocks:** any kernel on the GPU. **Needs:** W1, D1b.

Implement the bring-up subset over OpenCL first — simpler than Vulkan, and the
Qualcomm OpenCL 3.0 driver is already proven reachable by D1a. Vulkan stays open
as a later option if OpenCL's compiler quality disappoints.

Done when: a hand-written OpenCL kernel is loaded and launched through our
`DeviceContext`, and returns a checked numerical result.

**Watch:** the no-blocking rule from `AsyncRTRuntime.md`. Dispatch thread per
device from the start — retrofitting it later means redoing the completion path.

### W3 · SPIR-V emission from KGEN
**Blocks:** Mojo kernels on Adreno. **Needs:** WINMOJO G6, W1.

Add Adreno targets to `info.mojo` — all **five** edit sites named in
`adding-gpu-targets.md`, missing one fails somewhere unrelated. Add
`AdrenoPlugin` under `std/_plugin/adreno/`. Route codegen to LLVM's SPIR-V
backend, following the handoff pattern of `LLVMIRDowngradePass` rather than
attempting a new backend.

Done when: a trivial Mojo GPU kernel compiles to SPIR-V and runs via W2.

**Watch:** `print` inside a kernel. `amd-printf-lessons-learned.md` is the
record of what that cost on the second vendor; Adreno has no hostcall mechanism
either. Do not put it on the critical path — plan for kernels that cannot print.

### W4 · QNN harness and graph lowering
**Blocks:** the NPU line. **Needs:** D1b only. **Independent of Mojo.**

Build a graph → QNN IR → context binary → execute path. Pin the runtime version:
D1a measured `HTP_QTI_AISW` core 2.34.0 / backend 5.45.0, and context binaries
are version-sensitive.

llama.cpp's Hexagon backend (`ggml-hexagon.dll` + `libggml-htp-v81.so`, MIT,
already on disk) is the nearest readable prior art.

Done when: a small quantised model executes on HTP V81 and beats the CPU on
decode — the bar set by the D0 measurements, not an arbitrary one.

### W5 · Kernel portability pass
**Needs:** W2, W3.

Walk `max/kernels/src`, starting from HIP paths (wave 64) rather than CUDA ones.
Re-derive every tile size against 32 KiB of shared memory. Begin with
`elementwise-ops.md`'s abstraction — the simplest thing that exercises the whole
chain — then matmul.

Done when: elementwise and a naive matmul produce correct results on Adreno.

### W6 · Graph engine
**Needs:** D3. **Shape unknown until then, by design.**

The strategy decision. Candidate A — reimplement the device ABI so Modular's
engine sits on top — is **already eliminated on evidence**: there is no engine
binary for Windows ARM64 to sit on. Remaining: an independent runtime over the
open graph/nn/pipelines layers, or NPU-first with a narrower scope.

## Risk register

| Risk | Likelihood | Impact | Response |
|---|---|---|---|
| Qualcomm's SPIR-V compiler rejects what LLVM emits | medium | high | W2 before W3 — prove dispatch with hand-written kernels first, so a codegen problem stays a codegen problem |
| WINMOJO never reaches G6 | low | high | the entire QNN chain (W4) is independent of Mojo |
| Adreno X1-45 too weak to matter | **medium** | medium | D2 measures it; if so, GPU becomes secondary and NPU-first wins D3 on numbers |
| QNN version drift breaks context binaries | medium | medium | pin 2.34.0/5.45.0, record it in every artifact |
| `print` in kernels blocks progress | medium | low | designate it out of scope for bring-up |
| Kernel tile sizes overflow 32 KiB silently | **high** | medium | re-derive, never copy; assert shared-memory use at comptime |

The two rated most likely — Adreno being underwhelming, and tile sizes
overflowing — are both cheap to detect early and expensive to discover late.
D2 and an early comptime assertion cover them.

## What this plan will not do

- Multi-GPU, peer access, multicast. One integrated GPU.
- CUDA or HIP compatibility shims.
- Training. Inference only.
- Chasing Modular's closed engine. If a strategy needs it, that strategy is out.
- Supporting Snapdragon parts other than this one until this one works. The
  QAIRT bundle carries V73/V75/V79 skels; ignore them.
