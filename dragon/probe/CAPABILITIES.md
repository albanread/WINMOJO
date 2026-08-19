# Snapdragon capability report

What has actually been proven to run on this machine, measured 2026-08-19.
"Loads" and "executes" are tracked separately on purpose — the first is cheap
and the second is the one that matters.

| Surface | Loads | Executes | Evidence |
|---|---|---|---|
| **Adreno GPU** via our OpenCL | ✅ | ✅ | saxpy 4096 elems exact; matmul 41.9 GFLOP/s exact |
| **Adreno GPU** via `QnnGpu` | ✅ | ✅ | `qnn-platform-validator --backend gpu`: **Unit Test Passed** |
| **Hexagon NPU** via `QnnHtp` | ✅ | ✅ | `qnn-platform-validator --backend dsp`: **Unit Test Passed** |
| **Oryon CPU** via `QnnCpu` | ✅ | ✅ | full graph via `qnn-net-run`, outputs written |
| **Full model graph** on CPU | ✅ | ✅ | InceptionV3-shaped, 298 ms, 2 result sets |
| **Full model graph** on **HTP** | ✅ | ✅ | same graph, 1377 ms incl. prepare, 2 result sets |
| **Full model graph** on `QnnGpu` | ✅ | ❌ | `CL_INVALID_OPERATION` in the recording queue |
| **Our own synthetic model** on CPU + HTP | ✅ | ✅ | 4 MiB matmul chain; HTP matches CPU to 0.062% |
| HTP above ~4 MiB | — | ⚠️ | untested — DSP wedged, see below |

## Reproducing

```powershell
python dragon\probe\probe_surfaces.py         # all three reachable
python dragon\probe\probe_qnn_backends.py     # 5 QNN backends negotiate
python dragon\probe\probe_opencl_exec.py      # real kernel, verified
dragon\bench\matmul_baseline.exe              # CPU vs GPU, verified
```

For the vendor validator, both environment variables matter:

```powershell
$R = "C:\Qualcomm\AIStack\qairt\2.42.0.251225"
$env:PATH = "$R\lib\aarch64-windows-msvc;$R\bin\aarch64-windows-msvc;" + $env:PATH
$env:ADSP_LIBRARY_PATH = "$R\lib\hexagon-v81\unsigned"
& "$R\bin\aarch64-windows-msvc\qnn-platform-validator.exe" --backend all --testBackend --coreVersion
```

## What the validator actually said

**GPU — passed.** It found `OpenCL.dll`, resolved Qualcomm extensions
(`clNewRecordingQCOM`, `clEnqueueRecordingQCOM` — command record/replay, worth
noting for later), reported *"OpenCL 3.0 Qualcomm(R) Adreno(TM) X1-45 GPU"*,
built and ran a vector-addition program, and concluded *"QNN is supported for
backend GPU on the device."*

So **QNN's GPU backend is OpenCL underneath** — the same path our own D2 kernel
takes. That makes the D2 number a fair yardstick for it.

**Hexagon — passed, but only after a fix.** First run failed:

```
ERROR: -6 . Error while executing the sum function.
ERROR: Please use testsig if using unsigned images.
ERROR: Also make sure ADSP_LIBRARY_PATH points to directory containing skels.
Unit Test on the backend DSP: Failed.
```

Setting `ADSP_LIBRARY_PATH` to `lib\hexagon-v81\unsigned` turned it into
*"Unit Test on the backend DSP: Passed."* **Nothing about the hardware was
wrong; the DSP simply could not find its skels.** Worth remembering — the error
text points at image signing first, which is a red herring here.

Two oddities recorded, not explained:

- The tool loads `QnnHtpV73CalculatorStub.dll` and reports *"Core Version:
  Hexagon Architecture V73"* on what is V81 silicon. It then passes against the
  V81 skels. Either the tool's detection is legacy, or the V73 stub is generic.
  Do not treat that "V73" as a reading of the hardware.
- `DSP_INFO UNSUPPORTED_KEY: 49` / `50` appear before the run and appear to be
  harmless.

## Full model graph — CPU and NPU work, GPU does not

Built the SDK's own example model (`examples/QNN/converter/models/qnn_model_float.cpp`,
an InceptionV3 conv+relu graph) into an ARM64 DLL and ran it through
`qnn-net-run` on each backend.

| Backend | Result | Wall time |
|---|---|---|
| `QnnCpu` | **Finished Executing Graphs**, 2 result sets written | 298 ms |
| `QnnHtp` | **Finished Executing Graphs**, 2 result sets written | 1377 ms (incl. prepare) |
| `QnnGpu` | **Graph Execution failure** | 313 ms |

The GPU failure is specific:

```
CL ERROR: (-59) CL_INVALID_OPERATION
GPU ERROR: GPU_ERROR_OPENCL(10014) - OpenCL recorable command queue error
```

That is the `clNewRecordingQCOM` / `clEnqueueRecordingQCOM` path the validator
reported resolving. **`QnnGpu` drives the Adreno through OpenCL command
record-and-replay, and that path is broken on this driver.** Note what it is
*not*: the Adreno itself is fine. Our own direct OpenCL dispatch runs saxpy and
matmul correctly at 41.9 GFLOP/s, and `QnnGpu`'s own vector-add unit test
passes. Only the recorded-queue path fails, and only on a real graph.

### The documented workaround does not exist in this build

`QnnGpuGraph.h` declares `uint8_t disableQueueRecording` as a graph custom
config, defaulting to 0. Reaching it through `qnn-net-run` fails in a way worth
recording, because the two layers contradict each other:

- Put `disable_queue_recording` at the top level of the GPU extension config →
  schema rejects it, saying it depends on `graph_names`.
- Move it beside `"graph_names": ["convReluModel"]` as instructed →
  `ERROR: Unsupported key: graphs/0/disable_queue_recording`.

So the JSON schema validates a key that `QnnGpuNetRunExtensions.dll` then
refuses. **The toggle is only reachable programmatically**, by a host that sets
`QnnGpuGraph_CustomConfig_t` through the API — which is work DragonMax will be
doing anyway, but is not available from the stock tool.

**Consequence for the design: do not build the GPU path on `QnnGpu`.** Our own
OpenCL dispatch already works and is measurably fast; QnnGpu's graph path is
broken here and its escape hatch is unreachable from tooling. The NPU is the
backend where QNN earns its place.

## The HTP wedges, and it will fake a size ceiling if you let it

Measured 2026-08-19 while starting W4.0. **This is the most operationally
important finding so far and it nearly went in the notes as a wrong number.**

Sequence:

| Step | CPU | HTP |
|---|---|---|
| Our synthetic 4 MiB matmul chain | ok | **ok**, matches CPU to 0.062% |
| Same model, 128 MiB of weights | ok, 783 ms | **FAIL** at 41 ms |
| **Control: re-run the 4 MiB model** | ok | **FAIL, identically** |

The failure is always the same and always at session open:

```
<E> DspTransport.openSession qnn_open failed, 0x80000406, prio 100
```

**So 128 MiB is not a ceiling.** The DSP session layer wedged, and once wedged
every HTP run fails the same way — including one that had succeeded minutes
earlier. Reporting "the HTP tops out at 128 MiB" would have been wrong, and it
would have shaped the whole NPU plan around a fiction.

What the wedge is and is not:

- **Not the device.** Windows reports *Snapdragon(R) X - X126100 - Qualcomm(R)
  Hexagon(TM) NPU* with status **OK**.
- **Not the driver stack broadly.** `QnnCpu` keeps working throughout.
- **Not a stray process.** No `qnn-net-run` or holder process survives.
- **Not transient.** Still failing after a 20 s settle.
- It is specific to the **fastRPC / DSP session** layer, and it needs a reboot.

This matches the pre-HND behaviour recorded in the `geniex-gemma4-npu-setup`
notes, which the driver update was thought to have fixed. It has not been fixed
for this failure path.

### The rule that follows

**Every HTP probe must be followed by a control run of a known-good small
model.** If the control still passes, the failure was real. If the control
fails too, the DSP is wedged and *everything measured after the first failure
is void*. `dragon/qnn/htp_ceiling_sweep.ps1` enforces this and refuses to start
if the DSP is already wedged.

Still unknown, and honestly unknowable until after a reboot: whether the
128 MiB model actually exceeded something, or simply triggered the wedge. It
failed at **41 ms during session open**, before weights would plausibly have
been transferred, which hints at a session-sizing rejection rather than a
transfer failure — but that is a hypothesis, not a measurement.

## Building a model library — the working recipe

`dragon/qnn/build_model_lib.ps1` automates all of this. Four separate traps had
to be cleared, none of which produces an honest error:

1. `qnn-model-lib-generator` hardcodes `cmake -T ClangCL`; a stock VS 18 has no
   ClangCL component → `MSB8020`.
2. The generated code uses `(Qnn_Tensor_t){...}` — a **C compound literal**, a
   Clang extension invalid in ISO C++ at any level. `/std:c++20` clears the
   designated-initializer error (`C7555`) but never `C4576`/`C2059`. **Clang is
   mandatory; there is no MSVC-only path.** WINMOJO's bazel toolchain already
   provides clang 22.1.4 targeting `aarch64-pc-windows-msvc`.
3. The generated `CMakeLists.txt` branches on `CMAKE_GENERATOR_PLATFORM`, which
   Ninja refuses to accept. Branch on which `obj/` directory exists instead.
4. `set VAR=value && next` in cmd captures the space before `&&`. That turned
   `QNN_SDK_ROOT` into `...251225 `, the include path into `...251225 \include\QNN`,
   and surfaced as `fatal error: 'QnnInterface.h' file not found` — a quoting
   bug wearing a missing-header costume. Use `set "VAR=value"`.

Also: the generator writes its staging tree to `tmp_<pid>` in the **current
working directory**, not the `-o` directory, and leaves it behind.
