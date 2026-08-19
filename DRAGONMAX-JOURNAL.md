# DragonMax port journal

Running record. Newest entry at the bottom. Chat gets short replies; the
detail lives here.

---

## 2026-08-19 — D0 recon, project stood up

Forked from WINMOJO `dde8f83773` (its G3) rather than from Modular, to inherit
the Windows ARM64 build work. Remotes: `winmojo` → local WINMOJO trunk,
`upstream` → modular/modular. No `origin` yet.

### The finding that defines the project

MAX's engine is **closed source**. `max/python/max/_core` holds thirteen `.pyi`
stubs and no implementation. The GPU device runtime is closed too:
`max/mojo/max/gpu/host/device_context.mojo` is ~7,000 lines of `external_call`
into `AsyncRT_DeviceContext_*`, and grepping all of `AsyncRT/**/*.{h,cpp}` for
that prefix returns **nothing** — the open AsyncRT ships `CPUDevice.cpp` and
the async machinery, no accelerator devices.

So the Snapdragon backend cannot be written by editing MAX's runtime. It has to
either satisfy that C ABI from outside or replace the execution layer.

Mitigating: `device_context.mojo` *declares* the whole ABI it calls, so the
surface is fully enumerable from open source. Large, but not a mystery.

### What is open, and the Metal precedent

Open: the Mojo GPU programming model, `info.mojo`'s MLIR target tables, all of
`max/kernels/src`, and the Python graph/nn/pipelines stack.

Counting `api=` tags in `info.mojo`: cuda 19, hip 15, **metal 10**, none 1.
Apple Metal is already a third backend that is tile-based, unified-memory and
non-PTX — architecturally the same shape as Adreno. And
`mojo/stdlib/docs/adding-gpu-targets.md` (19 KB) is a step-by-step guide to
adding a new GPU target, written by Modular. The compile side is well-paved.

### Hardware, measured on this box

Adreno X1-45 via `vulkaninfo` from the driver store: **subgroup size 64**,
32 KiB shared memory per workgroup, 1024 max invocations, fp16/int8/int16 all
supported, integrated (unified memory, no PCIe copy).

Wave-64 matches AMD CDNA, not NVIDIA's 32 — so where `max/kernels` forks by
vendor, the **AMD path is the better starting point**. But 32 KiB of shared
memory is under half of AMD's 64 KiB, so tile sizes lifted from either vendor's
matmul will not fit and must be re-derived.

Everything needed is already installed, no SDK downloads:
- Adreno OpenCL + Vulkan in `qcdx8380.inf_arm64_3555a260d521ff65`
- QAIRT (`QnnHtp.dll`, `QnnHtpV81Stub.dll`, skels) bundled inside GenieX CLI
- llama.cpp's `ggml-hexagon.dll` and `ggml-opencl.dll` — MIT-licensed worked
  examples for both surfaces, sitting on disk

One trap already spotted: **no OpenCL ICD is registered** under
`HKLM\SOFTWARE\Khronos\OpenCL\Vendors`, so the generic `OpenCL.dll` loader
enumerates nothing. Adreno's OpenCL must be loaded from the driver-store path
directly. D1 will confirm.

### The number that should steer everything

Prior measurements on this machine: QAIRT NPU-native decode 35.6 tok/s vs CPU
25.3 vs llama.cpp NPU offload 13.8. **Naive NPU offload loses to the CPU.**
Only an AOT-compiled QNN graph wins, and only by 1.4x.

Therefore the NPU is a *graph compiler target*, not a kernel-dispatch device,
while Adreno is the reverse. Two different mechanisms. A design that treats the
HTP like a GPU will be slower than doing nothing.

### Licensing, recorded not resolved

Repo is Apache-2.0-with-LLVM-exceptions, but the README puts MAX *usage and
distribution* under the separate Modular Community License. WINMOJO avoided
`max/` precisely to stay permissive; DragonMax enters it by definition and
inherits the question for anything distributed. Matters at publication time,
not for local research. Terms to be read before shipping artifacts.

### Next

D1: three probes under `dragon/probe/` — `adreno_cl`, `adreno_vk`, `htp_qnn` —
each proving we can drive the silicon from a native ARM64 process and print a
correct result. No Mojo needed, so this runs in parallel with WINMOJO's G3–G6.

The strategy gate is D3, deliberately placed *after* D2's measurements rather
than guessed at now. Three candidates written up in `DRAGONMAX.md`.
