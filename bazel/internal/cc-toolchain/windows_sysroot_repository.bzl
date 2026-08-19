"""Create a local repository describing the MSVC CRT and Windows SDK.

There is no `--sysroot` equivalent for a `*-pc-windows-msvc` target, and
`.bazelrc` sets `--incompatible_strict_action_env`, so clang cannot discover the
toolchain from the environment the way it would in a normal developer shell.
Instead this rule locates the installed Visual Studio and Windows SDK once, at
repository-fetch time, and bakes the resulting include and library directories
into `cc_args` targets.

This is deliberately non-hermetic: it points at whatever MSVC and SDK are
installed on the machine. Microsoft's licensing does not permit redistributing
the CRT headers and import libraries the way the Linux sysroots are
redistributed, so a hermetic Windows sysroot would have to be assembled locally
anyway.
"""

_BUILD_HEADER = """\
load("@rules_cc//cc/toolchains:args.bzl", "cc_args")

package(default_visibility = ["//visibility:public"])
"""

_EMPTY_BUILD = _BUILD_HEADER + """
# Not a Windows host: expose empty args so analysis still succeeds elsewhere.
cc_args(
    name = "includes",
    args = [],
)

cc_args(
    name = "libs",
    args = [],
)
"""

def _norm(path):
    return str(path).replace("\\\\", "/").replace("\\", "/")

def _find_visual_studio(rctx):
    """Return (vc_tools_dir, msvc_version) for the newest MSVC install."""
    program_files = rctx.getenv("ProgramFiles", "C:/Program Files")
    program_files_x86 = rctx.getenv("ProgramFiles(x86)", "C:/Program Files (x86)")

    vswhere = rctx.path(_norm(program_files_x86) + "/Microsoft Visual Studio/Installer/vswhere.exe")
    roots = []
    if vswhere.exists:
        result = rctx.execute([
            str(vswhere),
            "-latest",
            "-products",
            "*",
            "-requires",
            "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
            "-property",
            "installationPath",
        ])
        if result.return_code == 0 and result.stdout.strip():
            roots.append(_norm(result.stdout.strip()))

    if not roots:
        # vswhere is not always present; fall back to scanning the well-known
        # layout, newest edition first.
        base = rctx.path(_norm(program_files) + "/Microsoft Visual Studio")
        if base.exists:
            for version_dir in base.readdir(watch = "no"):
                for edition in version_dir.readdir(watch = "no"):
                    roots.append(_norm(edition))

    for root in sorted(roots, reverse = True):
        tools = rctx.path(root + "/VC/Tools/MSVC")
        if not tools.exists:
            continue
        versions = sorted([child.basename for child in tools.readdir(watch = "no")], reverse = True)
        if versions:
            return root + "/VC/Tools/MSVC/" + versions[0], versions[0]

    return None, None

def _find_windows_sdk(rctx):
    """Return (sdk_root, sdk_version) for the newest installed Windows 10/11 SDK."""
    program_files_x86 = rctx.getenv("ProgramFiles(x86)", "C:/Program Files (x86)")
    root = _norm(program_files_x86) + "/Windows Kits/10"
    include = rctx.path(root + "/Include")
    if not include.exists:
        return None, None

    versions = []
    for child in include.readdir(watch = "no"):
        # A usable SDK has the ucrt headers under its version directory.
        if rctx.path(str(child) + "/ucrt").exists:
            versions.append(child.basename)

    if not versions:
        return None, None
    return root, sorted(versions, reverse = True)[0]

def _windows_sysroot_repository_impl(rctx):
    if not rctx.os.name.startswith("windows"):
        rctx.file("BUILD.bazel", _EMPTY_BUILD)
        return

    vc_dir, msvc_version = _find_visual_studio(rctx)
    if not vc_dir:
        fail("Could not locate an MSVC installation. Install the Visual Studio " +
             "'Desktop development with C++' workload, including the ARM64 build tools.")

    sdk_root, sdk_version = _find_windows_sdk(rctx)
    if not sdk_root:
        fail("Could not locate a Windows 10/11 SDK under '{}/Windows Kits/10'.".format(
            rctx.getenv("ProgramFiles(x86)", "C:/Program Files (x86)"),
        ))

    arch = rctx.attr.target_arch

    includes = [
        vc_dir + "/include",
        "{}/Include/{}/ucrt".format(sdk_root, sdk_version),
        "{}/Include/{}/shared".format(sdk_root, sdk_version),
        "{}/Include/{}/um".format(sdk_root, sdk_version),
        "{}/Include/{}/winrt".format(sdk_root, sdk_version),
    ]

    libs = [
        "{}/lib/{}".format(vc_dir, arch),
        "{}/Lib/{}/ucrt/{}".format(sdk_root, sdk_version, arch),
        "{}/Lib/{}/um/{}".format(sdk_root, sdk_version, arch),
    ]

    for path in includes + libs:
        if not rctx.path(path).exists:
            fail("Expected toolchain directory does not exist: {}\n".format(path) +
                 "The MSVC '{}' build tools and the matching SDK components may not be installed.".format(arch))

    include_args = []
    for path in includes:
        # -imsvc marks these as system headers so third-party warnings stay quiet.
        include_args.append("-imsvc")
        include_args.append(path)

    lib_args = ["-L" + path for path in libs]

    rctx.file("BUILD.bazel", _BUILD_HEADER + """
# MSVC {msvc_version}, Windows SDK {sdk_version}, target {arch}.
# Generated by windows_sysroot_repository; do not edit.

cc_args(
    name = "includes",
    actions = [
        "@rules_cc//cc/toolchains/actions:compile_actions",
    ],
    args = {include_args},
)

cc_args(
    name = "libs",
    actions = [
        "@rules_cc//cc/toolchains/actions:link_actions",
    ],
    args = {lib_args},
)
""".format(
        msvc_version = msvc_version,
        sdk_version = sdk_version,
        arch = arch,
        include_args = repr(include_args),
        lib_args = repr(lib_args),
    ))

windows_sysroot_repository = repository_rule(
    implementation = _windows_sysroot_repository_impl,
    attrs = {
        "target_arch": attr.string(
            default = "arm64",
            doc = "MSVC/SDK library architecture directory name, e.g. arm64 or x64.",
        ),
    },
    environ = [
        "ProgramFiles",
        "ProgramFiles(x86)",
    ],
    local = True,
    configure = True,
)
