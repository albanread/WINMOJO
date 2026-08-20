# maxdragon

*Mojo and MAX-class inference on Snapdragon hardware, on Windows on ARM.
Nobody asked for this. Nobody is coming to help. It works anyway, mostly.*

This is a fork of [modular/modular](https://github.com/modular/modular)
(Modular's original README lives on in the git history, cheerful as ever, with
its banner and its rocket emoji). It is also a fork of
[WINMOJO](https://github.com/albanread/WINMOJO), the project that ports the
Mojo compiler itself to native Windows ARM64. This repo is the half WINMOJO
deliberately left behind: the GPU, the NPU, the whole question of making a
£350 IdeaCentre Mini do inference like it owes somebody money.

## The situation, stated calmly

Modular's platform officially supports Linux and macOS. Their documentation
says, in full: **"Windows: Not currently supported."** It does not say
anything about Windows *on ARM*, in the way one does not bother posting a
"no swimming" sign on the sun.

MAX is source-available. It is not source-complete. The graph engine
(`max/python/max/_core`) ships as thirteen `.pyi` stub files whose build
rules name a directory that has never existed in any public commit. The GPU
device runtime — the 109 C functions every Mojo `DeviceContext` call lands on
— is declared, beautifully documented in comments, and implemented nowhere you
can see. The parts you would need to add a new hardware backend are precisely
the parts that are missing. We checked. Twice, because the first time we
didn't believe it either.

Qualcomm, for their part, do not publish the Adreno shader ISA, ship an
OpenCL driver that reports its own clock speed as **1 MHz**, and provide a
second OpenCL platform (Microsoft's D3D12 shim) that claims to be the same
GPU, so that selecting a device by name is a trap with your name on it.

So: the compiler vendor doesn't support the OS, the OS vendor impersonates
the GPU, the GPU vendor hides the ISA, and the engine we are nominally
porting does not, in the meaningful sense, exist.

We proceeded.

## What actually works (measured, not hoped)

This is the part that is only sad if you think about how it was obtained.

| Thing | Result |
|---|---|
| MAX's device ABI, reimplemented over OpenCL (`dragon/runtime/dragonrt.dll`) | passes its raw-ABI test: saxpy on the Adreno X1-45, **all 4096 elements exact** |
| Our tiled matmul on the Adreno | **41.9 GFLOP/s**, 3.37× a threaded CPU baseline, verified exact |
| Real QNN graphs on the Hexagon NPU | run; our generated models match the CPU to **0.062%** |
| 1 GiB of weights on the NPU | executes, **4.1× faster than the CPU** — and the advantage grows with size |
| The device ABI, fully specified | 109 symbols extracted from Modular's own bindings, 94 with recovered C prototypes, regenerated mechanically so it cannot drift |
| Adreno as a first-class Mojo target | stdlib target (six edit sites), `adreno` plugin, and a SPIR-V traits/lowering/backend trio in KGEN — written against interfaces read in full |
| The offload pipeline | traced end to end with file:line receipts; **no missing component**. The compiler embeds the SPIR-V in your executable; our runtime hands it to the driver |

The route, since no one will ever draw it on a conference slide: Mojo source
→ KGEN (`--target-accelerator adreno-x1`) → LLVM's SPIR-V backend → bytes
baked into the `.exe` → `dragonrt.dll` → Qualcomm's driver compiler → silicon.
Every arrow except the last is open source in this repository. The last one is
a driver, which is the ordinary kind of closed, the kind we can live with.

## A partial list of things that lied to us

Kept because the lies were the actual work.

- `uname -m` on this machine says `x86_64`. The machine is not x86_64.
- The Adreno driver reports 1 MHz. It is not running at 1 MHz.
- Two OpenCL platforms report the same GPU. One of them is Microsoft in a
  trench coat.
- The GPU's "warp size" is 64. Also 128. Per kernel. On the same device.
  Nobody knows why; we wrote the experiment, and the hypothesis it was
  designed to confirm, it refuted.
- The NPU appeared to die and need a reboot. It was fine. The *runtime* had
  stopped opening sessions, and our control test used the same runtime, which
  is how you prove a hardware fault that does not exist. A different QNN
  runtime on the same silicon ran a 128 MiB model in 555 ms while we were
  composing the obituary.
- The "128 MiB NPU ceiling" produced by that episode was also fiction. The
  real ceiling, if one exists, is somewhere past 1 GiB. We stopped looking
  when the number got embarrassing for the doubters, i.e. us.
- QnnGpu's unit test passes. QnnGpu cannot run an actual graph on this
  driver. The documented escape hatch is validated by the config schema and
  then rejected by the DLL that reads the config, a two-layer system in which
  each layer vetoes the other.
- `cmd.exe`'s `set VAR=value && next` puts the space *into the variable*,
  which becomes an include path with a trailing space, which becomes
  `fatal error: 'QnnInterface.h' file not found`, which is a quoting bug
  wearing a missing-header costume.
- The repository's own `.gitignore` contains `target/`, for Rust, a language
  this repository does not contain, and on Windows it silently ate our
  compiler backend, twice, before we noticed the commits were getting lighter.
- The vendored LLVM source tree vanished from disk *between two grep
  commands* while we were verifying an enum name. Bazel giveth.

Every one of these is documented properly in
[`DRAGONMAX-JOURNAL.md`](DRAGONMAX-JOURNAL.md), along with the four separate
occasions on which we wrote down a confident conclusion and later had to
retract it. The journal does not flatter us. That is what it is for.

## Current status

The GPU line is **code-complete and waiting**. Waiting, specifically, for
WINMOJO to get the Mojo compiler itself building on Windows ARM64 (its gate
G3), at which point our backend gets its first compile ever and either works
or fails in one of four pre-triaged, one-line-fix ways. We wrote a compiler
backend for a compiler that cannot yet compile it. This is either faith or
project management; the journal declines to say which.

If you are here to integrate it: read [`INTEGRATEME.md`](INTEGRATEME.md),
which was written for you, specifically, with love, and commands you can
paste. The formal contract is [`dragon/HANDOFF.md`](dragon/HANDOFF.md). The
finish line is one ordinary Mojo file —
[`dragon/mojo-tests/adreno_saxpy.mojo`](dragon/mojo-tests/adreno_saxpy.mojo) —
printing `PASS`. It contains nothing platform-specific, because the entire
point was that Mojo code should not have to know any of the above happened.

The NPU line continues independently — it never needed the compiler. Next up
there: int8 throughput (the "45 TOPS" the brochure meant) and AOT context
binaries for real models.

## Repository map

| Where | What |
|---|---|
| `dragon/` | everything we added: runtime, probes, benchmarks, QNN tools, design docs |
| `dragon/runtime/` | the MAX device ABI over OpenCL, its generated spec, its test |
| `dragon/qnn/` | NPU model generation, the build recipe, the wedge-vs-ceiling discipline |
| `KGEN/lib/**/Spirv/` | the SPIR-V compiler trio |
| `DRAGONMAX-JOURNAL.md` | the full record, mistakes included |
| `INTEGRATEME.md` | the runbook for the compiler team |

## License

Apache 2.0 with LLVM exceptions, per the header on every one of the 4,566
source files — which is the license that matters, and which Modular's own
[Community License](https://www.modular.com/legal/community) concedes
"controls over these Terms in the event of any conflict." The Community
License governs Modular's *binary* distributions, none of which this project
has ever downloaded, possessed, or run — a fact we maintain on purpose. The
full close reading, including the version of the license that changed the day
before we forked and what replaced it, is in
[`dragon/design/LICENSE-ANALYSIS.md`](dragon/design/LICENSE-ANALYSIS.md). Our
additions are as open as we could make them; the only closed thing in the
chain is the GPU driver, and we have made our peace with that, in the way one
makes peace with weather.

---

*Built on a Lenovo IdeaCentre Mini that cost less than the graphics card this
work is usually done on. It sits on the desk, running kernels correctly for a
toolchain that does not know it exists yet. The project does have fans — but
only the spinning kind.*
