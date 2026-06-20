#!/usr/bin/env python3
"""Parse manifest.toml and emit the slim install-time components.conf.

Two manifests, two audiences (design spec section 5.4):

  manifest.toml  -- build-time source of truth (urls / hashes / signer certs).
  components.conf -- generated, slim row table the on-device customize.sh reads.

This module owns the parse + emit half. It NEVER touches the network and never
downloads an APK; it only reads the pinned facts and projects them down to the
columns the device needs. Requires Python 3.11+ (stdlib ``tomllib``); the build
runs in CI where a modern Python is guaranteed.

CLI:
  python3 lib/manifest.py emit-conf [--out PATH] [--manifest PATH]
  python3 lib/manifest.py list      [--manifest PATH]

The functions are importable (build.sh consumes ``list`` as TSV).
"""

from __future__ import annotations

import argparse
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Final

# Sentinel meaning "no real APK hash pinned yet". build.sh refuses to build
# while a non-deferred component still carries this.
PENDING_BUMP: Final[str] = "PENDING-BUMP"

SCHEMA_VERSION_SUPPORTED: Final[int] = 1

# Default locations, resolved relative to the repo root (this file is in lib/).
_REPO_ROOT: Final[Path] = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST: Final[Path] = _REPO_ROOT / "manifest.toml"
DEFAULT_COMPONENTS_CONF: Final[Path] = _REPO_ROOT / "components.conf"


@dataclass(frozen=True)
class Apk:
    """One [[apk]] entry from manifest.toml, with all fields validated."""

    name: str
    package: str
    type: str  # "app" | "framework"
    partition: str
    version_code: int
    source: str  # "github" | "fdroid"
    url: str
    sha256: str
    signer_cert_sha256: str
    conflicts: tuple[str, ...]

    @property
    def is_deferred(self) -> bool:
        """A component with no resolvable url is deferred (e.g. Phonesky).

        Deferred components are carried in manifest.toml for documentation and
        future phases, but are skipped by both tools/bump and the
        components.conf emitter. An empty url is the single, explicit marker --
        see the Phonesky entry in manifest.toml.
        """
        return self.url.strip() == ""

    @property
    def is_framework(self) -> bool:
        return self.type == "framework"

    @property
    def asset(self) -> str:
        """On-device asset path for this component.

        framework -> apks/maps.jar (a shared-library JAR, not an APK).
        app       -> apks/<name>.apk.
        """
        if self.is_framework:
            return "apks/maps.jar"
        return f"apks/{self.name}.apk"

    @property
    def perms(self) -> str:
        """Permission-XML path: perms/<lowercased-name>.xml."""
        return f"perms/{self.name.lower()}.xml"


class ManifestError(Exception):
    """Raised when manifest.toml is malformed or violates the schema."""


_VALID_TYPES: Final[frozenset[str]] = frozenset({"app", "framework"})
_VALID_SOURCES: Final[frozenset[str]] = frozenset({"github", "fdroid"})
_REQUIRED_STR_FIELDS: Final[tuple[str, ...]] = (
    "name",
    "package",
    "type",
    "partition",
    "source",
    "sha256",
    "signer_cert_sha256",
)


def _coerce_apk(raw: dict[str, object], index: int) -> Apk:
    """Validate one raw [[apk]] table and build a frozen Apk.

    ``url`` is allowed to be empty (deferred marker); every other string field
    must be present and non-empty. ``version_code`` must be an int.
    """
    where = f"[[apk]] #{index} (name={raw.get('name', '?')!r})"

    for field in _REQUIRED_STR_FIELDS:
        value = raw.get(field)
        if not isinstance(value, str) or value == "":
            raise ManifestError(
                f"{where}: field {field!r} must be a non-empty string, got {value!r}"
            )

    apk_type = str(raw["type"])
    if apk_type not in _VALID_TYPES:
        raise ManifestError(
            f"{where}: type must be one of {sorted(_VALID_TYPES)}, got {apk_type!r}"
        )

    source = str(raw["source"])
    if source not in _VALID_SOURCES:
        raise ManifestError(
            f"{where}: source must be one of {sorted(_VALID_SOURCES)}, got {source!r}"
        )

    # url may be "" (deferred); it must still be a string if present.
    url = raw.get("url", "")
    if not isinstance(url, str):
        raise ManifestError(f"{where}: url must be a string, got {url!r}")

    version_code = raw.get("version_code")
    # bool is a subclass of int -- reject it explicitly so True/False can't slip in.
    if not isinstance(version_code, int) or isinstance(version_code, bool):
        raise ManifestError(
            f"{where}: version_code must be an integer, got {version_code!r}"
        )

    conflicts_raw = raw.get("conflicts", [])
    if not isinstance(conflicts_raw, list) or not all(
        isinstance(c, str) for c in conflicts_raw
    ):
        raise ManifestError(
            f"{where}: conflicts must be an array of strings, got {conflicts_raw!r}"
        )

    return Apk(
        name=str(raw["name"]),
        package=str(raw["package"]),
        type=apk_type,
        partition=str(raw["partition"]),
        version_code=version_code,
        source=source,
        url=url,
        sha256=str(raw["sha256"]),
        signer_cert_sha256=str(raw["signer_cert_sha256"]),
        conflicts=tuple(conflicts_raw),
    )


def load_manifest(path: Path | str = DEFAULT_MANIFEST) -> list[Apk]:
    """Read and validate manifest.toml, returning the list of Apk entries.

    Raises ManifestError on a malformed file, an unsupported schema_version, or
    any field that violates the schema.
    """
    path = Path(path)
    try:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
    except FileNotFoundError as exc:
        raise ManifestError(f"manifest not found: {path}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise ManifestError(f"manifest is not valid TOML ({path}): {exc}") from exc

    schema_version = data.get("schema_version")
    if schema_version != SCHEMA_VERSION_SUPPORTED:
        raise ManifestError(
            f"unsupported schema_version {schema_version!r}; "
            f"this tool understands {SCHEMA_VERSION_SUPPORTED}"
        )

    raw_apks = data.get("apk")
    if not isinstance(raw_apks, list) or not raw_apks:
        raise ManifestError("manifest has no [[apk]] entries")

    apks = [_coerce_apk(raw, i) for i, raw in enumerate(raw_apks)]

    names = [a.name for a in apks]
    duplicates = {n for n in names if names.count(n) > 1}
    if duplicates:
        raise ManifestError(f"duplicate component name(s): {sorted(duplicates)}")

    return apks


def _conf_field(value: str) -> str:
    """Render a single column: empty string becomes the '-' placeholder."""
    return value if value else "-"


def render_components_conf(apks: list[Apk]) -> str:
    """Render components.conf text from the manifest.

    One row per NON-deferred component (Phonesky is deferred and skipped -- it
    has no stable redistributable URL yet; see manifest.toml). Columns are
    whitespace-separated; '-' marks an empty column.

    Contract (must match customize.sh's interpreter):
      # name  pkg  asset  partition  type  perms  conflicts
    """
    # SKIP RULE: deferred components (empty url, e.g. Phonesky) are not placed on
    # device, so they never appear in components.conf. This keeps the on-device
    # interpreter from referencing an asset that the build never produced.
    rows = [a for a in apks if not a.is_deferred]

    columns: list[tuple[str, str, str, str, str, str, str]] = []
    for apk in rows:
        columns.append(
            (
                apk.name,
                apk.package,
                apk.asset,
                apk.partition,
                apk.type,
                apk.perms,
                _conf_field(",".join(apk.conflicts)),
            )
        )

    header = (
        "name",
        "pkg",
        "asset",
        "partition",
        "type",
        "perms",
        "conflicts",
    )

    # Align columns for human readability; whitespace-separated either way so the
    # shell interpreter (read name pkg asset ...) parses it regardless of widths.
    widths = [len(h) for h in header]
    for row in columns:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def fmt(row: tuple[str, ...]) -> str:
        return "  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip()

    lines = [
        "# Generated by lib/manifest.py from manifest.toml -- DO NOT EDIT BY HAND.",
        "# Slim install-time component table consumed by customize.sh.",
        "# Deferred components (e.g. Phonesky) are intentionally absent.",
        "# " + fmt(header),
    ]
    lines.extend(fmt(row) for row in columns)
    return "\n".join(lines) + "\n"


def emit_conf(
    out_path: Path | str = DEFAULT_COMPONENTS_CONF,
    manifest_path: Path | str = DEFAULT_MANIFEST,
) -> Path:
    """Write components.conf from manifest.toml. Returns the output path."""
    apks = load_manifest(manifest_path)
    text = render_components_conf(apks)
    out_path = Path(out_path)
    out_path.write_text(text, encoding="ascii")
    return out_path


def render_list_tsv(apks: list[Apk]) -> str:
    """Render the machine-parseable APK table for build.sh as TSV.

    One row per NON-deferred component (build.sh fetches + verifies these). The
    columns give build.sh everything it needs to download and 3-anchor verify:
      name  url  sha256  signer_cert_sha256  type  version_code
    A leading '#'-commented header documents the column order.
    """
    header = "#name\turl\tsha256\tsigner_cert_sha256\ttype\tversion_code"
    lines = [header]
    for apk in apks:
        if apk.is_deferred:
            continue
        lines.append(
            "\t".join(
                (
                    apk.name,
                    apk.url,
                    apk.sha256,
                    apk.signer_cert_sha256,
                    apk.type,
                    str(apk.version_code),
                )
            )
        )
    return "\n".join(lines) + "\n"


def _cmd_emit_conf(args: argparse.Namespace) -> int:
    out = args.out if args.out is not None else DEFAULT_COMPONENTS_CONF
    written = emit_conf(out_path=out, manifest_path=args.manifest)
    print(f"wrote {written}", file=sys.stderr)
    return 0


def _cmd_list(args: argparse.Namespace) -> int:
    apks = load_manifest(args.manifest)
    sys.stdout.write(render_list_tsv(apks))
    return 0


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Parse manifest.toml; emit components.conf or list APKs.",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_MANIFEST,
        help=f"path to manifest.toml (default: {DEFAULT_MANIFEST})",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_emit = sub.add_parser(
        "emit-conf", help="generate components.conf from manifest.toml"
    )
    p_emit.add_argument(
        "--out",
        type=Path,
        default=None,
        help=f"output path (default: {DEFAULT_COMPONENTS_CONF})",
    )
    p_emit.set_defaults(func=_cmd_emit_conf)

    p_list = sub.add_parser(
        "list", help="print non-deferred APKs as TSV for build.sh"
    )
    p_list.set_defaults(func=_cmd_list)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except ManifestError as exc:
        print(f"manifest error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
