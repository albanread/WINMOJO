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

---

## G1 — Done. Bazel runs natively on Windows ARM64 (2026-08-19)

**Result: `bazel query //KGEN:all` succeeds, exit 0, 617 targets enumerated,
including `//KGEN:mojo`.** The whole bzlmod module graph resolves on Windows.
No emulation anywhere in the chain.

The BuildBuddy fork was **not** load-bearing. Repinning to upstream Bazel was
sufficient, which confirms the G1 reading: their remote-cache plumbing is all
behind optional configs.

### The experiment

Ran bazelisk against the **unmodified** pin first, to prove the diagnosis rather
than assume it:

```
Downloading .../buildbuddy-io/bazel/releases/download/5.0.382/bazel-5.0.382-windows-arm64.exe...
could not download Bazel: ... failed with error 404
```

Bazelisk itself is flawless on Windows ARM64 — it resolved the fork, built the
correct URL, and asked for the right file. The file simply does not exist.
Repinning to `9.2.0` then downloaded `bazel-9.2.0-windows-arm64.exe` and printed
`bazel 9.2.0`.

### Changes

| File | Change |
| --- | --- |
| `.bazelversion` | `buildbuddy-io/5.0.382` -> `9.2.0`. Original preserved at `build/.bazelversion.upstream-orig`. |
| `bazelw` | Added an `msys*`/`cygwin*` branch with `.exe` suffix handling and pinned bazelisk SHAs for both Windows arches. |
| `bazelw.cmd` | New. Native entry point for cmd/PowerShell, no Git-Bash needed. |
| `tools/bazel.bat` | New. Windows counterpart of `tools/bazel`. |

bazelisk `windows-arm64` sha256
`46d97f32458cd88dd4c2c6ad1c597e02d38ee3a1d07b07715c5a9e1b0c09a6dc`, verified
equal to the digest GitHub publishes for the asset.

### Three Windows traps, all real

1. **Arch detection lies.** From Git-Bash on this ARM64 machine, `uname -m` says
   `x86_64` and `$PROCESSOR_ARCHITECTURE` says `AMD64` — Git-Bash is itself an
   x86-emulated process. Only `uname -s` carries the truth
   (`MINGW64_NT-10.0-26200-ARM64`). `bazelw` now keys off `uname -s` and
   explicitly does not trust `$arch`. Native cmd reports `ARM64` correctly, so
   `bazelw.cmd` can use `%PROCESSOR_ARCHITECTURE%`.

2. **The wrapper must be `tools/bazel.bat`, not `.cmd`.** Determined
   empirically: with `tools/bazel.cmd` in place bazelisk silently ignored it and
   ran Bazel directly, so `build/wrapper.bazelrc` was never generated and
   `.bazelrc`'s hard `import` of it aborted the build. Renaming to `.bat` made
   bazelisk delegate immediately. A silent non-delegation is a nasty failure
   mode — it looks like an unrelated rc-file error.

3. **Git-Bash mangles Bazel labels.** `./bazelw query '//KGEN:all'` fails with
   `invalid package name '/KGEN'` because MSYS path conversion rewrites `//...`
   into a Windows path. Use `MSYS_NO_PATHCONV=1` (verified working) or drive it
   from PowerShell via `bazelw.cmd`.

### Notes for later gates

- `detect_local_resources.sh` is pure GPU detection and its `else` branch
  assumes macOS, so it cannot run on Windows. Since GPU is out of scope,
  `tools/bazel.bat` writes an empty `local-resources.bazelrc`, which is exactly
  what a GPU-less Linux host produces.
- `tools/bazel.bat` rejects `--config=prebuilt-mojo` with an explanatory message,
  since that config cannot ever work on Windows.
- `//KGEN:mojo` is an `alias` rule, so the real binary target needs resolving
  before G4.

**Next: G2** — the `windows_arm64` platform and an MSVC `cc_toolchain` in their
custom `rules_cc` framework. Nothing further can build until that exists.

---

## G2 — Windows ARM64 toolchain declared (2026-08-19)

### Correction to the G1 plan

G1 called this "write an MSVC `cc_toolchain`". That was wrong, and reading
`tools/tools.bzl` changed the approach entirely: **Modular do not use MSVC on any
platform.** Every toolchain is hermetic Clang/LLVM — `@clang-{platform}//:bin/clang`,
`compiler = "clang"`, lld, and hermetic sysroots.

So writing an MSVC toolchain would have meant rewriting every `cc_args` in
`args/` and `features/` from GNU-style flags to `/W4`-style MSVC flags. Instead
we add a *fourth hermetic clang platform* and target `aarch64-pc-windows-msvc`
with the ordinary clang driver, which keeps every existing GNU-style arg working
unchanged. Using `clang-cl` would have reintroduced exactly the flag-dialect
problem, so it is deliberately avoided.

### The lucky break

Modular pin **LLVM 22.1.4** and host their own builds on S3, with no Windows
artifact. But upstream LLVM publish
`clang+llvm-22.1.4-aarch64-pc-windows-msvc.tar.xz` — *the exact same version*.
So `clang.BUILD`'s expected `lib/clang/22/...` layout lines up with no patching,
and we source that one platform from `llvm/llvm-project` releases instead of
Modular's S3. This is the difference between "port the toolchain" and "add a
platform".

737 MB, sha256 `958e314fc28968c3895a61c0b9ae54c9e4ec7a409ec4b59cc02c9c6a0ae90be4`.

### Changes

| File | Change |
| --- | --- |
| `BUILD.bazel` | Added `//:windows_arm64` config_setting and its `prebuilt_mojo_toolchain_enabled` entry. |
| `bazel/common.MODULE.bazel` | Added the `clang-windows-arm64` http_archive. |
| `MODULE.bazel` | Instantiated `windows_sysroot_repository`. |
| `bazel/internal/cc-toolchain/windows_sysroot_repository.bzl` | **New.** Locates MSVC + Windows SDK, emits `cc_args`. |
| `bazel/internal/cc-toolchain/tools/tools.bzl` | Added `windows-arm64` to `PLATFORMS` plus a separate `_declare_windows_tools`. |
| `bazel/internal/cc-toolchain/BUILD.bazel` | Windows sysroot args, target-triple args, four artifact-name patterns, toolchain registration, coverage_support entry. |

### Why Windows needs its own tool declarations

The existing tool map cannot be reused as-is:

- The `clang`/`clang++`/linker tools are **bash wrappers**
  (`multi-platform-clang.sh` and friends) that Windows cannot exec. Windows binds
  the `.exe` binaries directly.
- There is **no separate linker driver**: for a `windows-msvc` target the clang
  driver spawns `lld-link` itself, so `link_actions` map to `clang++`, with
  `:ld` carried in the tool's `data` so lld is present in runfiles.
- `llvm-otool`, `llvm-install-name-tool` and `dsymutil` are Mach-O tools with no
  PE/COFF meaning, so they are omitted.
- `dwp` is omitted: split DWARF does not apply to PDB-based debug info.

### The sysroot problem, and why this one is not hermetic

There is no `--sysroot` for an MSVC target, and `.bazelrc` sets
`--incompatible_strict_action_env`, so clang cannot discover MSVC from the
environment the way it does in a `vcvars` shell. `windows_sysroot_repository`
therefore resolves the paths once at fetch time — via `vswhere`, falling back to
scanning the standard install layout — and bakes them into `cc_args`. It fails
loudly with an actionable message if a directory is missing, rather than letting
clang fail later with a confusing missing-header error.

This one is deliberately **not** hermetic. Microsoft's licence does not permit
redistributing the CRT headers and import libraries the way the Linux sysroots
are redistributed, so a hermetic Windows sysroot would have to be assembled on
the machine anyway.

### Verified

- `bazel query //bazel/internal/cc-toolchain:all` exits 0 and lists
  `windows-arm64-toolchain`, `windows-arm64_clang_toolchain`, all four artifact
  patterns and `windows_arm64_target`.
- `bazel query @sysroot-windows-arm64//:all` exits 0: the repository rule runs
  and detects **MSVC 14.51.36231** and **Windows SDK 10.0.26100.0**, emitting
  correct `-imsvc` include paths and `-L` library paths for `arm64`.

### Not yet verified

**Nothing has been compiled.** The 737 MB clang archive has not been downloaded,
so no C++ has gone through this toolchain. Declaration and analysis are proven;
codegen is not. Expect real iteration here — flag-dialect mismatches in `args/`
and `features/`, and CRT link details, will only surface at first compile.

### Trap: do not mix shells

Driving Bazel from Git-Bash and PowerShell alternately restarts the Bazel server
every time, because Git-Bash injects
`--host_jvm_args=-Dbazel.windows_unix_root=...` and PowerShell does not. Pick one
shell per session. PowerShell + `bazelw.cmd` is the better default, since it also
avoids the `//`-label mangling.

**Next: G3** — fetch the clang archive and put real C++ through the toolchain.

---

## G3 — First contact with the toolchain (2026-08-19)

The 737 MB clang archive downloaded and extracted in 118 s. A smoke `cc_binary`
was added at `bazel/internal/cc-toolchain/smoke` — deliberately plain
`rules_cc` rather than the `modular_*` macros, so a failure there is
unambiguously a toolchain problem rather than a repo-convention one.

Five blockers hit in sequence. Four are fixed; the fifth is open.

### Fixed

1. **`clang.BUILD` does not fit the Windows distribution.** compiler-rt is
   `clang_rt.*` with no `lib` prefix under `lib/clang/22/lib/windows`, there is
   no `lib/clang/22/share`, and everything is `.exe`. Added
   `bazel/public-patches/clang-windows.BUILD` rather than relaxing the shared
   globs, so a genuinely missing file on Linux or macOS still fails loudly.

2. **Six selects in `args/BUILD.bazel` had no default**, covering only linux and
   macos, so each failed analysis on Windows. Each now has an explicit Windows
   branch, and the target triple moved into the existing `compile_and_link_args`
   select instead of a bespoke `cc_args` target.

3. **Two flags are actively wrong, not merely redundant.** `-fPIC` is rejected as
   unused for PE/COFF, and `-Werror=unused-command-line-argument` promotes that
   to a hard error. `-fno-autolink` suppresses the `#pragma comment(lib, ...)`
   directives in the MSVC headers, which is precisely the mechanism that selects
   a CRT variant matching the compilation mode — so it is dropped on Windows
   rather than pinning CRT libraries by hand.

4. **No `sandboxed` strategy exists on Windows**, and naming one is a hard error
   rather than a fallback. Added a `build:windows` section; the repo already sets
   `--enable_platform_specific_config`.

Also fixed `tools/bazel.bat`: cmd's `for` treats `=` as a delimiter, so
`--config=build-mojo` was silently split in two and never matched.

### Open blocker: no Windows ARM64 Python below 3.11

```
rules_python:python WARNING: No host compatible runtime found compatible with version 3.10
Error in fail: Unable to find interpreter for pip hub 'grpc_python_dependencies'
for python_version=3.9 ... Expected to find python_3_9_host among registered versions:
  python_3_11_host python_3_12_host python_3_13_host python_3_14_host
```

`PYTHON_VERSIONS` lists `3_10` through `3_14`, but only 3.11+ ever register on
this host: **rules_python publishes no `aarch64-pc-windows-msvc` interpreter for
3.9 or 3.10.** Adding `3_9` to the list was tried and reverted — it changes
nothing but the warning text, which confirms the gap rather than closing it.

`grpc` demands a 3.9 interpreter for its `grpc_python_dependencies` pip hub, and
toolchain resolution evaluates that extension even for a pure C++ target.

Scoping the mypy aspect to linux and macos (below) moved the failure from
"Analysis of aspects" to the target itself, which proves the aspect was one
route in but not the only one.

Candidate fixes, cheapest first:

- **Exclude grpc.** It is almost certainly a MAX serving dependency, and MAX is
  already out of scope. If nothing in the KGEN graph needs it, the cleanest fix
  is for it not to be in the graph at all.
- Override grpc's `python_version` to something with a win-arm64 runtime.
- Supply a local 3.9 via `local_runtime` rather than a hermetic download.

The first is most in keeping with the port's scope, and should be tried first.

### Note on the mypy aspect

`build --aspects=//bazel/pip:mypy.bzl%mypy_aspect` was applied unconditionally,
so it attached to C++ targets too. `--aspects` accumulates, so neither
`--aspects=` nor a `build:windows` section can clear it — it has to not be added
in the first place. It is now scoped to `build:linux` and `build:macos`. Python
linting has no bearing on porting a C++ compiler.

### Python versions: fixed by patching the modules that ask for 3.9

The 3.9 problem was not grpc-specific. `grpc` and `protoc-gen-validate` both
declare `PYTHON_VERSIONS = ["3.9" ... "3.13"]` and create a toolchain and a pip
hub per version — pgv copies grpc's block verbatim. Both are patched to start
at 3.11, using the `single_version_override` patches list Modular already
maintain for grpc, which is also where they already strip macOS x86
special-casing. So this follows an established mechanism rather than adding one.

Worth recording: **MODULE.bazel patches do take effect during bzlmod
resolution**, which was not obvious beforehand and is what makes this approach
viable at all.

Note this is *not* about compiling grpc. Nothing grpc-related is compiled; the
failure is in dependency resolution, and it blocks even a plain `cc_binary`
because toolchain resolution evaluates the pip extension regardless of what is
being built.

### Open blocker: Winsock fails inside repository rules

```
File ".../python_3_12_host/Lib/asyncio/windows_events.py", line 8, in <module>
  import _overlapped
OSError: [WinError 10106] The requested service provider could not be loaded or initialized
```

`rules_pycross` runs pip to install a wheel, pip imports `tenacity`, which
imports `asyncio`, which on Windows imports `_overlapped`, which initialises
Winsock. `WinError 10106` is `WSAEPROVIDERFAILEDINIT`.

What has been ruled out:

- **Not a broken interpreter.** Running that exact `python.exe` directly outside
  Bazel, `import _overlapped` succeeds. The interpreter also reports `ARM64
  64bit`, so it is not an emulated x64 build.
- **Not a missing environment variable.** Passing `SystemRoot`, `windir`,
  `SystemDrive`, `PATH`, `TEMP` and `TMP` through with `--repo_env` changes
  nothing. An earlier run that appeared to fix this was misread: repository
  evaluation order is not deterministic, so it had merely surfaced a different
  failure first. The `--repo_env=SystemRoot` line was therefore reverted rather
  than kept as unverified configuration.

So the failure is specific to Winsock initialising inside Bazel's
repository-rule subprocess on Windows ARM64, and the cause is not yet
identified.

Options not yet tried, roughly in order of appeal:

- Find out whether `rules_pycross` is reachable from the KGEN graph at all. Like
  grpc, it may be MAX-only, in which case the fix is for it not to be in the
  graph.
- Pin `rules_pycross` to a version whose bootstrap avoids pip, or patch its
  wheel install to not import `asyncio`.
- Drive `clang.exe` directly for one run to prove the compiler, sysroot and CRT
  link work, decoupling that proof from the Bazel dependency graph.

The last is worth doing regardless: it separates "is the toolchain right" from
"does the repo's dependency graph resolve on Windows", which are independent
risks currently entangled.

### The toolchain itself is proven correct

Bypassed Bazel entirely and drove `clang++.exe` with the exact flag set the
`windows-arm64` toolchain would use — every `cc_args` from `args/BUILD.bazel`
plus the include and library paths `windows_sysroot_repository` generated.
Preserved as `bazel/internal/cc-toolchain/smoke/toolchain_check.sh` so it can be
re-run whenever the toolchain args change.

Result: compiles, links, and runs.

```
winmojo smoke ok: windows-arm64-clang
pointer width: 64 bits
```

`dumpbin` reports `AA64 machine (ARM64)`, Windows CUI subsystem, 153,600 bytes.

This decouples two risks that were entangled: **the toolchain design is sound**,
and everything still failing is dependency-graph plumbing. It also settles the
open question from G2 — `-fno-exceptions` and `-fno-rtti` *do* work against the
MSVC STL, so `<vector>` and `<string>` compile despite the STL's use of
exceptions internally. That had been the largest unknown in the flag set.

**And it found a real bug that Bazel had not yet reached.**
`windows_sysroot_repository` emitted `-imsvc` for the MSVC and SDK include
directories. `-imsvc` is a **clang-cl** flag; the clang driver rejects it with
`error: unknown argument: '-imsvc'`. Since the toolchain deliberately uses the
clang driver rather than clang-cl to keep the GNU-style args working, the
correct spelling is `-isystem`. Fixed.

Worth noting the sequencing: this bug sat behind the pip/Winsock failures and
would only have surfaced after they were solved. Testing the toolchain directly
found it immediately, which is a good argument for keeping that script around.

### Scope correction: "not built here" is not "chop it out"

MAX is being ported to Windows ARM64 / Snapdragon / Adreno / Hexagon NPU as a
separate project that forks this trunk. So while MAX is not *built* here, every
MAX integration point — grpc, protoc-gen-validate, rules_pycross, the pip and
python plumbing — has to be made to **work** on Windows ARM64, never deleted or
excluded from the graph to turn a build green. Removing a dependency to get a
build passing here would leave a hole that the MAX port inherits.

An earlier suggestion in this journal to check whether `rules_pycross` was
reachable and keep it out of the graph was wrong on those grounds, and is
withdrawn. The distinction that does hold is between a *platform gap* and an
*inapplicable concept*: Mach-O tools such as `llvm-otool` and
`llvm-install-name-tool` have no PE/COFF meaning, and omitting those is not the
same as dropping a dependency.

### Winsock, solved: rctx.execute replaces the environment

`rules_pycross`'s `install_venv_wheels` does:

```python
env = dict(PYTHONPATH = str(rctx.path(pip_whl)))
result = rctx.execute([...], environment = env)
```

`rctx.execute(environment = ...)` **replaces** the environment rather than
extending it, so the subprocess gets `PYTHONPATH` and nothing else. Windows
cannot initialise Winsock without `SystemRoot`, so any import reaching `asyncio`
dies with `WinError 10106`. pip imports `tenacity`, which imports `asyncio`.

Reproduced exactly, outside Bazel:

| Environment passed to the same interpreter | Result |
| --- | --- |
| `{PYTHONPATH}` — what the rule passes | `WinError 10106` |
| `{PYTHONPATH, SystemRoot}` | `OK` |

This also explains why `--repo_env=SystemRoot` never helped: the rule discards
the inherited environment before that flag can matter. It is an upstream
`rules_pycross` bug, not a Modular one, and it is patched rather than routed
around.

Two process notes worth keeping:

- Earlier guesses at this — missing env vars, then
  `--sandbox_default_allow_network` — were both wrong, and `env -i` testing
  wrongly exonerated the environment because MSYS does not produce a truly empty
  Windows environment block. Reading `repo_venv_utils.bzl` found it in minutes.
  Read the code before theorising about the flags.
- The patch is matched case-insensitively with a fallback, because whether
  Bazel reports `SystemRoot` or `SYSTEMROOT` was not worth another guess.

With that fixed, analysis moves past all the pip machinery and into the C++
toolchain proper, where the remaining failures are ordinary missing-Windows
branches in `select()`s.

### Repository state

The fork now has a real remote: `origin` =
`github.com/albanread/WINMOJO.git`, with `upstream` = `modular/modular`.

The first push was rejected — `did not receive expected object` — because the
working copy was a `--depth 1` clone and the pack was incomplete without the
base commit's ancestors. `git fetch --unshallow upstream` fixed it: the history
is now complete at 53,622 commits, which also makes future rebases onto upstream
tractable.
