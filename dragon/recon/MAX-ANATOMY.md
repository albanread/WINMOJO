# What MAX actually is, open vs closed

Determined by reading the tree at `f66d4d5`, not from documentation. This is
the constraint that defines the project, so it is written down first.

## The engine is closed source

`max/python/max/_core` — the graph compiler and execution engine — contains
**only `.pyi` stubs**. Thirteen of them: `engine.pyi`, `graph.pyi`,
`driver.pyi`, `mlrt.pyi`, `dlpack.pyi` and friends. No `.cpp`, no `.py`, no
implementation. The native extension they describe is a prebuilt binary that
is not in the repository and is not built for Windows ARM64 either way.

## The GPU device runtime is also closed

`max/mojo/max/gpu/host/device_context.mojo` is ~7,000 lines, and it is a
*binding*, not an implementation. Every operation is an `external_call` into
symbols named `AsyncRT_DeviceContext_*`, `AsyncRT_DeviceTimer_*`, etc.

The open `AsyncRT/` tree ships the async runtime and **`CPUDevice.cpp` only**.
`grep` for `AsyncRT_DeviceContext_` across all of `AsyncRT/**/*.{h,cpp}`
returns nothing. The CUDA/HIP/Metal device implementations behind those symbols
are not in the repository.

**Consequence: you cannot add a Snapdragon backend by editing MAX's runtime,
because that source does not exist publicly.** Any device backend must either
reimplement the `AsyncRT_DeviceContext_*` C ABI from the outside, or replace
the execution layer entirely.

The one piece of good news: because `device_context.mojo` declares the entire
ABI it calls, the surface a reimplementation would have to satisfy is fully
enumerable from open source. It is large but it is not a mystery.

## What *is* open, and it is a lot

| Component | Path | Nature |
|---|---|---|
| Mojo compiler + stdlib | `mojo/` | Apache-2.0, WINMOJO's scope |
| GPU programming model | `mojo/stdlib/std/gpu/` | device-side intrinsics, Mojo |
| **GPU target tables** | `mojo/stdlib/std/gpu/host/info.mojo` | MLIR targets per arch |
| **Kernel library** | `max/kernels/src/` | matmul, attention, conv, nn — all Mojo |
| Graph API / layers / pipelines | `max/python/max/{graph,nn,pipelines}` | Python |
| Async runtime + CPU device | `AsyncRT/` | C++ |

## Metal is the precedent that matters

`info.mojo` tags every target with an `api=` field. Counting them:

- `cuda` — 19 targets
- `hip` — 15 targets
- **`metal` — 10 targets**
- `none` — 1

Apple Metal is a third, already-shipping backend that is neither CUDA nor HIP:
tile-based, unified-memory, mobile-lineage, non-PTX. That is architecturally
the same shape as Adreno. It proves the target layer generalises beyond the two
desktop vendors, and it gives a concrete diff to imitate.

Better still, `mojo/stdlib/docs/adding-gpu-targets.md` is a 19 KB
step-by-step guide to adding a new GPU target — MLIR triple, `data_layout`
string format, `GPUInfo` alias, `_get_info_from_target` wiring, and a
validation checklist. Modular wrote the instructions for exactly this job.

What the guide covers is the **compile** side: getting Mojo to emit code for a
new architecture. It says nothing about the **run** side, which is the closed
part above. That split — compile-side open, run-side closed — is the shape of
the whole problem.

## Licensing, recorded so later decisions are informed

The repository is Apache-2.0 with LLVM exceptions. But `README.md` adds:
"MAX usage and distribution are licensed under the Modular Community License"
(https://www.modular.com/legal/community).

WINMOJO deliberately stays out of `max/` to keep that port wholly permissive.
DragonMax enters `max/` by definition, so it inherits that question for
anything it distributes. This is a real consideration at distribution time, not
a blocker for local research work. Read the actual terms before publishing
artifacts; nothing here is legal advice.
