"""Repository rule vendoring an Apple toolchain (Command Line Tools).

The resulting repository mirrors the layout of
`/Library/Developer/CommandLineTools`:

    usr/        The toolchain itself (clang, swiftc, ld, ...).
    SDKs/       macOS SDKs bundled with the toolchain.
    Library/    Frameworks and support files bundled with the toolchain.

The toolchain can come from three kinds of sources:

  * `path`: an existing Command Line Tools style directory on disk.
  * `url` pointing at a Command Line Tools `.dmg` as downloaded from Apple
    (or re-hosted by your organization). The installer packages inside the
    image are expanded without being installed system-wide.
  * `url` pointing at a plain archive (`.tar.gz`, `.zip`, ...) containing a
    Command Line Tools style directory, for organizations that re-host
    repackaged toolchains.
"""

load(
    ":utils.bzl",
    "APPLE_SLA_ENV",
    "read_sdk_settings",
    "require_apple_sla",
)

_BUILD = """\
package(default_visibility = ["//visibility:public"])

exports_files(["MARKER"])
"""

def _extract_dmg(rctx, dmg_name):
    """Expands the Command Line Tools installer pkgs from a mounted dmg."""

    # Mount outside of the repository directory; Bazel's repository machinery
    # cannot handle a read-only mount point appearing inside the repository.
    result = rctx.execute(["/usr/bin/mktemp", "-d", "/tmp/hermetic_apple_clt.XXXXXX"])
    if result.return_code != 0:
        fail("Failed to create temporary mount directory: {}".format(result.stderr))
    mount_dir = result.stdout.strip()
    result = rctx.execute([
        "/usr/bin/hdiutil",
        "attach",
        "-nobrowse",
        "-readonly",
        "-mountrandom",
        mount_dir,
        dmg_name,
    ], timeout = 600)
    if result.return_code != 0:
        fail("Failed to attach {}: {}".format(dmg_name, result.stderr))

    mount_point = None
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if parts and parts[-1].startswith("/"):
            mount_point = parts[-1].strip()
    if not mount_point:
        fail("Could not determine mount point from hdiutil output:\n" + result.stdout)

    # Note: only inspect the (temporary) mount point with subprocesses, never
    # rctx.path(...); otherwise Bazel records the mount point as an input to
    # this repository and refuses to reuse it once the image is detached.
    result = rctx.execute(["/bin/sh", "-c", "ls '{}'/*.pkg".format(mount_point)])
    pkgs = result.stdout.splitlines() if result.return_code == 0 else []
    if len(pkgs) != 1:
        rctx.execute(["/usr/bin/hdiutil", "detach", mount_point])
        fail("Expected exactly one .pkg in {}, found {}".format(dmg_name, pkgs))

    rctx.report_progress("Expanding {}".format(pkgs[0]))
    result = rctx.execute([
        "/usr/sbin/pkgutil",
        "--expand-full",
        pkgs[0],
        "expanded",
    ], timeout = 3600)
    rctx.execute(["/usr/bin/hdiutil", "detach", mount_point])
    rctx.execute(["/bin/rm", "-rf", mount_dir])
    if result.return_code != 0:
        fail("Failed to expand {}: {}".format(pkgs[0], result.stderr))

    # Each component package's payload is rooted at /, with the Command Line
    # Tools content under Library/Developer/CommandLineTools. Merge all of the
    # payloads into the repository root.
    rctx.report_progress("Merging Command Line Tools payloads")
    for entry in rctx.path("expanded").readdir():
        if not entry.basename.endswith(".pkg"):
            continue
        payload = entry.get_child("Payload", "Library", "Developer", "CommandLineTools")
        if not payload.exists:
            continue
        result = rctx.execute(["/usr/bin/ditto", str(payload), "."], timeout = 3600)
        if result.return_code != 0:
            fail("Failed to merge payload {}: {}".format(payload, result.stderr))

    rctx.delete("expanded")
    rctx.delete(dmg_name)

def _write_toolchain_info(rctx):
    """Records the versions of the macOS SDKs bundled with the toolchain."""
    info = {}
    sdks_dir = rctx.path("SDKs")
    if sdks_dir.exists:
        for sdk in sdks_dir.readdir():
            if sdk.basename != "MacOSX.sdk":
                continue
            settings = read_sdk_settings(rctx, sdk)
            info["macosx"] = {"version": settings.get("Version")}
    rctx.file("toolchain_info.json", json.encode_indent(info) + "\n")

def _apple_toolchain_repository_impl(rctx):
    require_apple_sla(rctx, "the Apple Command Line Tools")

    if rctx.attr.path:
        if rctx.attr.url:
            fail("apple.toolchain(name = {}): path and url are mutually exclusive".format(
                repr(rctx.attr.name),
            ))
        root = rctx.path(rctx.attr.path)
        if not root.exists:
            fail("apple.toolchain(name = {}): path {} does not exist".format(
                repr(rctx.attr.name),
                rctx.attr.path,
            ))
        for entry in root.readdir():
            rctx.symlink(entry, entry.basename)
    elif rctx.attr.url:
        is_dmg = rctx.attr.url.endswith(".dmg")
        if is_dmg:
            rctx.report_progress("Downloading {}".format(rctx.attr.url))
            rctx.download(
                url = rctx.attr.url,
                output = "clt.dmg",
                sha256 = rctx.attr.sha256,
            )
            _extract_dmg(rctx, "clt.dmg")
        else:
            rctx.download_and_extract(
                url = rctx.attr.url,
                sha256 = rctx.attr.sha256,
                stripPrefix = rctx.attr.strip_prefix,
            )
    else:
        fail("apple.toolchain(name = {}): either path or url is required".format(
            repr(rctx.attr.name),
        ))

    if not rctx.path("usr/bin/clang").exists:
        fail(("apple.toolchain(name = {}): the toolchain does not contain " +
              "usr/bin/clang; expected a Command Line Tools style layout").format(
            repr(rctx.attr.name),
        ))

    _write_toolchain_info(rctx)
    rctx.file("MARKER", "")
    rctx.file("BUILD.bazel", _BUILD)

apple_toolchain_repository = repository_rule(
    doc = "Vendors an Apple Command Line Tools style toolchain.",
    environ = [APPLE_SLA_ENV],
    implementation = _apple_toolchain_repository_impl,
    attrs = {
        "path": attr.string(
            doc = "Absolute path to an existing Command Line Tools directory.",
        ),
        "url": attr.string(
            doc = "URL of a Command Line Tools .dmg or re-hosted archive.",
        ),
        "sha256": attr.string(
            doc = "SHA-256 of the downloaded file.",
        ),
        "strip_prefix": attr.string(
            doc = "Prefix to strip when extracting a plain archive.",
        ),
    },
)
