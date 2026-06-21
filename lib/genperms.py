#!/usr/bin/env python3
"""Build-time permission-XML generation for the microG installer.

This is the heart of the bootloop-prevention design (design spec section 6.1).
A /system/priv-app on stock Android (API >= 26) is only granted the privileged
permissions that a privapp-permissions allowlist XML *explicitly* lists. Stock
runs in "enforce" mode: if microG REQUESTS a privileged permission that is NOT
in its allowlist, PackageManagerService throws at scan time and the device
boot-loops. So the allowlist must be generated, never copied.

Crucially, an APK manifest lists which permissions are REQUESTED, not which are
"privileged" -- protection levels live in the platform framework manifest
(frameworks/base/core/res/AndroidManifest.xml), not the APK. The allowlist is
therefore an INTERSECTION computed per target API:

    granted = requested(APK)  INTERSECT  privileged_perms(target AOSP API)
            + FAKE_PACKAGE_SIGNATURE   # microG-custom, absent from stock AOSP

Safety rule (spec 6.1): under-listing -> bootloop under enforce; over-listing is
harmless. When uncertain whether a perm is privileged at a given API, KEEP it in
the privileged-perms data file -- prefer the superset.

FAKE_PACKAGE_SIGNATURE is the microG-custom permission that lets GmsCore report
a chosen package signature to apps that check it. It does not exist in stock
AOSP, so it can never appear in privileged_perms -- yet it MUST be granted, so it
is added unconditionally (and only to the GmsCore allowlist by default; callers
that need it elsewhere pass --add-fake-signature).

Behavioral exemptions (allow-in-power-save, allow-unthrottled-location) are NOT
allowlist entries -- they are sysconfig directives and go in a SEPARATE
perms/sysconfig-microg.xml so they never pollute the boot-critical allowlist.

Host-testability: every external/tool dependency is injectable. requested_perms
wraps apkanalyzer/aapt2 but callers (and tests) may pass the requested list
directly; privileged_perms can come from data files, a parsed AOSP manifest, or
an injected set. No real APK is required to exercise the intersection logic.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.dom import minidom

# Canonical name of the microG-custom permission. Some references use the
# org.microg.gms.* form, but GmsCore declares and the platform-style allowlist
# uses android.permission.FAKE_PACKAGE_SIGNATURE; that is what we emit.
FAKE_PACKAGE_SIGNATURE = "android.permission.FAKE_PACKAGE_SIGNATURE"

# Default directory holding the checked-in privileged-perms-<api>.txt data files.
# Resolved relative to this file so it works regardless of the caller's cwd.
DEFAULT_DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# AOSP framework manifest namespace, used when parsing a real core/res manifest.
ANDROID_NS = "http://schemas.android.com/apk/res/android"


class GenPermsError(Exception):
    """Raised on any unrecoverable error during permission generation."""


def _safe_parse(path: Path) -> ET.ElementTree:
    """Parse an XML file with DTD / external-entity resolution disabled.

    Build-time inputs (our own emitted XML, an AOSP manifest from a checked-out
    tree) are trusted, but rejecting DTDs is cheap defence-in-depth against XXE
    and billion-laughs, and keeps us stdlib-only (no defusedxml dependency).

    Implemented by driving expat directly into an ElementTree TreeBuilder: a raw
    expat parser exposes the DOCTYPE / external-entity handlers across Python
    versions (ET.XMLParser stopped surfacing the underlying parser in 3.x).
    Any DOCTYPE aborts the parse; external entities are never resolved.
    """
    import xml.parsers.expat as expat

    # Enable namespace processing so namespaced names round-trip. expat reports
    # them as "uri<sep>local"; we normalize to ElementTree's "{uri}local" Clark
    # notation so AOSP-manifest lookups by {android-ns}name keep working.
    sep = "\t"
    parser = expat.ParserCreate(namespace_separator=sep)
    builder = ET.TreeBuilder()

    def _clark(name: str) -> str:
        if sep in name:
            uri, local = name.split(sep, 1)
            return f"{{{uri}}}{local}"
        return name

    def _reject_doctype(*_args: object) -> None:
        raise GenPermsError("DTD/DOCTYPE not allowed in permission XML")

    def _start(tag: str, attrs: dict[str, str]) -> None:
        builder.start(_clark(tag), {_clark(k): v for k, v in attrs.items()})

    parser.StartDoctypeDeclHandler = _reject_doctype  # type: ignore[assignment]
    # Refuse to resolve external entities -- the XXE fetch primitive.
    parser.ExternalEntityRefHandler = lambda *_a: False  # type: ignore[assignment]
    parser.StartElementHandler = _start
    parser.EndElementHandler = lambda tag: builder.end(_clark(tag))
    parser.CharacterDataHandler = builder.data

    data = path.read_bytes()
    try:
        parser.Parse(data, True)
    except expat.ExpatError as exc:
        raise ET.ParseError(str(exc)) from exc
    return ET.ElementTree(builder.close())


# --------------------------------------------------------------------------- #
# requested(APK): what the APK asks for.
# --------------------------------------------------------------------------- #
def requested_perms_from_apk(apk_path: Path) -> set[str]:
    """Return the permissions an APK REQUESTS (uses-permission), via toolchain.

    Prefers `apkanalyzer manifest permissions`; falls back to
    `aapt2 dump permissions`. Pure I/O -- host tests inject the list instead of
    calling this (see normalize_requested / the --requested-file CLI flag).
    """
    if not apk_path.is_file():
        raise GenPermsError(f"APK not found: {apk_path}")

    apkanalyzer = shutil.which("apkanalyzer")
    if apkanalyzer:
        out = _run([apkanalyzer, "manifest", "permissions", str(apk_path)])
        return _parse_apkanalyzer_permissions(out)

    aapt2 = shutil.which("aapt2")
    if aapt2:
        out = _run([aapt2, "dump", "permissions", str(apk_path)])
        return _parse_aapt2_permissions(out)

    raise GenPermsError(
        "neither apkanalyzer nor aapt2 found on PATH; cannot read APK "
        "permissions. Install Android build-tools, or pass the requested "
        "permissions directly via --requested-file (host/test path)."
    )


def _parse_apkanalyzer_permissions(text: str) -> set[str]:
    """Parse `apkanalyzer manifest permissions` output (one perm per line).

    apkanalyzer prints one bare permission name per line (e.g.
    `android.permission.INTERNET`). We tolerate an optional `uses-permission:`
    label some tool versions emit, and accept any dotted, space-free token as a
    permission name so non-`android.permission.*` custom perms (like microG's
    org.microg.* ones) are not silently dropped.
    """
    perms: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("uses-permission:"):
            line = line.split(":", 1)[1].strip()
        if not line or line.startswith("#"):
            continue
        # A permission name is a dotted token with no whitespace.
        if " " not in line and "." in line:
            perms.add(line)
    return perms


def _parse_aapt2_permissions(text: str) -> set[str]:
    """Parse `aapt2 dump permissions` output: uses-permission: name='...'."""
    perms: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("uses-permission:"):
            # Format: uses-permission: name='android.permission.FOO'
            marker = "name='"
            start = line.find(marker)
            if start != -1:
                start += len(marker)
                end = line.find("'", start)
                if end != -1:
                    perms.add(line[start:end])
    return perms


def normalize_requested(perms: list[str] | set[str]) -> set[str]:
    """Normalize an injected requested-perms list (test path): strip + dedupe."""
    return {p.strip() for p in perms if p and p.strip()}


def read_requested_file(path: Path) -> set[str]:
    """Read a requested-perms list from a file (one perm per line, # comments)."""
    return _read_perm_list_file(path)


# --------------------------------------------------------------------------- #
# privileged_perms(API): which platform perms are "privileged".
# --------------------------------------------------------------------------- #
def load_privileged_perms(
    api: int,
    data_dir: Path = DEFAULT_DATA_DIR,
    extra_apis: tuple[int, ...] = (30,),
) -> set[str]:
    """Load the privileged-perms set for `api`, unioned with `extra_apis`.

    Reads data/privileged-perms-<api>.txt for the target API and unions it with
    the listed extra API files when present (spec 6.1: "union a couple of API
    levels to be safe" -- a perm privileged on an older platform stays grantable
    on devices still running it). Missing extra-API files are skipped silently;
    a missing target-API file is a hard error so a typo never yields an empty,
    bootloop-inducing allowlist.
    """
    apis = {api, *extra_apis}
    perms: set[str] = set()
    target_file = data_dir / f"privileged-perms-{api}.txt"
    if not target_file.is_file():
        raise GenPermsError(
            f"privileged-perms data file not found for target API {api}: "
            f"{target_file}. See data/privileged-perms-30.txt for the format "
            f"and regeneration steps."
        )
    for level in sorted(apis):
        path = data_dir / f"privileged-perms-{level}.txt"
        if path.is_file():
            perms |= _read_perm_list_file(path)
    return perms


def privileged_perms_from_aosp_manifest(manifest_path: Path) -> set[str]:
    """Parse an AOSP core/res AndroidManifest.xml for privileged permissions.

    Returns the names of every <permission> whose android:protectionLevel
    contains the "privileged" flag. This is the same rule the data-file
    regeneration procedure documents; offered so a build with a checked-out AOSP
    tree can compute the set directly instead of relying on the curated file.
    """
    if not manifest_path.is_file():
        raise GenPermsError(f"AOSP manifest not found: {manifest_path}")
    try:
        tree = _safe_parse(manifest_path)
    except ET.ParseError as exc:
        raise GenPermsError(f"failed to parse AOSP manifest {manifest_path}: {exc}")

    name_attr = f"{{{ANDROID_NS}}}name"
    level_attr = f"{{{ANDROID_NS}}}protectionLevel"
    perms: set[str] = set()
    for perm in tree.getroot().iter("permission"):
        level = perm.get(level_attr, "")
        name = perm.get(name_attr, "")
        # protectionLevel is a '|'-joined flag list, e.g. "signature|privileged".
        if name and "privileged" in level.split("|"):
            perms.add(name)
    if not perms:
        raise GenPermsError(
            f"no privileged permissions found in {manifest_path}; is this an "
            f"AOSP core/res AndroidManifest.xml?"
        )
    return perms


def _read_perm_list_file(path: Path) -> set[str]:
    """Read a perm-list text file: one name per line, '#' comments, blanks ok."""
    perms: set[str] = set()
    for raw in path.read_text(encoding="ascii").splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            perms.add(line)
    return perms


# --------------------------------------------------------------------------- #
# The intersection.
# --------------------------------------------------------------------------- #
def compute_granted(
    requested: set[str],
    privileged: set[str],
    add_fake_signature: bool = True,
) -> set[str]:
    """Compute the privapp-permissions allowlist set (the core intersection).

        granted = (requested INTERSECT privileged) + FAKE_PACKAGE_SIGNATURE?

    A requested permission that is NOT privileged is dropped (it is granted by
    other means -- normal/runtime -- and listing it in the privapp allowlist is
    rejected by PMS). A privileged permission the APK does not request is
    irrelevant. FAKE_PACKAGE_SIGNATURE is added when requested (it is microG's
    custom perm, never present in `privileged`, but must be granted).
    """
    granted = requested & privileged
    if add_fake_signature:
        granted.add(FAKE_PACKAGE_SIGNATURE)
    return granted


# --------------------------------------------------------------------------- #
# XML emission.
# --------------------------------------------------------------------------- #
def build_privapp_xml(package: str, perms: set[str]) -> str:
    """Build a privapp-permissions allowlist XML document for one component.

    <permissions>
      <privapp-permissions package="...">
        <permission name="..."/>   (sorted for deterministic, diffable output)
      </privapp-permissions>
    </permissions>
    """
    root = ET.Element("permissions")
    privapp = ET.SubElement(root, "privapp-permissions", {"package": package})
    for name in sorted(perms):
        ET.SubElement(privapp, "permission", {"name": name})
    return _pretty_xml(root)


def build_sysconfig_xml(packages: list[str]) -> str:
    """Build the SEPARATE sysconfig XML carrying behavioral exemptions.

    These are NOT privapp-permissions allowlist entries (spec 6.1): they are
    sysconfig directives that exempt microG from battery/location throttling so
    push and network-location keep working in Doze. Kept out of the allowlist so
    they can never pollute the boot-critical file.

    <permissions>
      <allow-in-power-save package="..."/>
      <allow-unthrottled-location package="..."/>
    </permissions>
    """
    root = ET.Element("permissions")
    for pkg in packages:
        ET.SubElement(root, "allow-in-power-save", {"package": pkg})
        ET.SubElement(root, "allow-unthrottled-location", {"package": pkg})
    return _pretty_xml(root)


def _pretty_xml(root: ET.Element) -> str:
    """Serialize an element tree to indented, ASCII-only XML with a declaration."""
    rough = ET.tostring(root, encoding="unicode")
    parsed = minidom.parseString(rough)
    pretty = parsed.toprettyxml(indent="  ")
    # minidom emits a UTF-8 declaration and blank lines; normalize to plain ASCII.
    lines = [ln for ln in pretty.splitlines() if ln.strip()]
    if lines and lines[0].startswith("<?xml"):
        lines[0] = '<?xml version="1.0" encoding="utf-8"?>'
    return "\n".join(lines) + "\n"


def validate_xml(path: Path) -> None:
    """Validate an emitted XML file with `xmllint --noout` when available.

    A malformed allowlist is as dangerous as a wrong one. When xmllint is
    absent (e.g. minimal host) we fall back to ElementTree parsing so a syntax
    error is still caught rather than silently shipped.
    """
    xmllint = shutil.which("xmllint")
    if xmllint:
        result = subprocess.run(
            [xmllint, "--noout", str(path)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise GenPermsError(
                f"xmllint rejected {path}: {result.stderr.strip()}"
            )
        return
    # Fallback: best-effort well-formedness check without xmllint.
    try:
        _safe_parse(path)
    except ET.ParseError as exc:
        raise GenPermsError(f"malformed XML {path}: {exc}")


# --------------------------------------------------------------------------- #
# Orchestration.
# --------------------------------------------------------------------------- #
def generate_privapp_file(
    package: str,
    requested: set[str],
    privileged: set[str],
    out_path: Path,
    add_fake_signature: bool = True,
    validate: bool = True,
) -> set[str]:
    """Compute the allowlist, write the XML, validate it, return the granted set."""
    granted = compute_granted(requested, privileged, add_fake_signature)
    xml = build_privapp_xml(package, granted)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(xml, encoding="ascii")
    if validate:
        validate_xml(out_path)
    return granted


def generate_sysconfig_file(
    packages: list[str], out_path: Path, validate: bool = True
) -> None:
    """Write the separate sysconfig-microg.xml and validate it."""
    xml = build_sysconfig_xml(packages)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(xml, encoding="ascii")
    if validate:
        validate_xml(out_path)


def _run(cmd: list[str]) -> str:
    """Run a subprocess, returning stdout; raise GenPermsError on failure."""
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise GenPermsError(
            f"command failed ({' '.join(cmd)}): {result.stderr.strip()}"
        )
    return result.stdout


# --------------------------------------------------------------------------- #
# CLI.
# --------------------------------------------------------------------------- #
def _resolve_requested(args: argparse.Namespace) -> set[str]:
    """Pick the requested-perms source: --requested-file (injectable) or --apk."""
    if args.requested_file:
        return read_requested_file(Path(args.requested_file))
    if args.apk:
        return requested_perms_from_apk(Path(args.apk))
    raise GenPermsError("one of --apk or --requested-file is required")


def _resolve_privileged(args: argparse.Namespace) -> set[str]:
    """Pick the privileged-perms source: --aosp-manifest, --priv-file, or data dir."""
    if args.aosp_manifest:
        return privileged_perms_from_aosp_manifest(Path(args.aosp_manifest))
    if args.priv_file:
        return _read_perm_list_file(Path(args.priv_file))
    return load_privileged_perms(args.api, Path(args.data_dir))


def cmd_gen(args: argparse.Namespace) -> int:
    """`gen` subcommand: emit one component's privapp-permissions allowlist."""
    requested = _resolve_requested(args)
    privileged = _resolve_privileged(args)
    granted = generate_privapp_file(
        package=args.package,
        requested=requested,
        privileged=privileged,
        out_path=Path(args.out),
        add_fake_signature=not args.no_fake_signature,
        validate=not args.no_validate,
    )
    dropped = sorted(requested - privileged - {FAKE_PACKAGE_SIGNATURE})
    print(f"wrote {args.out}: {len(granted)} granted for {args.package}")
    if dropped:
        print(f"  dropped (requested but not privileged): {', '.join(dropped)}")
    return 0


def cmd_sysconfig(args: argparse.Namespace) -> int:
    """`sysconfig` subcommand: emit the separate behavioral-exemptions XML."""
    generate_sysconfig_file(
        packages=args.package,
        out_path=Path(args.out),
        validate=not args.no_validate,
    )
    print(f"wrote {args.out}: sysconfig exemptions for {', '.join(args.package)}")
    return 0


def cmd_dump_requested(args: argparse.Namespace) -> int:
    """`dump-requested` subcommand: write an APK's requested perms to a file.

    build.sh runs this ONCE per component so the exact same requested-perms list
    feeds both `gen --requested-file` and the CI invariant (which reads the same
    sidecar). Using one extraction keeps genperms the sole APK reader and removes
    any chance of apkanalyzer/aapt2 output drift between the two consumers.
    """
    apk = Path(args.apk)
    requested = requested_perms_from_apk(apk)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# Requested permissions of {apk.name}, dumped by genperms.py.",
        "# Generated -- DO NOT EDIT. One permission per line.",
    ]
    lines.extend(sorted(requested))
    out_path.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"wrote {out_path}: {len(requested)} requested perms")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="genperms.py",
        description="Generate microG privapp-permissions allowlist XML "
        "(requested INTERSECT privileged + FAKE_PACKAGE_SIGNATURE).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("gen", help="generate one component's allowlist XML")
    src = gen.add_argument_group("requested permissions source (one required)")
    src.add_argument("--apk", help="APK to read requested permissions from")
    src.add_argument(
        "--requested-file",
        help="text file of requested perms (one per line); test/no-APK path",
    )
    gen.add_argument("--package", required=True, help="component package name")
    gen.add_argument(
        "--api", type=int, default=34, help="target AOSP API level (default 34)"
    )
    priv = gen.add_argument_group("privileged-perms source (optional override)")
    priv.add_argument(
        "--data-dir",
        default=str(DEFAULT_DATA_DIR),
        help="dir holding privileged-perms-<api>.txt (default: repo data/)",
    )
    priv.add_argument(
        "--priv-file", help="explicit privileged-perms list file (overrides data dir)"
    )
    priv.add_argument(
        "--aosp-manifest",
        help="AOSP core/res AndroidManifest.xml to derive privileged perms from",
    )
    gen.add_argument("--out", required=True, help="output XML path (perms/<name>.xml)")
    gen.add_argument(
        "--no-fake-signature",
        action="store_true",
        help="do NOT add FAKE_PACKAGE_SIGNATURE (default: always add)",
    )
    gen.add_argument(
        "--no-validate", action="store_true", help="skip xmllint validation"
    )
    gen.set_defaults(func=cmd_gen)

    sysc = sub.add_parser(
        "sysconfig", help="generate the separate behavioral-exemptions XML"
    )
    sysc.add_argument(
        "--package",
        required=True,
        nargs="+",
        help="package(s) to exempt (usually just com.google.android.gms)",
    )
    sysc.add_argument(
        "--out", required=True, help="output path (perms/sysconfig-microg.xml)"
    )
    sysc.add_argument(
        "--no-validate", action="store_true", help="skip xmllint validation"
    )
    sysc.set_defaults(func=cmd_sysconfig)

    dump = sub.add_parser(
        "dump-requested",
        help="write an APK's requested permissions to a file (one per line)",
    )
    dump.add_argument("--apk", required=True, help="APK to read requested perms from")
    dump.add_argument(
        "--out", required=True, help="output sidecar path (e.g. <name>.perms)"
    )
    dump.set_defaults(func=cmd_dump_requested)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except GenPermsError as exc:
        print(f"genperms: error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
