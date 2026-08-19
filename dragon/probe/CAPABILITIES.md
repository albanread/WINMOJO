# Snapdragon capability report

What has actually been proven to run on this machine, measured 2026-08-19.
"Loads" and "executes" are tracked separately on purpose — the first is cheap
and the second is the one that matters.

| Surface | Loads | Executes | Evidence |
|---|---|---|---|
| **Adreno GPU** via our OpenCL | ✅ | ✅ | saxpy 4096 elems exact; matmul 41.9 GFLOP/s exact |
| **Adreno GPU** via `QnnGpu` | ✅ | ✅ | `qnn-platform-validator --backend gpu`: **Unit Test Passed** |
| **Hexagon NPU** via `QnnHtp` | ✅ | ✅ | `qnn-platform-validator --backend dsp`: **Unit Test Passed** |
| **Oryon CPU** via `QnnCpu` | ✅ | — | provider negotiates; no separate unit test in the tool |
| Full model graph, any backend | — | ❌ | blocked, see below |

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

## Blocked: full model graph

`qnn-net-run` needs a compiled model library. Building one from the SDK's own
example (`examples/QNN/converter/models/qnn_model_float.cpp`) fails, and the
reason is a toolchain gap, not anything about our machine's silicon:

1. `qnn-model-lib-generator` hardcodes `cmake -T ClangCL`, and this Visual
   Studio 18 install has no ClangCL component → `MSB8020`.
2. Forcing the default MSVC toolset gets past configure, then fails to compile:
   the generated code uses `(Qnn_Tensor_t){...}` — a **C compound literal**,
   which is a Clang/GCC extension and not valid ISO C++ at any standard level.
   `/std:c++20` clears the designated-initializer error (`C7555`) but not this
   one (`C4576`, `C2059`).
3. No clang exists anywhere on this box.

**So Qualcomm's generated model code requires Clang. There is no MSVC-only
path.** Fix is one of:

- Visual Studio Installer → *Desktop development with C++* → **C++ Clang tools
  for Windows** (adds the ClangCL toolset the generator expects), or
- install LLVM for ARM64 and point CMake at `clang-cl`.

Either is a user action — it installs software and changes system state.
Everything else on this page already works without it.
