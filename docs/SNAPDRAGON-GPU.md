# Snapdragon GPU integration: the WINMOJO-side design

DragonMax declared HANDOFF on 2026-08-19: a complete Adreno GPU line —
SPIR-V backend trio in KGEN, stdlib target entries, a device runtime proven
on hardware — with a six-checkbox runbook
([`INTEGRATEME.md`](../../DRAGONMAX/INTEGRATEME.md)) whose finish line is
standard Mojo saxpy printing PASS on the X1-45. The Julia demo reached the
Adreno by handing HLSL to Direct3D; this is the honest version: **Mojo
compiles the kernel**, and the same `DeviceContext` code people write for
NVIDIA runs on this machine's silicon.

The runbook was written against WINMOJO at `dde8f83` (our G3). We are ~100
commits past that, and everything below is the reconciliation: what transfers
unchanged, what has drifted, and the decisions that are ours to make. This
document is the design; the runbook remains the execution script wherever the
two agree.

## What we verified before designing

Merge surface, checked against today's tree:

- **No conflicts expected.** We have zero commits touching
  `mojo/stdlib/std/gpu/`; their KGEN additions are three new `Target/Spirv/`
  directories; they made no BUILD edits; our sqlite/toolchain work touches
  none of their files. `.gitignore` line 69 has the bare `target/` rule their
  re-include hunk defuses — keep the hunk, exactly as the runbook warns.
- **The glob-and-alwayslink assumption is *three-quarters* true.**
  `lib/Target/**` (rule at KGEN/BUILD.bazel:1102, alwayslink) and
  `lib/KGENToLLVM/Target/**` (1130, alwayslink) will absorb their files and
  keep the self-registration alive. But the ObjectCompiler glob at :1341
  belongs to a rule whose alwayslink status must be confirmed — the Host
  backend got its own `alwayslink = True` rule (:1302) precisely because the
  parent may strip registrars. **Expect bounce-back #3**, and the fix the
  runbook names: a `:SpirvBackend` rule shaped like `:HostBackend`. That is
  one BUILD edit, contradicting the runbook's "zero," and it is fine.
- **`dragonrt.dll` dynamically loads `OpenCL.dll`** (no import lib needed)
  and carries ~10 allocation sites. Whether any allocation crosses the ABI
  is not audited; our CRT doctrine makes the question moot — see D2.

## The deltas the runbook cannot know

1. **The acceptance test does not compile in our dialect.**
   `adreno_saxpy.mojo` uses `fn` (a hard error here) and imports
   `from max.gpu.host` (the `max.*` namespace is out of scope and unbuilt;
   our tree's GPU API is `std.gpu.host`). The runbook anticipated this —
   "the *shape* is the contract, not the spellings" — so the port is ours:
   `fn`→`def`, `max.gpu.host`→`std.gpu.host`, and whatever
   [DIALECT-NOTES.md](DIALECT-NOTES.md) says when it fights back. The ported
   test lands in `examples/win32/` beside the others, plus a Bazel
   `mojo_test` gated on the existing `//:has_gpu` constraint so the CPU
   census never waits on a GPU.

2. **Adding `"SPIRV"` to `BACKENDS` re-keys the LLVM build.** The backends
   list feeds `llvm_configure`; changing it invalidates the LLVM action
   graph — roughly 8,000 actions, the never-build-LLVM-again journal entry's
   whole subject. The disk cache will absorb the unchanged majority, but
   budget **an hour-class rebuild once**, and do the merge when that is
   acceptable. This is also bounce-back #4's home: the SPIRV backend has
   never been built by this toolchain on this host. Highest-risk single item
   in the plan.

3. **Their runtime build violates our CRT invariant.** The runbook builds
   `dragonrt.dll` with `cl /LD` and no `/MD`, which defaults to the static
   CRT. This port's hardest bug established the law: every module in the
   process shares one ucrtbase heap, no exceptions
   (`-fms-runtime-lib=dll`). Even if no allocation crosses the ABI today,
   we do not ship a module that breaks the invariant. Decision D2.

4. **Our linking story is richer than the one they wrote against.** Since
   G3 we grew: `mojo build` linking via `lld-link` with explicit inputs
   (the machine-type and oldnames fixes in `mojo-build.cpp`), the
   rules_mojo patch materializing dependency DLLs beside test binaries,
   `Win32Module` for process-lifetime DLL loading, and a toolchain-input
   pattern (winkb) for shipping files beside the compiler. All four slot
   directly into their Step 5.

## Decisions

**D1 — take the merge, not cherry-picks.** `git remote add dragonmax
C:/projects/DRAGONMAX && git fetch && git merge dragonmax/main`. The
conflict surface is near-nil, the commits are ordered, and a remote keeps
future DragonMax fixes one fetch away. Their `dragon/` tree rides along
off the build path; harmless, and the NPU line will want it later.

**D2 — `dragonrt` becomes a first-class Bazel target.** A
`modular_shared_library` beside `KGENCompilerRTShared`, built by the
hermetic clang with the dynamic CRT, replacing the `cl /LD` recipe. Its
smoke test (`test_dragonrt`) becomes a `cc_test` tagged `gpu`. This kills
the CRT question, gives the DLL our toolchain's provenance, and lets the
existing DLL-materialization machinery put it beside test binaries. The
source is 612 lines of C++ with no build-time deps (OpenCL is
`LoadLibraryA`'d), so the port is a BUILD file, not a porting job.

**D3 — linking is Option A through `mojo-build.cpp`, with B as the test
fallback.** The import library joins the Windows link block in
`mojo-build.cpp` exactly as `oldnames.lib` did — unconditionally; an
unreferenced import lib costs nothing, and conditioning the link on the
target would put policy in two places. `dragonrt.dll` ships beside
`mojo.exe` the way `KGENCompilerRTShared.dll` already does. Option B
(`Win32Module("dragonrt.dll")` before first use) stays documented for any
context where the import lib is awkward — we built that mechanism this
week and it is exactly delay-load.

**D4 — the acceptance test is ported, not patched around.** The dialect
port of `adreno_saxpy.mojo` is small, ours, and becomes the repo's example
of standard Mojo GPU code (`examples/win32/adreno_saxpy.mojo`). PASS on
hardware is the finish line, per the HANDOFF contract, and the human
camera rule applies: the number check *is* the camera here — every element
verified against the host.

**D5 — the NPU line is explicitly out of this design.** DragonMax's own
measurements say the Hexagon pays off only as an AOT graph target
(35.6 tok/s NPU-native vs 13.8 offloaded); that is a graph-compiler
integration, not a device backend, and it continues in DragonMax as W4.
Nothing here forecloses it; `dragon/` merges in regardless.

## The ladder

House rules: each gate has evidence, the census stays green, journal over
chat.

| Gate | Deliverable | Evidence |
|---|---|---|
| **SG0** | Merge landed; `.gitignore` hunk and `BACKENDS` line intact; tree still builds *without* the SPIRV rebuild being wasted — do SG0+SG1 in one sitting | `git log` shows dragonmax commits; `bazelw build //KGEN/tools/mojo:mojo` green |
| **SG1** | LLVM+SPIRV builds; KGEN's Spirv trio compiles (bounce-backs 1–3 burned down; `:SpirvBackend` alwayslink rule if needed) | full build green; census unchanged vs pre-merge |
| **SG2** | Registration + codegen: accelerator listed, SPIR-V emitted | `--print-supported-accelerators` shows Adreno; `--emit=asm` on the ported test yields `OpEntryPoint` |
| **SG3** | `dragonrt` under Bazel (D2), linked (D3); runtime smoke passes | `test_dragonrt` PASS as a bazel test |
| **SG4** | **The finish line**: ported saxpy builds via `mojo build`, runs on the X1-45 | `PASS: all 4096 elements correct on Qualcomm(R) Adreno(TM) X1-45 GPU` |

SG2 needs no GPU and no runtime; SG3 needs no compiler. They parallelize if
SG1 drags.

## Risk register

| Risk | Standing | Mitigation |
|---|---|---|
| SPIRV backend fails to build here (bounce-back 4) | **highest**; unproven toolchain/target combo | triage in `llvm_project.bzl`; DragonMax pre-triaged; same-day contract |
| The three Spirv sources hit API drift (bounce-backs 1–2) | expected, mechanical | fixes are named in the runbook; re-mirror from our tree |
| ObjectCompiler glob lacks alwayslink (bounce-back 3) | **likely**, verified plausible at :1341 | the `:HostBackend`-shaped rule; one BUILD edit |
| Dialect drift inside `DeviceContext`/stdlib GPU path deeper than the test | unknown until SG2 | our dialect notes + the stdlib-is-the-reference rule |
| `enqueue_*` API shape moved since fork | anticipated by handoff | port the call sites; shape is the contract |
| CRT mismatch via their cl recipe | eliminated by D2 | bazel build with `-fms-runtime-lib=dll` |
| Launch-dim widening / `.spv` "fixes" / warp_size assumptions | self-inflicted only | the runbook's do-not-improve list is law; copy it into the PR description |
| Census regression from merged stdlib edits | low; six sites in `info.mojo`, no overlap | SG1 evidence includes census diff |

## What this buys, said plainly

The Julia demo proved the *window*; this proves the *language*. After SG4,
the README's irony section needs a new paragraph: the machine Mojo does not
support runs Mojo kernels on its GPU, compiled by Mojo, launched by
`DeviceContext`, with no vendor SDK in the build and one driver boundary —
the same deal NVIDIA gets. The winkb metadata line and this one converge
later: a `d3djulia` whose pixel shader is a **Mojo kernel** instead of HLSL
is the demo that closes the "cheating" era, and after SG4 it is roughly a
weekend, not a project.
