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

---

## 2026-08-19 — D1a: all three surfaces answer

`dragon/probe/probe_surfaces.py` — ctypes, no build system, no Mojo. Runs in a
native ARM64 Python 3.12 and asks each vendor runtime what it is.

```
  [ok] Adreno OpenCL
  [ok] Hexagon QNN system
  [ok] Hexagon QNN HTP
```

### Correction: the ICD trap I predicted does not exist

D0 recorded that no OpenCL ICD was registered under
`HKLM\SOFTWARE\Khronos\OpenCL\Vendors`, and inferred the generic loader would
find nothing. **Wrong.** `C:\Windows\System32\OpenCL.dll` enumerates two
platforms perfectly well. Registration lives somewhere other than the key I
checked. `HARDWARE.md` has been corrected.

Going the other way, `OpenCL_adreno.dll` exports *neither* `clGetPlatformIDs`
nor `clIcdGetPlatformIDsKHR`, so it is not usable as a direct loader — the
exact opposite of the D0 guess. Use the system loader.

### The real trap, which fails silently

**Two OpenCL platforms report the same device name.**

| Platform | Device reported | CUs |
|---|---|---|
| `QUALCOMM Snapdragon(TM)` — OpenCL 3.0, build 807.0 | Adreno X1-45 | 3 |
| `OpenCLOn12` — D3D12 translation | Adreno X1-45 | 1 |
| `OpenCLOn12` | Microsoft Basic Render Driver | 1 |

Anything that picks a device by matching "Adreno" in the name can land on
Microsoft's D3D12 translation layer and still look like it succeeded. **Select
by platform, not device name.** The probe now labels both inline so this can't
be misread later.

Also: the QUALCOMM driver reports `CL_DEVICE_MAX_CLOCK_FREQUENCY` as **1 MHz**.
Garbage. Do not use that field. Global memory reads 15 GiB — about half the
unified 31.6 GiB — and local memory 32 KiB, agreeing with the Vulkan numbers.

### NPU versions, measured

| Library | Provider | backendId | API |
|---|---|---|---|
| `QnnHtp.dll` | `HTP_QTI_AISW` | 6 | core 2.34.0, backend 5.45.0 |
| `QnnSystem.dll` | `SYSTEM_QTI_AISW` | 0 | system 1.9.0 |

So the bundled QAIRT is the 2.34 generation. Worth pinning: context binaries are
version-sensitive.

One self-inflicted bug worth recording, because it is the kind that produces
confident nonsense rather than an error. `QnnSystemInterface_t` carries a
*single* `systemApiVersion`, while `QnnInterface_t` carries a `coreApiVersion` +
`backendApiVersion` pair. Reading the system struct with the backend layout
printed `backend=0.860793856.32764` — plausible-looking garbage, no crash, no
error code. Two structs now, and a comment saying why.

That is the [[dolphin-32bit-offsets-rule]] lesson again in a new costume:
a struct layout taken from the wrong header does not fail, it lies.

### Next

D1b — reachability is not execution. Get a checkable numerical result out of
each surface: a real OpenCL kernel on the QUALCOMM platform, a Vulkan compute
dispatch, and a trivial QNN graph on HTP V81.

---

## 2026-08-19 — re-verified the closed-engine claim under challenge

Pushed back on: isn't MAX open, under a community license? Worth re-checking,
and the wording in D0 was sloppy. Two separate questions had been blurred.

**On licensing, the challenge is correct.** MAX is openly licensed. Published
tree is Apache-2.0 with LLVM exceptions; usage and distribution fall under the
Modular Community License, which is permissive for most purposes. Licensing is
*not* what blocks this port, and D0 implied otherwise by lumping them together.

**On source availability, the original finding survives, with better evidence.**

The decisive artifact is `max/python/max/_core/BUILD.bazel`, which names its own
sources:

```python
srcs = ["//max/python/max/_core/internal:_core.cpp"],
deps = ["//max/python/max/_core/internal:AsyncRTPython",
        "//max/python/max/_core/internal/modules"]
```

`max/python/max/_core/internal/` **does not exist in the repo and never appears
in its git history.** `git log --all -- <path>` returns nothing; `git ls-files`
under `_core/` lists `.pyi` and nothing else. The BUILD file is the public
residue of an internal monorepo where that directory does exist. The interface
was published; the implementation was stripped at export.

Same for the device runtime, checked more widely than in D0: `AsyncRT_DeviceContext`
across the **whole tree** in any `.c/.cpp/.h/.hpp/.cc` file returns **zero
hits**. Every hit is `.mojo`, and every one is a declaration —
`device_context.mojo`, `device_graph.mojo`, `_nvidia_cuda.mojo`,
`_amdgpu_hip.mojo`, `_metal.mojo`, `_metal_capture.mojo`. The per-vendor files
turn out to be bindings as well; `_nvidia_cuda.mojo` is five `external_call`s
and some opaque structs, not a CUDA driver.

And the fallback of using a prebuilt engine does not exist here either:
upstream `MODULE.bazel` at `f66d4d5` mentions Windows **zero** times. Every
Windows reference in this tree is WINMOJO's own G2 work.

**Corrected framing, now used in the docs: source-available, not
source-complete.** The unpublished parts happen to be exactly the two a new
hardware backend would need. The ladder is unchanged.

---

## 2026-08-19 — design docs, and a large correction in our favour

Went looking for Modular's own design docs, and found that the D0 picture was
**too pessimistic about the compile side**. Three findings, each of which moves
work from impossible to merely hard.

### KGEN — the Mojo compiler — is open source

`KGEN/` holds **326 `.cpp`, 234 `.h`, 66 `.td`**. D0 implied the compiler was
out of reach. It is not.

Concretely, `stdlib_plugin` is resolved in `KGEN/lib/KGENDialect/KGENAttrs.cpp`
and treated as an **opaque string** via `getStdlibPlugin()` — no closed enum, no
validation against a fixed vendor list. The Mojo-side registry
(`std/_plugin/selector.mojo`) matches that string at compile time, and
`std/_plugin/` already contains `cuda/`, `hip/`, `metal/`.

Scope check so nobody over-reads this: `MetalPlugin` is **twelve lines** with
every hook left at default. The hooks are `exp`, `tanh`, address-space lookup,
`print` emission, `abort`, assertion messages — stdlib behaviour, *not* codegen.
An `adreno` plugin is an afternoon. It is not the port.

### How Modular targets a GPU whose backend they do not have

The best thing in the tree, and it is in no design doc.

Apple's AIR is not an upstream LLVM target, and there is no AIR backend in the
open KGEN. So what makes `triple = "air64-apple-macosx"` work?

- `KGEN/lib/Compiler/ObjectCompiler/LLVM/Transforms/LLVMIRDowngradePass.cpp` —
  *"Transform LLVM IR for backend compilation that takes older version of LLVM
  IR."*
- `Bitcode/17/`, `Bitcode/19/`, `Bitcode/21/` — vendored, version-pinned
  bitcode writers.

**They do not write backends for closed GPUs. They emit something the vendor's
compiler already accepts.** For Adreno that is SPIR-V — a documented standard
with an in-tree LLVM backend since 18, consumed by `qcvkarm64xcompiler.dll` and
`qcclarm64xcompiler.dll`, both already installed. Strictly easier than what they
did for Metal, since we hand off at a published format rather than a guessed
bitcode version.

### The device ABI is exactly 109 symbols, and most are optional

Enumerated properly this time (the first grep missed multi-line `external_call`
and undercounted by 5x). Across `max/mojo/max/gpu/host/*.mojo`:

| Tier | Count | For Adreno |
|---|---|---|
| Core — lifecycle, buffers, transfers, streams, kernels, events | ~68 | must implement |
| Vendor escape hatches — `cuda_context`, `metal_device`, `cuda_tensorMapEncode*` | 13 | omit |
| Graph capture — `DeviceGraphBuilder_*` (15), `DeviceGraph_*` (4), +1 | 20 | stub unsupported |
| Multi-GPU / peer / multicast | 8 | stub — one GPU |

Bring-up subset is roughly **30 symbols**: create/release, one buffer type,
H2D/D2H, one stream, `loadFunction` + `enqueueFunctionDirect`, `synchronize`.
A far smaller problem than "109 unpublished functions" first suggested.

### Candidate A is dead

D3's option A — reimplement the ABI so Modular's own engine sits on top — is
**eliminated on evidence, not preference**. Upstream `MODULE.bazel` mentions
Windows **zero** times; there is no engine binary for Windows ARM64 to sit on.
D3 is now a two-way choice between B (independent runtime) and C (NPU-first),
and D2's numbers decide it.

### A constraint worth writing down before it bites

`AsyncRT/docs/AsyncRTRuntime.md`: **"The design assumes that work items never
block."** QNN's `graphExecute` is synchronous and long; OpenCL's `clFinish`
blocks. Neither can run on a `WorkQueue` worker without stalling a core the
runtime thinks is busy. We need a dispatch thread per device from the start,
signalling back through `AsyncValue`. Retrofitting that means redoing the whole
completion path, and the failure mode is bad scaling rather than a crash — the
kind of bug that hides.

### Written

- `dragon/design/ARCHITECTURE.md` — the stack with both gaps marked, codegen
  route per surface, the ABI tiering, what we add and where.
- `dragon/design/PORTING-PLAN.md` — support matrix (honest about the NPU int8
  cell being the point), dependency graph, work breakdown W1–W6, risk register,
  explicit non-goals.
- `dragon/design/UPSTREAM-DOCS.md` — Modular's docs tiered by usefulness.
  Tier 1 is three items; the Blackwell `wgmma` material is a dead end for us.

`MAX-ANATOMY.md` corrected — it understated how much is open.

### Next

W1 (extract the ABI spec) needs nothing and can start now. So can W4's QNN
harness, which never needs `mojo.exe`. D1b still wants a checked numeric result
out of each surface.

---

## 2026-08-19 — W1 done, and D1b runs a real kernel on the Adreno

### W1 — the ABI spec is generated, not transcribed

`dragon/runtime/extract_abi.py` walks the bindings and emits
`dragon/runtime/ABI.md`. **109 symbols, 94 of them (86%) with the real C
prototype** recovered from the comment above each `external_call`.

First attempt recovered only 26. The bug: the comment is not always on the line
directly above, because calls are usually wrapped —

```mojo
# const char *AsyncRT_DeviceContext_hip_device(hipDevice_t *result, ...)
_checked(
    external_call["AsyncRT_DeviceContext_hip_device", _CString[]](
```

— so a bare `_checked(` sits between comment and call. Scanning back over
intervening code, and accepting a comment block only when it *names the symbol*,
took it to 94. The name check is what makes the wider scan safe.

Generated rather than hand-written on purpose: 109 hand transcriptions is 109
chances at an error that only shows up as a wrong-arguments crash in a foreign
process. `--check` fails when stale, so a rebase that changes the interface is
reported rather than silently absorbed.

Tiers came out core 68 / graph 19 / vendor 14 / multigpu 8. All **33** hand-picked
bring-up symbols verified present in the bindings.

**Three structural findings, none of them in any Modular document:**

1. `const char *AsyncRT_DeviceContext_create(const DeviceContext **result,
   const char *api, int id)` — `api` is a **plain runtime string**
   (`"cpu"`, `"cuda"`, `"hip"`, `"metal"`), not an enum, not a compile-time
   parameter. The device runtime is a string-dispatched factory, and since we
   implement it, we own the dispatch.
2. `"cpu"` goes through the same interface, so AsyncRT's **published**
   `CPUDevice` is a working reference for the ABI's shape.
3. **77 of 109 calls return `const char *`**: null is success, non-null is an
   error message the *caller* owns and must release with
   `AsyncRT_DeviceContext_strfree`. Traced through `_checked` →
   `_raise_checked_impl` → `_string_from_owned_charptr`. Get the ownership rule
   wrong and it leaks on every error path.

### D1b — a real kernel, verified

`dragon/probe/probe_opencl_exec.py`: saxpy over 4096 floats on the QUALCOMM
platform, **every element checked against the host**. Qualcomm's OpenCL compiler
accepted the source; context, buffers, H2D, launch, D2H and `clFinish` all work.
Deliberately the same operations as the ABI bring-up subset, so what it learns
transfers straight to `dragon/runtime/`.

### The wave width is not a device constant

Vulkan said `subgroupSize = 64`. OpenCL disagreed, so I measured three kernels:

| kernel | max WG | preferred multiple |
|---|---|---|
| `saxpy` | 1024 | **128** |
| `wave_probe` | 1024 | **64** |
| `reg_heavy` | 1024 | **128** |

**Established: the preferred multiple varies by kernel on the same device.**
That is unlike NVIDIA's fixed 32 and AMD CDNA's fixed 64. Query it per kernel
after compilation; never hardcode it, and never derive it from Vulkan's
`subgroupSize`.

**Not established: why.** Register pressure was the hypothesis, and I wrote
`reg_heavy` specifically to test it — 64 live floats in a dependent chain. The
data contradicts the simple form of it: `reg_heavy` reports the same 128 as
trivial `saxpy`, while the even more trivial `wave_probe` reports 64. Cause
unknown. Recorded as unknown rather than guessed at.

This retires the "Adreno is wave-64, use the HIP paths" rule from
`ARCHITECTURE.md` in its confident form. The HIP paths are still the better
starting point — 64 divides both observed widths — but "Adreno is wave-64" is
not a fact to build on. Both design docs corrected.

Also worth noting for later: the Qualcomm driver reports `CL_DEVICE_MAX_COMPUTE_UNITS`
as 3 and `MAX_CLOCK_FREQUENCY` as 1 MHz. The clock is garbage (already known);
3 CUs is plausible for an X1-45 but should not be trusted for occupancy maths
until something independent confirms it.

### Next

D1b's remaining half: a trivial graph on HTP V81 through QNN. That is also the
start of W4, and it needs no `mojo.exe`.

---

## 2026-08-19 — QAIRT SDK obtained; one API covers NPU **and** GPU

### Where the SDK came from

Qualcomm's own Windows-on-Snapdragon repo, [quic/wos-ai], has
`Scripts/qnn_setup.ps1`, which downloads QAIRT from a **direct public URL with
no account and no token**:

```
https://apigwx-aws.qualcomm.com/qsc/public/v1/api/download/software/sdks/
Qualcomm_AI_Runtime_Community/All/2.42.0.251225/v2.42.0.251225.zip
```

1,543,955,191 bytes (1.44 GB), 3.48 GB extracted, 10,910 entries. Installed to
`C:\Qualcomm\AIStack\qairt\2.42.0.251225`, matching Qualcomm's own convention;
`QNN_SDK_ROOT` persisted to the user environment.

Practical note: **`HEAD` on that URL returns 403 while `GET` works.** A ranged
`GET` (206) is the way to check size without pulling the whole file.

### The finding that changes the architecture

QAIRT ships **CPU, GPU and HTP backends for `aarch64-windows-msvc`, behind one
interface**. All five load and answer in a native ARM64 process:

| DLL | Provider | id | backend API |
|---|---|---|---|
| `QnnCpu.dll` | `CPU_QTI_AISW` | 3 | 1.1.0 |
| `QnnGpu.dll` | `GPU_QTI_AISW` | 4 | 3.12.0 |
| `QnnHtp.dll` | `HTP_QTI_AISW` | 6 | 5.41.0 |
| `QnnIr.dll` | `IR_QTI_AISW` | 9 | 0.1.0 |
| `QnnSaver.dll` | `SAVER_QTI_AISW` | 2 | 1.1.0 |

**`QnnGpu` was not in the GenieX bundle** — it is new capability, and it is
exactly what the dual NPU+GPU goal needs. The original design had a bespoke
OpenCL device runtime for the GPU *plus* a separate QNN path for the NPU. One
QNN execution layer can cover both, and the CPU as well. Qualcomm already wrote
it for this platform triple.

Unproven, and not to be assumed: that each backend actually *builds and runs* a
graph; how `QnnGpu`'s graph-at-a-time model compares with the **41.9 GFLOP/s**
our own OpenCL kernel hit in D2; and how op coverage differs per backend. A
graph API could easily be worse than direct dispatch for GPU compute. D2 is the
yardstick for finding out.

### Direction corrected

An earlier draft of `PORTING-PLAN.md` over-rotated to "NPU first" on a partial
reading. The actual direction is **NPU and GPU, both first-class** — the NPU at
45 TOPS for small models, the Adreno at 3.37x the CPU. Both design docs fixed.
This lands nearer candidate **B** than C, and the QAIRT finding makes B much
cheaper than it looked.

### Two version traps

**1. The package number is not the API version.** Package `2.42.0.251225`
declares `QNN_API_VERSION 2.32.0` in `QnnCommon.h`. The GenieX bundle reports
core **2.34.0** — so the older-looking bundle is the *newer* API. Build against
the SDK headers, run against the SDK's own DLLs, keep the pair matched.

**2. I guessed the backend-id enum and got it wrong.** Written from memory as
`{1: CPU, 2: GPU, 3: DSP, 4: HTA, 5: SAVER, 6: HTP}`, it was shifted by one and
mislabelled every backend while looking entirely reasonable — CPU printed as
"DSP", GPU as "HTA". The header says
`NULL 0, REFERENCE 1, SAVER 2, CPU 3, GPU 4, DSP 5, HTP 6`. The raw ids in the
probe output were right all along; only my map was wrong.

Third time this shape of error has appeared in this project
(QnnSystemInterface layout, the OpenCL ICD guess, now this). **We have the
headers now — there is no longer any excuse for guessing at a constant.**

### Next

W4.0: find the real model-size ceiling on the HTP. The D0 measurement of
`~5 GB` came from llama.cpp's ggml-hexagon backend; whether that limit belongs
to the HTP, its driver, or that backend is unknown, and it bounds the whole NPU
line. With the SDK in hand it is cheap to answer, and `bin/` ships
`qnn-net-run` and the converters to answer it with.

---

## 2026-08-19 — capability tests: GPU and NPU both execute

Goal was narrow: prove the surfaces work at all, not benchmark them. Full
report in `dragon/probe/CAPABILITIES.md`.

| Surface | Loads | Executes |
|---|---|---|
| Adreno via our own OpenCL | yes | **yes** — saxpy exact, matmul 41.9 GFLOP/s exact |
| Adreno via `QnnGpu` | yes | **yes** — vendor unit test passed |
| Hexagon via `QnnHtp` | yes | **yes** — vendor unit test passed |
| Oryon via `QnnCpu` | yes | provider negotiates; tool has no CPU unit test |
| Full model graph | — | **blocked** on a toolchain gap, below |

### The Hexagon failure was a path, not the hardware

First DSP run failed outright — `-6 . Error while executing the sum function`,
followed by advice about `testsig` and unsigned images. That advice is a red
herring. The real cause was the second line: `ADSP_LIBRARY_PATH` was unset, so
the DSP could not find its skels. Pointing it at
`lib\hexagon-v81\unsigned` turned the same command into
**"Unit Test on the backend DSP: Passed."**

Two oddities logged without explanation, because guessing is how this project
keeps getting caught out: the tool loads `QnnHtpV73CalculatorStub.dll` and
reports *"Hexagon Architecture V73"* on V81 silicon, yet passes against V81
skels. And `DSP_INFO UNSUPPORTED_KEY: 49/50` precedes every run harmlessly.
**Do not read that "V73" as a hardware fact.**

### QnnGpu is OpenCL underneath

The validator's GPU run found `OpenCL.dll` and resolved Qualcomm extensions —
including `clNewRecordingQCOM` / `clEnqueueRecordingQCOM`, a command
record-and-replay facility that looks directly useful for a dispatch runtime
later. It reported *"OpenCL 3.0 Qualcomm(R) Adreno(TM) X1-45 GPU"* and passed a
vector-addition unit test.

That means **QnnGpu takes the same OpenCL path our D2 kernel takes**, so D2's
41.9 GFLOP/s is a fair yardstick to hold it against rather than an unrelated
number. Good: the comparison we wanted is apples to apples.

### Blocked, and precisely why

`qnn-net-run` needs a compiled model library, and building the SDK's own
example fails in three diagnosed steps:

1. `qnn-model-lib-generator` hardcodes `cmake -T ClangCL`; this VS 18 install
   has no ClangCL component → `MSB8020`.
2. Forcing the default MSVC toolset configures fine, then fails to compile.
   `/std:c++20` clears the designated-initializer error (`C7555`) but not
   `C4576`/`C2059`, because the generated code uses `(Qnn_Tensor_t){...}` — a
   **C compound literal**, a Clang/GCC extension that is not valid ISO C++ at
   any standard level.
3. No clang exists anywhere on this machine.

**Qualcomm's generated model code requires Clang; there is no MSVC-only path.**
That is a toolchain gap, not a limitation of the silicon, and it does not
affect anything already proven above. Fix is a user action — VS Installer's
*C++ Clang tools for Windows*, or an LLVM ARM64 install.

Noted for the record: the generator writes its staging tree to `tmp_<pid>` in
the **current working directory**, not the `-o` output dir, and leaves it
behind. Two of them landed in `C:\projects`; both removed.

### Next

Once clang is available: build the example model and run `qnn-net-run` across
`QnnCpu` / `QnnGpu` / `QnnHtp` for a like-for-like three-way comparison, then
W4.0 — the HTP model-size ceiling.

---

## 2026-08-19 — full model graph runs on CPU and NPU; QnnGpu does not

Clang was already on the box after all — WINMOJO's bazel toolchain downloads
**clang 22.1.4, target `aarch64-pc-windows-msvc`**, under
`_bazel_alban\cache\repos\...\bin`. My earlier search missed it because I looked
at install locations and PATH rather than the bazel repo cache. It is not
registered anywhere, so `Get-Command` and the registry both come up empty.

With that, built the SDK's own InceptionV3 conv+relu example into an ARM64 DLL
and ran it through `qnn-net-run` on each backend:

| Backend | Result | Wall time |
|---|---|---|
| `QnnCpu` | **Finished Executing Graphs**, 2 result sets | 298 ms |
| `QnnHtp` | **Finished Executing Graphs**, 2 result sets | 1377 ms (incl. prepare) |
| `QnnGpu` | **Graph Execution failure** | 313 ms |

**A real graph executes on the Hexagon NPU.** That is the headline; the NPU line
is unblocked.

### QnnGpu is broken here, and it matters for the design

```
CL ERROR: (-59) CL_INVALID_OPERATION
GPU ERROR: GPU_ERROR_OPENCL(10014) - OpenCL recorable command queue error
```

That is the `clNewRecordingQCOM` / `clEnqueueRecordingQCOM` path the platform
validator reported resolving earlier. QnnGpu drives the Adreno through OpenCL
command record-and-replay, and **that path fails on this driver.**

Careful about what this is not. The Adreno is fine: our own direct OpenCL
dispatch runs saxpy and a tiled matmul correctly at 41.9 GFLOP/s, and QnnGpu's
own vector-add unit test passes. Only the recorded-queue path fails, and only
on a real graph. The unit test passing while the real workload fails is exactly
why "loads" and "executes" are tracked as separate columns.

The header offers a way out — `QnnGpuGraph.h` declares
`uint8_t disableQueueRecording` — but it is unreachable from the tool, and the
two layers contradict each other while saying so:

- top-level `disable_queue_recording` → schema rejects it, "depends on graph_names"
- moved beside `"graph_names": ["convReluModel"]` →
  `ERROR: Unsupported key: graphs/0/disable_queue_recording`

The JSON schema validates a key the extension DLL then refuses. **The toggle is
only reachable programmatically**, via `QnnGpuGraph_CustomConfig_t`.

**Design consequence: do not build the GPU path on QnnGpu.** Own the OpenCL
dispatch. QNN earns its place on the NPU, not the GPU. That reverses the
optimistic reading from the morning — one API spanning all three is *available*
but not *usable* for the GPU, and D2's 41.9 GFLOP/s is the reason we can say so
with numbers rather than shrugging.

### Four traps in building a model library

Recorded in `dragon/qnn/build_model_lib.ps1`, which automates the lot. None of
them produces an honest error:

1. `qnn-model-lib-generator` hardcodes `cmake -T ClangCL`; stock VS 18 has no
   ClangCL component → `MSB8020`.
2. Generated code uses `(Qnn_Tensor_t){...}`, a **C compound literal** — Clang
   extension, invalid ISO C++ at any level. `/std:c++20` clears `C7555` but
   never `C4576`/`C2059`. Clang is mandatory.
3. The generated `CMakeLists.txt` branches on `CMAKE_GENERATOR_PLATFORM`, which
   Ninja refuses. Branch on which `obj/` dir exists instead.
4. **`set VAR=value && next` in cmd captures the space before `&&`.**
   `QNN_SDK_ROOT` became `...251225 `, the include path `...251225 \include\QNN`,
   and it surfaced as `fatal error: 'QnnInterface.h' file not found` — a quoting
   bug dressed as a missing header. Use `set "VAR=value"`.

### Next

W4.0, now genuinely unblocked: find the HTP's real model-size ceiling. Then a
like-for-like CPU-vs-HTP comparison on something bigger than a two-op graph.

---

## 2026-08-19 — W4.0: our own model runs on the NPU, and the DSP wedges

### The pipeline is ours now

`dragon/qnn/gen_matmul_model.py` emits a QNN model of controllable weight size —
a chain of `[1,D] x [D,D]` MatMul layers, `.cpp` plus a `.bin` tar of raw
tensors in the SDK's own converter format. `build_model_lib.ps1` turns it into
an ARM64 DLL. So we can now generate, build and run arbitrary graphs on the
Hexagon NPU without going through anyone's converter.

First real result, 4 MiB of weights (dim 512, 4 layers):

| Backend | Result |
|---|---|
| `QnnCpu` | Finished Executing Graphs |
| `QnnHtp` | **Finished Executing Graphs** |

And they agree: **max |cpu − htp| = 0.0348 against a max magnitude of 56.1, so
0.062% relative.** The HTP is computing at reduced internal precision, as
expected, and getting the right answer. That is the first end-to-end numerical
validation of our own workload on the NPU.

One generator bug worth noting: weights were originally built with a
`struct.pack` per element, which at dim=4096 is 16.7M calls per layer and
dominates everything. Now tiles a 17-float period instead — 128 MiB in 0.31 s.

### Then the ceiling test, and a lesson

Scaled to 128 MiB (dim 2048, 8 layers). CPU ran it in 783 ms. HTP failed at
41 ms:

```
<E> DspTransport.openSession qnn_open failed, 0x80000406, prio 100
```

The obvious conclusion is "the HTP tops out somewhere under 128 MiB". **That
conclusion would have been wrong.** Re-ran the 4 MiB model that had passed
minutes earlier as a control — and it failed identically.

**The DSP session layer wedges.** Once wedged, every HTP run fails the same way
at session open, regardless of size. What it is not:

- not the device — Windows reports the Hexagon NPU with status **OK**
- not the driver stack broadly — `QnnCpu` keeps working throughout
- not a stray process — nothing is holding a session
- not transient — still failing after a 20 s settle

This is the pre-HND behaviour from the `geniex-gemma4-npu-setup` notes, which
the driver update was believed to have fixed. It has not been, for this path.

**So the 128 MiB number measures nothing.** Whether that model exceeded a real
limit, or merely triggered the wedge, is unknown. It failed during *session
open*, before weights would plausibly have moved, which hints at a
session-sizing rejection — but that is a hypothesis, not a measurement, and it
stays labelled as one.

### The rule, now enforced in code

**Every HTP probe is followed by a control run of a known-good small model.**
Control passes → the failure was real. Control fails → the DSP is wedged and
everything after the first failure is void.

`dragon/qnn/htp_ceiling_sweep.ps1` bakes this in: it builds a small control
model, refuses to start if the DSP is already wedged, and after any HTP failure
re-runs the control to label the result `CEILING` or `WEDGED` before deciding
whether to continue.

This is the same shape as every other trap in this project — a plausible number
that is actually an artefact. The difference is that this one would have set
the NPU roadmap around a fiction, so the control discipline is worth the cost.

### Blocked on a reboot

The DSP will not recover without one. Recovery might also come from disabling
and re-enabling the NPU in Device Manager, but that is a system change and the
user's call, not mine.

After a reboot: run `htp_ceiling_sweep.ps1` and get the real number.

---

## 2026-08-19 — D3 resolved, and the MAX device ABI runs on Adreno

### The decision

**Objective set by the owner: WINMOJO's Mojo should drive our accelerated
Snapdragon features, through a MAX-compatible interface, used the standard Mojo
way.** That resolves D3, and it is a better-scoped target than "port MAX" —
the seam is `device_context.mojo`, which is open, and implementing the symbols
it calls makes `DeviceContext`, `DeviceBuffer` and `enqueue_function` work
unchanged.

### W2 — the runtime works

`dragon/runtime/dragonrt.cpp` implements the 33-symbol bring-up subset over
OpenCL. `test_dragonrt.c` drives it through `GetProcAddress` only, with no
DragonMax header, so it exercises the ABI exactly as Mojo will find it.

```
all bring-up exports resolved
  device : Qualcomm(R) Adreno(TM) X1-45 GPU
  api    : adreno   id=0        ver=300  total=16163 MiB  maxAlloc=1024 MiB
  [ok] createBuffer x/y/out, HtoD, loadFunction(saxpy),
       enqueueFunctionDirect, synchronize, DtoH
  [ok] all 4096 elements correct
ALL PASS
```

Three things worth keeping from building it:

- `loadFunction` sniffs the **SPIR-V magic number** `0x07230203` and routes to
  `clCreateProgramWithIL`, otherwise treats the blob as OpenCL C. The source
  path exists so the runtime is testable *before* KGEN emits SPIR-V. That
  ordering means a codegen bug and a runtime bug can never be the same
  investigation.
- Launch dims are `uint32_t` because the bindings say so: Mojo has two launch
  paths and if they disagree (i64 vs i32) a module composing both fails to
  legalize.
- Mojo speaks a CUDA-shaped grid-of-blocks; OpenCL wants global work-items. The
  launch multiplies through.

### W3 — Adreno is now a Mojo target, on paper

Six edit sites, not the five `adding-gpu-targets.md` documents:

1. `QualcommAdrenoFamily` — wave 64, **32 KiB** shared memory
2. `_get_adreno_x1_target()` — triple `spirv64-unknown-unknown`,
   `stdlib_plugin = "adreno"`
3. `AdrenoX1` GPUInfo alias, `api="adreno"`, `sm_count=3`
4. `"adreno-x1"` in the `_all_targets` canonical list
5. `GPUInfo.target()` dispatch
6. the arch-string → GPUInfo mapping in `_get_info_from_target`

Plus `std/_plugin/adreno/` and its registration in `_overlay.mojo`'s
`STD_PLUGINS`.

**The data layout was emitted by LLVM, not written by hand** —
`clang -target spirv64-unknown-unknown -S -emit-llvm` gives
`e-i64:64-v16:16-...-n8:16:32:64-G1`, exactly the "query LLVM/Clang" method the
guide recommends. Given how many guessed constants have bitten this project,
that mattered.

The family's `warp_size=64` carries a caveat in its own docstring: Vulkan says
64, but OpenCL's preferred multiple comes back per-kernel as 64 **or** 128 on
this device. It is not a device constant, and kernels that care must query.

### The gap that stops this compiling today

`info.mojo` carries a SYNC comment: the canonical target list must match
"the TargetTraits accelerator tables in `KGEN/lib/Target/`". Those tables are
**not in the published KGEN** — `grep` for `apple-m4` or `gfx942` across all of
`KGEN/**/*.{cpp,h,td}` finds only help text in `TargetOptions.td`.
`TargetTraits.h` declares the interface (`supportedAcceleratorArchs()` returning
`ArrayRef<AcceleratorArch>`), but the per-target subclasses that populate it are
absent.

So the stdlib now describes Adreno correctly, and the compiler will still reject
`--target-accelerator=adreno-x1` until that table is reachable. **That is the
next real obstacle, and it is a fresh instance of the same compile-side-open /
run-side-closed split — except this time it is the accelerator registry.**

Worth being precise: this does not block the runtime, which is done and tested.
It blocks *Mojo-authored* kernels reaching it. Hand-written OpenCL C already
runs through the same ABI today.

### Next

Find where `supportedAcceleratorArchs()` is populated — a generated file, an
unpublished subclass, or something reachable from `MAttrs.td`. That determines
whether Mojo can be taught a new accelerator at all, and it is the single most
important open question for this objective.
