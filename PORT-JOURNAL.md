# WINMOJO — Mojo on native Windows ARM64

Running record of the port. Newest entry at the bottom.

**Goal:** `mojo.exe` compiles and runs a `.mojo` file natively on Windows ARM64.
No WSL, no emulation in the shipped binary.

**Scope:** Mojo compiler (KGEN) + C++ substrate + stdlib + CPU codegen.
**Out of scope:** MAX (kernels, graph, engine, serve), GPU backends (PTX/ROCm).

**Upstream:** `modular/modular` @ `f66d4d5` (shallow). Remote `upstream`.

---

## G0 — Recon (2026-08-19)

### Legal position

| Component | License | Port it? |
| --- | --- | --- |
| Mojo compiler (`KGEN/`), stdlib, substrate | Apache 2.0 **with LLVM exceptions** | Yes — permissive, patent grant, binary attribution waived |
| MAX (`max/`) usage + distribution | Modular Community License | No — out of scope, avoids the restrictive licence entirely |

Scoping to compiler+stdlib keeps us wholly inside Apache 2.0. This is deliberate,
not incidental: it is the reason the scope line is drawn where it is.

### Why there is nothing to fork

- [Issue #620 "[Feature Request] Native Windows support"](https://github.com/modular/modular/issues/620)
  open since **September 2023**. Modular calls native Windows a "mid-term project".
- No community fork, branch, or third-party port found.
- `CLAUDE.md` states: Linux x86_64/aarch64, macOS ARM64, "Windows: Not currently supported".

### The gate we hit

`./bazelw` switches on `$OSTYPE`, handling only `darwin*` and `linux*`;
everything else falls through to `error: unsupported platform`. Under Git-Bash
here `$OSTYPE=cygwin`, so it exits 1 before Bazel ever starts.

Note: `uname` reports `MINGW64_NT-10.0-26200-ARM64` with machine `x86_64` —
Git-Bash is itself x86-emulated. Any shell-level arch detection we add must not
trust `uname -m` on this platform.

### Host toolchain — verified working

| Tool | Status |
| --- | --- |
| MSVC `19.51.36252` **native ARM64** (`Hostarm64 -> arm64`, MSVC 14.51.36231) | Verified: compiled + ran a test exe, `dumpbin` reports `AA64 machine (ARM64)` |
| `vcvarsarm64.bat` | Present (also `vcvarsx86_arm64`, `vcvarsamd64_arm64` cross variants) |
| CMake + Ninja | Bundled inside VS 18 Professional, not on `PATH` |
| Python | 3.12 **ARM64-native** |
| clang-cl | **Missing** — VS component "C++ Clang tools for Windows" not installed |
| Bazel | **Missing** |

VS 18 Professional at `C:\Program Files\Microsoft Visual Studio\18\Professional`.
`vcvarsarm64.bat` emits a benign `vswhere.exe not recognized` warning and still
sets the environment correctly.

### Porting surface — measured, not guessed

| Area | Size / finding |
| --- | --- |
| `KGEN/` C++ | 326 `.cpp`, 234 `.h` |
| Substrate `AsyncRT` `Support` `Config` `Cache` `Init` | 207 `.cpp` |
| stdlib Mojo sources | 3,671 `.mojo` repo-wide; 40 modules in `mojo/stdlib/std` |
| stdlib POSIX syscall deps | `dlopen`×2, `dlsym`×2, `fork`×2, `execvp`×1, `unistd`×1, `O_RDONLY`×1 — and **`mmap`×0, `pthread`×0** |
| Windows awareness in stdlib | **None.** No `os_is_windows` predicate exists anywhere. 5 total string hits across 4 files, one of them a TODO: *"Move this to a generic path module when Windows is supported."* |
| COFF/MSVC awareness in KGEN | Already present in 10+ files incl. `ExecutionEngine`, JIT layers, `Lexer` — inherited from LLVM |

Two readings of this, both favourable:

1. The stdlib's OS-coupled surface is genuinely tiny. Most of it is SIMD,
   collections and math, which are OS-agnostic. `mmap`×0 and `pthread`×0 mean no
   memory-mapping or threading layer to reimplement in the stdlib itself.
2. Zero existing Windows branches means no half-finished abstraction to fight —
   we add the target predicate and the shims cleanly.

### The real blocker

**There is no CMake anywhere in the repo — `find . -name CMakeLists.txt` returns
nothing. KGEN is Bazel-only.** The build system, not the language semantics, is
the hard part of this port. `bazel/internal/cc-toolchain/BUILD.bazel` declares
sysroots for `linux_x86_64`, `linux_aarch64` and `macos` only; there is no
Windows platform, sysroot, or toolchain definition.

LLVM itself is not vendored as source in-tree — it is fetched by Bazel
(`llvm_source` / `llvm_configure` in `MODULE.bazel`). KGEN carries its own
bitcode readers/writers for LLVM **17, 19 and 21** side by side.

## G1 — The build-driver chain (2026-08-19)

Traced what `./bazelw` actually does. It does not download Bazel; it downloads
**bazelisk**, which then reads `.bazelversion` and fetches the real Bazel.

```
bazelw  ->  bazelisk v1.27.0  ->  .bazelversion = buildbuddy-io/5.0.382  ->  Bazel
```

Checking each link for a Windows ARM64 build:

| Link | windows-arm64? |
| --- | --- |
| bazelisk v1.27.0 | **Yes** — `bazelisk-windows-arm64.exe` is published |
| Upstream `bazelbuild/bazel` 9.2.0 | **Yes** — `bazel-9.2.0-windows-arm64.exe` |
| Pinned `buildbuddy-io/bazel` 5.0.382 | **No** — darwin-arm64, darwin-x86_64, linux-arm64, linux-x86_64 only. No Windows asset on any release. |

So the pin is the blocker, not Bazel. Native ARM64 Windows Bazel exists upstream;
Modular pin a BuildBuddy fork that is never built for Windows.

Encouragingly, every BuildBuddy reference in the repo is remote cache / BES
plumbing (`--bes_backend`, `--remote_cache`, `--remote_downloader`) and all of it
sits behind the optional `:cache` and `:public-cache` configs. Nothing in a
*local* build appears to need the fork. Repinning `.bazelversion` to upstream
Bazel is a one-line experiment.

### The expensive discovery

`--config=prebuilt-mojo` — the route the contributor docs tell you to use, and
the only cheap one — **downloads a prebuilt Mojo toolchain**. No Windows build of
that toolchain exists, so the config is unavailable to us by definition.

We are forced onto `--config=build-mojo`, which builds KGEN *and* LLVM from
source. There is no cheap path onto this platform: the port requires a full
compiler build from day one.

### The cc-toolchain is fully custom

`bazel/internal/cc-toolchain/BUILD.bazel` builds on the modern
`@rules_cc//cc/toolchains` API — `cc_toolchain`, `cc_sysroot`,
`cc_artifact_name_pattern`, plus their own `features/` and `tools/` with a
`PLATFORMS` list. Sysroots are hand-declared for `linux_x86_64`,
`linux_aarch64` and `macos`.

It does **not** use Bazel's built-in MSVC auto-detection, so we cannot get
Windows C++ for free by pointing Bazel at `vcvarsarm64`. A Windows toolchain has
to be written inside their framework. This is the main structural work of the
port.

### Ladder

| Gate | Goal | Status |
| --- | --- | --- |
| G0 | Recon, licence, toolchain, surface | Done |
| G1 | Identify the build-driver blocker | Done — repin `.bazelversion` to upstream, add a `bazelw` Windows entry point |
| G2 | Windows/MSVC `cc_toolchain` + `windows_arm64` platform in their rules_cc framework | Main structural work |
| G3 | Build LLVM + MLIR + KGEN from source (`--config=build-mojo`) | Multi-GB, multi-hour |
| G4 | `mojo.exe` links natively | |
| G5 | stdlib shims: `dlopen`→`LoadLibrary`, `dlsym`→`GetProcAddress`, `fork`/`execvp`→`CreateProcess`, `unistd`/`O_RDONLY`; add the missing `os_is_windows` predicate | ~8 files |
| G6 | `hello.mojo` compiles and runs natively on Windows ARM64 | Goal gate |

G1's fix is cheap and testable. G3 is the long pole and cannot be deferred.
