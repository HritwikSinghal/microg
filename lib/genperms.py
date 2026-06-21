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

# Default directory holding the checked-in platform-perms-<api>.txt data files.
# Resolved relative to this file so it works regardless of the caller's cwd.
DEFAULT_DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# API levels we ship pinned AOSP platform-perms tables for. A target --api N
# unions every available level <= N (see load_platform_perms): a perm privileged
# on ANY covered level, if requested, gets allowlisted (harmless where it is not
# privileged). These four cover the realistic stock-Android install base.
PINNED_APIS: tuple[int, ...] = (30, 33, 34, 35)

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
# platform_perms(API): the AUTHORITATIVE per-API platform permission table.
#
# The data model is a single file per API, data/platform-perms-<api>.txt, listing
# EVERY platform <permission> with its raw AOSP protectionLevel, one entry per
# line as "<name><TAB><level>". From this ONE table genperms derives BOTH:
#   - the PRIVILEGED set: names whose protectionLevel flag list contains
#     "privileged" (what a /system/priv-app may be allowlisted for); and
#   - the PLATFORM-ALL set: every platform permission name (used by the invariant
#     to fail-closed on a requested android.permission.* it cannot classify).
#
# The old privileged-perms-<api>.txt files (a name-only privileged subset) are
# superseded: a hand-curated privileged subset can only support the under-list
# check, never the unknown-permission guard, because it cannot say whether an
# UNlisted perm is a harmless normal perm or a privileged one we forgot. Deriving
# both sets from the full AOSP table is what makes the guard authoritative.
# --------------------------------------------------------------------------- #
def _is_privileged_level(level: str) -> bool:
    """True if a raw protectionLevel string carries the 'privileged' flag.

    protectionLevel is a '|'-joined flag list, e.g. "signature|privileged" or
    "signature|privileged|development". A bare base level ("normal", "signature",
    "dangerous") is not privileged.
    """
    return "privileged" in level.split("|")


def load_platform_perms(paths: list[Path]) -> dict[str, str]:
    """Load and union platform-perms tables into a name->protectionLevel map.

    Each path is a data/platform-perms-<api>.txt file: "<name><TAB><level>" per
    line, '#' comments and blanks ignored. When the same permission appears in
    more than one API table with differing levels, the levels are merged by
    UNION of their '|'-flags so the privileged flag is never lost across levels
    (under-listing bootloops; over-listing is harmless -- spec 6.1).
    """
    # Order-preserving union: keep flags in first-seen order (so a single source
    # round-trips verbatim and matches the raw AOSP parse path) while still
    # deduping and never dropping the privileged flag across merged levels.
    merged: dict[str, list[str]] = {}
    for path in paths:
        if not path.is_file():
            continue
        for raw in path.read_text(encoding="ascii").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "\t" not in line:
                raise GenPermsError(
                    f"malformed platform-perms line in {path} (expected "
                    f"'<name><TAB><level>'): {line!r}"
                )
            name, level = line.split("\t", 1)
            name = name.strip()
            flags = merged.setdefault(name, [])  # registers empty-level names too
            for f in level.strip().split("|"):
                if f and f not in flags:
                    flags.append(f)
    return {name: "|".join(flags) for name, flags in merged.items()}


def privileged_names(table: dict[str, str]) -> set[str]:
    """The privileged-name set derived from a platform-perms table."""
    return {name for name, level in table.items() if _is_privileged_level(level)}


def all_platform_names(table: dict[str, str]) -> set[str]:
    """The platform-all (every-name) set derived from a platform-perms table."""
    return set(table.keys())


def _platform_perms_paths(api: int, data_dir: Path) -> list[Path]:
    """Resolve the platform-perms-<level>.txt paths to union for a target API.

    Union semantics (spec 6.1): every PINNED level <= api whose file exists. A
    missing target-API table is a hard error so a typo never yields an empty,
    bootloop-inducing allowlist; lower-level files are optional. A target API
    ABOVE every pinned level is also a hard error: silently reusing the newest
    pinned table for an unpinned API could under-list a perm that became
    privileged later, which bootloops under enforce -- fail loud so the pinned
    tables get extended instead.
    """
    if api > max(PINNED_APIS):
        raise GenPermsError(
            f"target API {api} is above every pinned platform-perms table "
            f"(pinned levels are {', '.join(map(str, PINNED_APIS))}); add a "
            f"data/platform-perms-{api}.txt via extract-perms rather than "
            f"reusing stale data."
        )
    levels = sorted(level for level in PINNED_APIS if level <= api)
    if not levels:
        raise GenPermsError(
            f"no pinned platform-perms tables at or below target API {api}; "
            f"pinned levels are {', '.join(map(str, PINNED_APIS))}."
        )
    target = max(levels)
    target_file = data_dir / f"platform-perms-{target}.txt"
    if not target_file.is_file():
        raise GenPermsError(
            f"platform-perms data file not found for API {target}: "
            f"{target_file}. See data/platform-perms-30.txt for the format and "
            f"the extract-perms regeneration command."
        )
    return [data_dir / f"platform-perms-{level}.txt" for level in levels]


def load_platform_table(api: int, data_dir: Path = DEFAULT_DATA_DIR) -> dict[str, str]:
    """Load the unioned platform-perms table for a target API from the data dir."""
    return load_platform_perms(_platform_perms_paths(api, data_dir))


def load_privileged_perms(
    api: int,
    data_dir: Path = DEFAULT_DATA_DIR,
) -> set[str]:
    """Load the privileged-perms set for `api` from the unioned platform table.

    Reads data/platform-perms-<api>.txt (and lower pinned levels) and derives the
    privileged set as the names whose protectionLevel carries "privileged". A
    perm privileged on ANY covered level is included (harmless where it is not).
    """
    return privileged_names(load_platform_table(api, data_dir))


def platform_table_from_aosp_manifest(manifest_path: Path) -> dict[str, str]:
    """Parse an AOSP core/res AndroidManifest.xml into a name->level table.

    Returns EVERY <permission> with its raw android:protectionLevel string (empty
    string if the attribute is absent). This is the authoritative source from
    which both the privileged set and the platform-all set are derived; the
    checked-in data files are generated from exactly this via `extract-perms`.
    """
    if not manifest_path.is_file():
        raise GenPermsError(f"AOSP manifest not found: {manifest_path}")
    try:
        tree = _safe_parse(manifest_path)
    except ET.ParseError as exc:
        raise GenPermsError(f"failed to parse AOSP manifest {manifest_path}: {exc}")

    name_attr = f"{{{ANDROID_NS}}}name"
    level_attr = f"{{{ANDROID_NS}}}protectionLevel"
    table: dict[str, str] = {}
    for perm in tree.getroot().iter("permission"):
        name = perm.get(name_attr, "")
        level = perm.get(level_attr, "")
        if name:
            table[name] = level
    if not table:
        raise GenPermsError(
            f"no <permission> entries found in {manifest_path}; is this an "
            f"AOSP core/res AndroidManifest.xml?"
        )
    return table


def privileged_perms_from_aosp_manifest(manifest_path: Path) -> set[str]:
    """Parse an AOSP manifest for privileged permission names (convenience).

    Thin wrapper over platform_table_from_aosp_manifest + privileged_names, kept
    so a build with a checked-out AOSP tree can compute the privileged set
    directly. Raises if the manifest declares zero privileged perms (a sign the
    wrong file was passed).
    """
    perms = privileged_names(platform_table_from_aosp_manifest(manifest_path))
    if not perms:
        raise GenPermsError(
            f"no privileged permissions found in {manifest_path}; is this an "
            f"AOSP core/res AndroidManifest.xml?"
        )
    return perms


def render_platform_perms_file(table: dict[str, str], api: int) -> str:
    """Render a name->level table as a checked-in platform-perms-<api>.txt body.

    Documented header (source tag is filled by the regenerate command, recorded
    by whoever runs extract-perms), then one "<name><TAB><level>" entry per line,
    sorted by name for deterministic, diffable output. ASCII only.
    """
    header = [
        f"# Platform permissions -- AOSP API {api}.",
        "#",
        "# WHAT THIS IS",
        "# Every platform-defined <permission> from the AOSP framework manifest",
        "# (frameworks/base/core/res/AndroidManifest.xml) for this API, with its",
        "# raw protectionLevel. Format: one entry per line, '<name><TAB><level>'.",
        "# '#' comments and blank lines are ignored. Sorted by name.",
        "#",
        "# genperms.py derives BOTH sets from this single table:",
        "#   - privileged set = names whose protectionLevel contains 'privileged'",
        "#     (signature|privileged, signature|privileged|development, ...);",
        "#   - platform-all set = every name here (the invariant's fail-closed",
        "#     unknown-permission guard rejects any requested android.permission.*",
        "#     that is absent from this set across all pinned APIs).",
        "#",
        "# HOW TO REGENERATE (per target API on an AOSP bump)",
        "# Fetch the AOSP core/res AndroidManifest.xml at the platform release tag",
        "# from aosp-mirror/platform_frameworks_base, then run extract-perms:",
        "#   curl -fsSL \\",
        "#     https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/<TAG>/core/res/AndroidManifest.xml \\",
        "#     -o /tmp/AndroidManifest-<api>.xml",
        f"#   python3 lib/genperms.py extract-perms --aosp-manifest /tmp/AndroidManifest-{api}.xml \\",
        f"#     --api {api} --out data/platform-perms-{api}.txt",
        "#",
        "# SAFETY NOTE (design spec 6.1): under-listing a privileged perm bootloops",
        "# a device under enforce; over-listing is harmless. genperms.py unions all",
        "# pinned API tables <= the target API, so a perm privileged on any covered",
        "# level stays grantable.",
        "#",
    ]
    body = [f"{name}\t{level}" for name, level in sorted(table.items())]
    return "\n".join(header + body) + "\n"


def write_platform_perms_file(table: dict[str, str], api: int, out_path: Path) -> None:
    """Write a generated platform-perms-<api>.txt to disk (ASCII)."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(render_platform_perms_file(table, api), encoding="ascii")


def _read_perm_list_file(path: Path) -> set[str]:
    """Read a perm-list text file: one name per line, '#' comments, blanks ok.

    Used for the name-only requested-perms sidecars and the legacy --priv-file
    test-injection path (a privileged subset by name, with no level column).
    """
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
      <allow-in-data-usage-save package="..."/>
      <allow-unthrottled-location package="..."/>
    </permissions>

    These mirror the three entries microG ships in its canonical
    sysconfig-com.google.android.gms.xml: allow-in-power-save (Doze exemption for
    the persistent GCM/MCS connection), allow-in-data-usage-save (Data Saver
    background-network exemption -- without it push is throttled under Data
    Saver), and allow-unthrottled-location (location-request throttling exemption).
    """
    root = ET.Element("permissions")
    for pkg in packages:
        ET.SubElement(root, "allow-in-power-save", {"package": pkg})
        ET.SubElement(root, "allow-in-data-usage-save", {"package": pkg})
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
    """Pick the privileged-perms source for `gen`.

    Precedence: --aosp-manifest (derive from a full manifest) > --priv-file (a
    name-only privileged list, for test injection) > the data dir
    (platform-perms-<api>.txt tables). The data-dir and manifest paths both yield
    the authoritative privileged set; --priv-file is a deliberate test-only
    shortcut that supplies privileged names directly without level data.
    """
    if args.aosp_manifest:
        return privileged_perms_from_aosp_manifest(Path(args.aosp_manifest))
    if args.priv_file:
        return _read_perm_list_file(Path(args.priv_file))
    return load_privileged_perms(args.api, Path(args.data_dir))


def cmd_extract_perms(args: argparse.Namespace) -> int:
    """`extract-perms` subcommand: AOSP manifest -> platform-perms-<api>.txt.

    Parses every <permission>/protectionLevel from a fetched AOSP core/res
    AndroidManifest.xml and writes the sorted name<TAB>level table with the
    documented header. This makes the checked-in data reproducible: the data
    files are never hand-edited, only regenerated from a pinned AOSP tag.
    """
    table = platform_table_from_aosp_manifest(Path(args.aosp_manifest))
    out_path = Path(args.out)
    write_platform_perms_file(table, args.api, out_path)
    priv = len(privileged_names(table))
    print(
        f"wrote {out_path}: {len(table)} platform perms "
        f"({priv} privileged) for API {args.api}"
    )
    return 0


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
        help="dir holding platform-perms-<api>.txt (default: repo data/)",
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

    extract = sub.add_parser(
        "extract-perms",
        help="parse an AOSP manifest into a platform-perms-<api>.txt table",
    )
    extract.add_argument(
        "--aosp-manifest",
        required=True,
        help="AOSP core/res AndroidManifest.xml to extract every <permission> from",
    )
    extract.add_argument(
        "--api", type=int, required=True, help="API level this manifest is for"
    )
    extract.add_argument(
        "--out", required=True, help="output data file (data/platform-perms-<api>.txt)"
    )
    extract.set_defaults(func=cmd_extract_perms)
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
