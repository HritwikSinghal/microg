#!/usr/bin/env python3
"""CI invariant gates -- the permanent bootloop cure (design spec section 6.2).

These checks run in CI on every build. Their job is to make a mismatched microG
bump literally UNBUILDABLE rather than letting it silently ship a bootloop. Two
gates:

1. permission_invariant
   For every bundled component:
     a. requested_privileged (the perms the APK requests that ARE privileged for
        the target API) MUST be a SUBSET of the generated privapp-permissions
        allowlist. If the APK starts requesting a new privileged permission that
        genperms did not allowlist, stock "enforce" mode boot-loops -- so this
        fails the build with a precise diff instead.
     b. Every entry in a component's default-permissions file MUST actually be
        declared/requested by the APK. A default-permissions grant for a perm the
        app does not request is dead config at best and wrong at worst.
   All generated XML is validated with `xmllint --noout`.

2. signer_cert_gate
   Fails if any component's signer_cert_sha256 changed between the old and new
   manifest.toml. A new signing key on a /system/priv-app install path is a
   security event, not a version bump (spec decision log / 6.2). The bump tool
   also enforces this; this is the reusable CI-side check.

Like genperms, every input is injectable so the logic is host-testable with tiny
hand-written fixtures and no real APKs: requested perms come from <name>.perms
sidecar files (or are passed directly), the allowlist is read from the emitted
perms/<name>.xml, and the signer gate operates on parsed TOML dicts.
"""

from __future__ import annotations

import argparse
import sys
import tomllib
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

# Reuse the single source of truth for privileged-perms loading, the FAKE perm,
# the safe XML parser, and xmllint validation.
import genperms

FAKE_PACKAGE_SIGNATURE = genperms.FAKE_PACKAGE_SIGNATURE


class InvariantError(Exception):
    """Raised when a CI gate detects an unrecoverable configuration error."""


@dataclass
class Violation:
    """A single invariant violation, formatted into a precise CI diff line."""

    component: str
    kind: str
    detail: str

    def __str__(self) -> str:
        return f"[{self.component}] {self.kind}: {self.detail}"


@dataclass
class CheckResult:
    """Aggregate result of a gate run: ok flag + the list of violations."""

    violations: list[Violation] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.violations

    def report(self) -> str:
        if self.ok:
            return "OK"
        return "\n".join(str(v) for v in self.violations)


# --------------------------------------------------------------------------- #
# Reading the generated allowlist back.
# --------------------------------------------------------------------------- #
def read_allowlist_xml(path: Path) -> set[str]:
    """Read the granted permission names from a generated privapp-permissions XML.

    Validates the file first (xmllint when available; safe-parser fallback) so a
    malformed allowlist is caught here too, then extracts every
    <permission name="..."/> under <privapp-permissions>.
    """
    if not path.is_file():
        raise InvariantError(f"allowlist XML not found: {path}")
    genperms.validate_xml(path)
    tree = genperms._safe_parse(path)
    name_attr = "name"
    perms: set[str] = set()
    for perm in tree.getroot().iter("permission"):
        name = perm.get(name_attr)
        if name:
            perms.add(name)
    return perms


# --------------------------------------------------------------------------- #
# Gate 1: permission invariant.
# --------------------------------------------------------------------------- #
def check_permission_invariant(
    component: str,
    requested: set[str],
    privileged: set[str],
    allowlist: set[str],
    default_perms: set[str] | None = None,
) -> CheckResult:
    """Assert the permission invariant for one component (spec 6.2).

    a. requested_privileged = requested INTERSECT privileged  MUST be subset of
       allowlist. FAKE_PACKAGE_SIGNATURE is exempt from the privileged side (it
       is microG-custom, never in the platform privileged set) -- but if the APK
       requests it, the allowlist must still carry it, so it is folded into the
       required set.
    b. default_perms MUST be subset of requested (no granting a perm the app does
       not even ask for).
    """
    result = CheckResult()

    requested_privileged = requested & privileged
    if FAKE_PACKAGE_SIGNATURE in requested:
        requested_privileged = requested_privileged | {FAKE_PACKAGE_SIGNATURE}

    missing = requested_privileged - allowlist
    if missing:
        result.violations.append(
            Violation(
                component=component,
                kind="under-listed allowlist (would BOOTLOOP under enforce)",
                detail=(
                    "requested privileged perms missing from allowlist: "
                    + ", ".join(sorted(missing))
                ),
            )
        )

    if default_perms:
        undeclared = default_perms - requested
        if undeclared:
            result.violations.append(
                Violation(
                    component=component,
                    kind="default-permissions not requested by APK",
                    detail=(
                        "default-permissions entries the APK never requests: "
                        + ", ".join(sorted(undeclared))
                    ),
                )
            )

    return result


# --------------------------------------------------------------------------- #
# Gate 2: signer-cert gate.
# --------------------------------------------------------------------------- #
def _index_manifest_by_name(manifest: dict) -> dict[str, dict]:
    """Index a parsed manifest.toml's [[apk]] entries by component name."""
    entries = manifest.get("apk", [])
    indexed: dict[str, dict] = {}
    for entry in entries:
        name = entry.get("name")
        if not name:
            raise InvariantError("manifest [[apk]] entry missing 'name'")
        indexed[name] = entry
    return indexed


def signer_cert_gate(old_manifest: dict, new_manifest: dict) -> CheckResult:
    """Fail if any component's signer_cert_sha256 changed (spec 6.2).

    A signer change on a privileged-app install path is a security event, never
    an auto-bump. Only components present in BOTH manifests are compared: a newly
    added component has no prior cert to diff, and a removed one is irrelevant.
    Placeholder/non-pinned values ("n-a-framework-jar", "TODO-phase2") are
    compared verbatim -- if such a placeholder changes that is still a signal.
    """
    result = CheckResult()
    old_idx = _index_manifest_by_name(old_manifest)
    new_idx = _index_manifest_by_name(new_manifest)

    for name, new_entry in new_idx.items():
        old_entry = old_idx.get(name)
        if old_entry is None:
            continue  # newly added component; nothing to diff against.
        old_cert = old_entry.get("signer_cert_sha256", "")
        new_cert = new_entry.get("signer_cert_sha256", "")
        if old_cert != new_cert:
            result.violations.append(
                Violation(
                    component=name,
                    kind="signer_cert_sha256 changed (SECURITY EVENT, never auto-bump)",
                    detail=f"{old_cert!r} -> {new_cert!r}",
                )
            )
    return result


# --------------------------------------------------------------------------- #
# Filesystem wiring for the CLI: map components -> APK requested perms + XML.
# --------------------------------------------------------------------------- #
def _load_toml(path: Path) -> dict:
    """Parse a TOML file, raising InvariantError on failure."""
    if not path.is_file():
        raise InvariantError(f"TOML file not found: {path}")
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except tomllib.TOMLDecodeError as exc:
        raise InvariantError(f"failed to parse {path}: {exc}")


def _requested_for_component(
    name: str, apks_dir: Path, apk_asset: str | None
) -> set[str]:
    """Resolve a component's requested perms for CI.

    Prefers a checked-in/CI-emitted sidecar <name>.perms (one perm per line) next
    to the APK so the invariant can run without re-invoking apkanalyzer; falls
    back to reading the real APK via genperms when only the binary is present.
    """
    sidecar = apks_dir / f"{name}.perms"
    if sidecar.is_file():
        return genperms.read_requested_file(sidecar)
    if apk_asset:
        apk_path = apks_dir / Path(apk_asset).name
        if apk_path.is_file():
            return genperms.requested_perms_from_apk(apk_path)
    raise InvariantError(
        f"no requested-perms source for component {name!r}: expected sidecar "
        f"{sidecar} or an APK in {apks_dir}"
    )


def run_check_perms(
    manifest_path: Path,
    perms_dir: Path,
    apks_dir: Path,
    api: int,
    data_dir: Path,
) -> CheckResult:
    """CI entry: run the permission invariant for every non-framework component.

    framework components (type=framework, e.g. MapsV1) are shared-lib JARs with
    no privapp-permissions allowlist, so they are skipped here.
    """
    manifest = _load_toml(manifest_path)
    privileged = genperms.load_privileged_perms(api, data_dir)
    aggregate = CheckResult()

    for entry in manifest.get("apk", []):
        name = entry.get("name")
        if not name:
            raise InvariantError("manifest [[apk]] entry missing 'name'")
        if entry.get("type") == "framework":
            continue
        # Deferred components (no url) are not bundled, so nothing to check.
        if entry.get("url", "") == "":
            continue

        # Allowlist filename matches the on-device contract emitted by
        # manifest.py (perms/<lowercased-name>.xml) -- the same file shipped in
        # the ZIP and referenced by components.conf.
        allowlist_path = perms_dir / f"{name.lower()}.xml"
        if not allowlist_path.is_file():
            aggregate.violations.append(
                Violation(
                    component=name,
                    kind="missing generated allowlist",
                    detail=f"expected {allowlist_path} (genperms not run?)",
                )
            )
            continue

        requested = _requested_for_component(name, apks_dir, entry.get("url"))
        allowlist = read_allowlist_xml(allowlist_path)

        default_path = perms_dir / f"default-permissions-{name.lower()}.xml"
        default_perms = (
            _read_default_permissions(default_path)
            if default_path.is_file()
            else None
        )

        component_result = check_permission_invariant(
            component=name,
            requested=requested,
            privileged=privileged,
            allowlist=allowlist,
            default_perms=default_perms,
        )
        aggregate.violations.extend(component_result.violations)

    return aggregate


def _read_default_permissions(path: Path) -> set[str]:
    """Read permission names from an AOSP default-permissions XML.

    Shape: <exceptions><exception package="..."><permission name="..." .../>...
    We only need the set of permission names referenced.
    """
    genperms.validate_xml(path)
    tree = genperms._safe_parse(path)
    perms: set[str] = set()
    for perm in tree.getroot().iter("permission"):
        name = perm.get("name")
        if name:
            perms.add(name)
    return perms


# --------------------------------------------------------------------------- #
# CLI.
# --------------------------------------------------------------------------- #
def cmd_check_perms(args: argparse.Namespace) -> int:
    result = run_check_perms(
        manifest_path=Path(args.manifest),
        perms_dir=Path(args.perms_dir),
        apks_dir=Path(args.apks_dir),
        api=args.api,
        data_dir=Path(args.data_dir),
    )
    if result.ok:
        print("permission invariant: OK")
        return 0
    print("permission invariant: FAILED", file=sys.stderr)
    print(result.report(), file=sys.stderr)
    return 1


def cmd_check_signer(args: argparse.Namespace) -> int:
    old = _load_toml(Path(args.old))
    new = _load_toml(Path(args.new))
    result = signer_cert_gate(old, new)
    if result.ok:
        print("signer-cert gate: OK")
        return 0
    print("signer-cert gate: FAILED", file=sys.stderr)
    print(result.report(), file=sys.stderr)
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="invariant.py",
        description="microG installer CI invariant gates (bootloop + signer).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    perms = sub.add_parser(
        "check-perms", help="run the permission invariant over generated allowlists"
    )
    perms.add_argument(
        "--manifest", default="manifest.toml", help="manifest.toml path"
    )
    perms.add_argument(
        "--perms-dir", default="perms", help="dir of generated allowlist XML"
    )
    perms.add_argument(
        "--apks-dir",
        default="apks",
        help="dir of APKs and/or <name>.perms sidecars",
    )
    perms.add_argument(
        "--api", type=int, default=34, help="target AOSP API level (default 34)"
    )
    perms.add_argument(
        "--data-dir",
        default=str(genperms.DEFAULT_DATA_DIR),
        help="dir of privileged-perms-<api>.txt (default: repo data/)",
    )
    perms.set_defaults(func=cmd_check_perms)

    signer = sub.add_parser(
        "check-signer", help="fail if any signer_cert_sha256 changed between manifests"
    )
    signer.add_argument("--old", required=True, help="previous manifest.toml")
    signer.add_argument("--new", required=True, help="new manifest.toml")
    signer.set_defaults(func=cmd_check_signer)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except (InvariantError, genperms.GenPermsError) as exc:
        print(f"invariant: error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
