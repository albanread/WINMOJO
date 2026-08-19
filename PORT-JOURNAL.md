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

### G3 reached: Bazel builds and runs a native Windows ARM64 binary

```
$ bazel build --config=build-mojo -c fastbuild //bazel/internal/cc-toolchain/smoke
INFO: Build completed successfully, 5 total actions

$ ./bazel-bin/.../smoke.exe
winmojo smoke ok: windows-arm64-clang
pointer width: 64 bits
```

`dumpbin` reports `AA64 machine (ARM64)`, Windows CUI. No manual flags: plain
`bazel build`. The whole chain now works — bazelisk, Bazel, the module graph,
the pip and python plumbing, the hermetic clang, the MSVC sysroot, compile and
link.

Five further problems were solved to get here.

1. **Path mapping requires sandboxing.** `--experimental_output_paths=strip`
   makes CppCompile "require sandboxing due to path mapping", which Windows
   cannot provide. Disabled via the wrapper.

2. **Symlinked sysroots glob to nothing on Windows.** The first attempt mirrored
   `macos_sysroot_repository` and symlinked the MSVC and SDK trees in. The
   symlinks were created and were traversable from a shell, but Bazel's `glob`
   does not follow symlinked directories on Windows, so every `directory` target
   had empty srcs. The rule now **copies** instead — about 1.6 GB, a slower
   first fetch, and the price of Bazel actually seeing the headers.

3. **`directory` reports its package path, not its srcs' root.** With all eight
   targets declared in the repository root BUILD file, every one resolved to the
   repository root, so the toolchain silently emitted five identical `-isystem`
   flags pointing at the same place. That is why the macOS rule puts its
   `directory` inside `sysroot/BUILD.bazel`. Each copied tree now gets its own
   BUILD file and is referenced as `@sysroot-windows-arm64//<name>:dir`.

4. **`-D_DEBUG` means something else on MSVC.** `args/modular:assertions` pairs
   it with `-D_GLIBCXX_ASSERTIONS`, which is a libstdc++ idiom. On MSVC `_DEBUG`
   switches the entire CRT to its debug variant, so the STL emitted calls to
   `_CrtDbgReport` and the link failed on it. Windows keeps `-UNDEBUG`, which is
   the actual intent — `assert()` stays live outside production builds.

5. Shell actions need `BAZEL_SH`, since the builtin module map generator is a
   bash script.

The lesson repeated throughout: three of these produced misleading errors a long
way from their cause. Symlinked globs surfaced as "absolute path inclusion(s)
found"; the `directory` path bug surfaced as the same thing; `_DEBUG` surfaced as
an undefined symbol in `<vector>`. Dumping the actual command line with
`--subcommands` found two of them immediately after flag-level guessing had
failed.

**Next: G4** — point this at KGEN and build the compiler itself. The toolchain is
proven on one translation unit; KGEN is 326 `.cpp` files plus LLVM.

---

## G4 — Building KGEN (2026-08-19, in progress)

### Method

`--nobuild` runs loading and analysis without executing actions, so each missing
`select()` branch surfaces in about a second instead of hours into an LLVM
compile. Worth using for the whole of this gate.

### Fixed so far

- **`Support:Base` library naming.** Only the shared-library *suffix* was
  platform-dependent; the `lib` prefix and `.a` were unconditional. PE/COFF uses
  no prefix and `.dll`/`.lib`, so the whole set is now selected. These have to
  agree with the `artifact_name_patterns` the Windows toolchain declares, or
  runtime lookups construct names that were never produced. The select is
  *flattened*, not nested: `_process_defines` parses it with with_cfg.bzl's
  `decompose_select_elements`, which cannot handle a select inside a select.
- **Mojo's own target triple** is `aarch64-pc-windows-msvc`. Deliberately no
  `--target-cpu`: the other platforms pin one because their hardware is known,
  whereas Windows ARM64 spans several Snapdragon generations whose LLVM names
  move between releases. The triple is the part that must be right.
- **tcmalloc / gperftools** support neither Windows, so those aliases resolve to
  `empty_lib` and the process keeps the system allocator. A performance choice,
  not a correctness one.
- **`Support:Globals`** force-links an MLIR symbol by its *Itanium-mangled*
  name, which does not exist under the MSVC ABI. It only matters for matching
  MLIR types across separate shared objects, and `mojo.exe` links as a single
  static binary, so Windows takes no linkopt. Must be revisited before building
  Mojo as DLLs.
- **LLDB** attaches natively on Windows rather than through a debug server, so
  no `LLDB_DEBUGSERVER_PATH` is exported.

### Current blocker: crashpad has no Windows targets

`Support:CrashReporting` depends unconditionally on `@crashpad//:client`, and
Modular's hand-written `crashpad.BUILD` — 679 lines — only defines
`mini_chromium_linux`/`_macos`, `util_linux`/`_macos` and `client_linux`/`_macos`.
Its compat include list literally reads `includes = ["compat/non_win"]`.

The good news is that **the Windows sources are already in the vendored
tarball**: `client/crashpad_client_win.cc`, `client/crash_report_database_win.cc`,
`util/win/` (63 files), `compat/win/` (9 files) and `handler/win/`. Nothing needs
fetching or patching upstream — only Modular's Bazel wrapper needs extending.

So this is mechanical rather than novel: add `mini_chromium_windows`,
`util_windows` and `client_windows` targets, swap `compat/non_win` for
`compat/win`, and translate the source lists from crashpad's own GN build.

Scope note: only the **client** is linked into `mojo.exe`. `handler/win` builds a
separate crash-handler executable and is not on the critical path, so the client
comes first. Crash reporting stays in the graph either way — MAX uses it, and
removing it would leave a hole the MAX port inherits.

### Recon: crashpad is the *only* remaining analysis blocker

Rather than write the crashpad BUILD blind, the dependency was removed in a
throwaway edit purely to enumerate what else stands between here and compiling
C++. Two things came out of it, and the edit was reverted immediately.

**1. `//KGEN:mojo` is the wrong target.** It aliases to `mojo-full`, the
debugger-bundled variant, whose dependency chain is:

```
//KGEN:mojo -> mojo-full -> //KGEN:gdb-server
  -> lldb:gdb-server -> lldb:lldb-server   <-- marked incompatible
```

LLVM's own Bazel overlay marks `lldb-server` incompatible on Windows, correctly:
LLDB attaches natively there rather than through a remote debug server. The
plain `//KGEN/tools/mojo:mojo` target is the compiler binary without the
debugger bundle, and is the right thing to build. This is target selection, not
scope reduction — `mojo-full` is a packaging concern.

**2. With crashpad out of the way, analysis of the entire Mojo compiler passes
on Windows ARM64.** `bazel build --nobuild //KGEN/tools/mojo:mojo` exits 0.
Putting the dependency back leaves exactly one error, in crashpad's own
`BUILD.bazel:463`.

So the build-system work is nearly done: crashpad is the last plumbing gate, and
past it the remaining work is compiling roughly 326 KGEN `.cpp` files plus LLVM
and MLIR — real C++, where MSVC STL differences, the `-Werror` set and POSIX
assumptions in the source will be the actual obstacles.

### Repository state

The fork now has a real remote: `origin` =
`github.com/albanread/WINMOJO.git`, with `upstream` = `modular/modular`.

The first push was rejected — `did not receive expected object` — because the
working copy was a `--depth 1` clone and the pack was incomplete without the
base commit's ancestors. `git fetch --unshallow upstream` fixed it: the history
is now complete at 53,622 commits, which also makes future rebases onto upstream
tractable.

---

## G4 — Compiling KGEN: the first two full builds (2026-08-19)

Crashpad landed first (see below), then the whole compiler was pointed at the
toolchain. Two full builds so far.

| | actions | failed targets |
| --- | --- | --- |
| Build 1 | 8,734 / 8,738 | **484** |
| Build 2 | in progress | **3** so far at 3,099 / 8,885 |

Both were run with `--keep_going`, which matters: a multi-hour build that stops
at the first error teaches you one thing, whereas one that continues inventories
everything. Classifying ~2,000 errors from build 1 by normalising the messages
(strip quoted identifiers and digits, then sort by frequency) reduced them to
four causes.

### The four systemic causes, in order of blast radius

**1. MSVC flag dialect in third-party BUILD files — 1,633 errors.** curl passes
its eight feature defines as `/DBUILDING_LIBCURL` and friends; boringssl's
`util.bzl` passes `/std:c11`. Both spellings are clang-cl only. Under the
ordinary clang driver a leading slash is a *file path*, so every affected
translation unit died with `no such file or directory: '/DWIN32'`.

This is the recurring bill for choosing the clang driver over clang-cl in G2,
and it is still the right trade — clang-cl would have meant rewriting every
GNU-style flag in `args/` and `features/`. Worth doing proactively: a scan of
every external `BUILD`/`.bzl` for MSVC-style flags found only these two.
grpc's are confined to an RBE toolchain config that is never used.

**2. `NOMINMAX` — ~224 errors.** `windows.h` defines `min` and `max` as
function-like macros, so `std::numeric_limits<size_t>::max()` becomes a macro
invocation with the wrong arity. It surfaces either as "too few arguments
provided to function-like macro invocation" or, more confusingly, as "invalid
operands to binary expression". Almost all of it was boringssl.

This belongs in the toolchain's `compile_args`, not per-target, because it has to
hold for third-party code too. `WIN32_LEAN_AND_MEAN` went in beside it: it cuts
compile time and, usefully, excludes `wincrypt.h`, whose `X509_NAME` and `PKCS7`
macros collide with boringssl's own names.

**3. `layering_check` had no standard library in the module map.** Windows got
only clang's builtin headers, because MSVC has no `--sysroot` and G3 therefore
paired it with no sysroot directory. The other platforms cover their standard
library through exactly that directory, so on Windows every `#include <atomic>`
or `<string>` belonged to no module and was rejected with "does not depend on a
module exporting". Fixed by adding the MSVC STL and SDK directory targets to
`builtin_module_map`.

**4. `parse_headers` had no wrapper to create its marker.** The feature works by
setting `PARSE_HEADER` and expecting the compiler wrapper to create that file;
the `.sh` wrappers end with `touch "${PARSE_HEADER}"`. G2 bound `clang.exe`
directly, so the marker never appeared and every header parse failed with "not
all outputs were created". Fixed with `.bat` wrappers that mirror the shell
ones — including resolving the compiler relative to the execution root, which is
how the `.sh` version works too — and create the marker only on success.

### The real C++ problems, and a pattern worth knowing

Four dependencies needed source patches, and **every one of them already had a
portable fallback sitting behind the failing branch**. In each case the fix was
to correct an over-broad feature test rather than to write anything new.

| Dependency | Failing construct | Why it breaks on Windows ARM64 |
| --- | --- | --- |
| xxhash | `__asm__("" : "+w" (var))` | clang cannot lower the NEON `"+w"` constraint: "don't know how to handle tied indirect register inputs" |
| protobuf/upb | hand-written AArch64 assembly in `encode_longvarint` | LLVM cannot size a function containing inline asm, so SEH unwind emission fails |
| abseil | `__builtin_nontemporal_store` | `__m128i` is MSVC's `__n128`, a *union*, which the builtin rejects |
| LLVM BLAKE3 | `__builtin_shufflevector` | `vreinterpretq_*` yields `__n128` rather than a clang vector type |

Two lessons generalise:

- **`defined(__aarch64__) && defined(__clang__)` is true on Windows too.** Three
  of these four guards assumed that combination implied a Unix-like ARM64
  target. Adding `!defined(_WIN32)` was the whole fix in each case.
- **MSVC's NEON types are unions, not vector types.** Anything using clang
  vector builtins on `__m128i`/`uint8x16_t` will fail. abseil's case is
  especially misleading: `ABSL_HAVE_BUILTIN(__builtin_nontemporal_store)`
  reports the builtin as *present*, because it is — it just refuses this type.

The upb one is the most interesting for this port specifically, because Windows
ARM64 **requires** unwind data for every function. The failure is not cosmetic
and cannot be waived; the assembly simply cannot be used here.

### Method notes

- `--nobuild` for analysis-only passes: each missing `select()` branch surfaces
  in about a second rather than hours into a compile.
- `--subcommands=pretty_print` to see the real command line. This found the
  `-imsvc` bug and the collapsed `-isystem` paths immediately, after flag-level
  guessing had failed on both.
- **Generate patches with `git diff`, never by hand.** Hand-written unified-diff
  hunk headers were wrong three times in a row here; copying the file into a
  scratch git repo, editing it, and diffing is both faster and correct. Always
  `git apply --check` before handing a patch to Bazel, since Bazel's failure
  mode is a module-resolution error far from the cause.

---

## G5–G7 — The road to test results and a Python comparison (2026-08-19)

The goal is now explicit: run the Mojo test suite on Windows ARM64, report how
many pass, and compare performance against Python. That decomposes into three
gates, and the recon for each is done.

### What the test suite looks like

**322 `.mojo` test files** under `mojo/stdlib/test`, plus a `benchmarks/` tree.
Each test directory declares one `mojo_test` target per source file:

```python
[
    mojo_test(name = src + ".test", srcs = [src], ...)
    for src in glob(["*.mojo"])
]
```

So once `mojo.exe` links, `bazel test //mojo/stdlib/test/...` gives a pass/fail
count directly, with no new harness. Worth noting for honest reporting later:
some tests already carry `target_compatible_with` constraints pinning them to
Linux — `test_erf.mojo` and `test_tanh.mojo` among them — so those will be
*skipped*, not failed, and the denominator on Windows is not 322.

### G5: the stdlib has no concept of Windows

`CompilationTarget` had `is_linux()` and `is_macos()` and nothing else, and every
OS-specific value in the standard library flows through `platform_map`, which
accepted only `linux` and `macos` arms. Until that changed, no stdlib code could
express a Windows branch at all. `is_windows()` and a `windows` arm are now in,
keyed off the target's `os` field, which is `windows` for
`aarch64-pc-windows-msvc`.

The substantive work is `std/sys/_libc.mojo`, which the whole FFI layer sits on.
Four functions need Windows implementations, and three of them have semantics
that differ in ways that are easy to get quietly wrong:

| POSIX | Windows | Trap |
| --- | --- | --- |
| `dlopen(path, flags)` | `LoadLibraryA` | `dlopen(NULL, ...)` means "the main program" and maps to `GetModuleHandleA(NULL)`, not `LoadLibraryA(NULL)` |
| `dlsym(handle, name)` | `GetProcAddress` | straightforward |
| `dlclose(handle)` | `FreeLibrary` | **return values are inverted**: `dlclose` returns 0 on success, `FreeLibrary` returns non-zero on success |
| `dlerror()` | `GetLastError` + `FormatMessage` | `dlerror` returns a string or NULL *and clears* the error; Windows returns a numeric code and does not |

The `dlclose` inversion is the one most likely to produce a silently wrong port,
since the failure would look like "unloading always fails" rather than a crash.

### Sequencing note

These stdlib changes are deliberately **not** being written ahead of a working
`mojo.exe`. Mojo is unfamiliar enough that speculative code written with no way
to compile it would mostly be guesswork, and the compiler is the thing that tells
us whether the FFI declarations are right. The predicate work above is the
exception: it is additive, mechanical, and needed regardless.

---

## G4 — The build system is done (2026-04-19)

**Build 18 attempted all 8,847 actions for the first time.** Every remaining
failure is now first-party C++ rather than build configuration, which makes this
the boundary between porting the *build* and porting the *code*.

### The last build-system problem: three command-line limits

Windows has three ceilings and this port hit all of them, each with a different
signature:

| Limit | Applies to | Symptom |
| --- | --- | --- |
| 8,191 (cmd.exe) | anything through the .bat wrapper | `The command line is too long` |
| 32,767 (CreateProcess) | direct .exe invocation | bare `Exit -1`, no diagnostic |

The second is the dangerous one: no error text, just a failed launch, which
reads like a crash rather than a length problem.

Compiles needed `compiler_param_file`; links needed **both** the
`linker_param_file` feature *and* `cc_toolchain`'s `supports_param_files`
attribute, which defaults to False. Enabling the feature alone changed the
argument count by exactly zero. The attribute decides whether params are used at
all; the feature only describes how they are formatted. rules_cc's own MSVC
configuration sets both, which was the clue worth following sooner.

### The remaining surface: ~9 files

Roughly 70 targets fail, but they collapse to a small set of substrate files:

| Area | Problem |
| --- | --- |
| `Support/Threading/SpinWaiter.h` | includes `<immintrin.h>` on Windows |
| `Support/lib/Debugger.cpp` | `IsDebuggerPresent`, `Sleep` undeclared |
| `Support/lib/CPUCache.cpp`, `Threading/HWInfo.h` | `sched.h` |
| `AsyncRT/lib/Support/Semaphore.cpp` | `semaphore.h` |
| `Init/lib/DevelopmentSignalHandler.cpp` | `sys/ucontext.h` |
| `Support/lib/FileSystemExtras.cpp` | `ssize_t` |
| `AsyncRT/.../Globals.cpp`, `Support/lib/Context.cpp` | assorted |
| link | `CommandLineToArgvW` needs shell32 |

### A latent bug that is not Windows-specific

`SpinWaiter.h` guarded its x86 intrinsics on `_MSC_VER`:

```cpp
#ifdef _MSC_VER
#include <immintrin.h> // _mm_pause
#endif
```

and dispatched with `#if MODULAR_WINDOWS` *before* checking the architecture, so
Windows implied `_mm_pause()`. `_MSC_VER` says the compiler is MSVC-compatible,
which clang also is when targeting the MSVC ABI; it says nothing about the
target architecture. **MSVC on Windows ARM64 would hit this too.** The macros to
use were already there and correct — `MODULAR_ARM` is true for `_M_ARM64`.

This is the same shape as the dependency guards fixed earlier, where
`defined(__aarch64__) && defined(__clang__)` was taken to mean a Unix-like
target: **a compiler macro used as a proxy for an architecture**. It is the most
common single mistake found in this port.

Windows ARM64 uses `__yield()` rather than the `isb` inline assembly the other
ARM targets use, deliberately: inline assembly stops LLVM computing a function's
length for SEH unwind info, which is a hard error here rather than a warning.
The same constraint already forced upb onto its portable path.

## The heap corruption was never Bazel's fault

The stdlib precompile crashed under Bazel with `0xC0000374` (heap corruption)
and `0xC0000409` (fastfail), while the identical command run by hand appeared
to succeed. Both halves of that sentence turned out to be misleading, and the
path to the real bug is worth recording.

**Step one: distrust the sample size.** The "manual run succeeds" claim rested
on one run. Looping it six times gave six crashes — three `0xC0000374`, three
`0xC0000409`. There was never a Bazel-specific bug; there was a nondeterministic
crash and a lucky first roll. The lesson is old but keeps needing to be
relearned: one clean run of a nondeterministic failure proves nothing.

**Step two: notice *when* it dies.** Every crashing run had already written the
complete 3.2 MB `std.mojoc`. The compiler does all of its work correctly and
dies on the way out the door. Crashes at process teardown with completed output
are the signature of allocator trouble in destructors, not of compiler logic
bugs.

**Step three: look at the imports.** `llvm-readobj --coff-imports mojo.exe`
listed no `ucrtbase.dll`, no `api-ms-win-crt-*`, no `vcruntime140.dll` — and
the same for the Globals DLLs. Clang's default for MSVC targets is the *static*
CRT, so mojo.exe, MSupportGlobals.dll and AsyncRTRuntimeGlobals.dll each
carried a private copy of the C runtime, each with its own heap.

That is fatal to this codebase's architecture. Modular builds the Globals
libraries as shared objects precisely so that one allocator serves the whole
process — TCMalloc state, runtime globals, the works. On Linux and macOS a
single libc guarantees it. On Windows with static CRTs, the design inverts:
every module gets its own allocator, and any `std::string`, `shared_ptr`
control block or vector allocated in one module and freed in another goes back
to the wrong heap. The damage is silent until ntdll's heap validation trips,
which is why the exit code varied and why the crash always landed in teardown,
where each module's globals drain at once.

Why silent, even with crash reporting compiled in? Two reasons stacked:
`rules_mojo` sets `MODULAR_CRASH_REPORTING_ENABLED=false` for every compile
action, and `0xC0000374`/`0xC0000409` are raised via `__fastfail`, which
bypasses SEH and vectored handlers entirely. Only a debugger or WER sees them.

**The fix is one flag**: `-fms-runtime-lib=dll` in the toolchain's Windows
compile args. It defines `_MT` and `_DLL`, so the MSVC headers' autolink
pragmas select `msvcrt.lib`/`ucrt.lib` (the import libraries) instead of
`libcmt.lib`/`libucrt.lib`, and every module in the process shares the one
ucrtbase heap — the same topology the code was written against. Verified on a
scratch object before committing to the rebuild: with the flag the object
embeds `DEFAULTLIB:msvcrt`, without it `libcmt` territory. This is also simply
what Windows software does: /MD is the norm for anything shipping an exe with
DLLs.

The cost: the flag changes every compile command line, so the entire C++ tree
rebuilds and the disk cache starts cold.
