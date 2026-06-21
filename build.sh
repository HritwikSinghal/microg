#!/usr/bin/env bash
#################################################################
# microG Universal Installer -- hermetic build (design spec section 6).
#
# Stages 2 and 3 of the build (RESOLVE is tools/bump's job, run separately):
#   [2] BUILD    download each pinned APK + 3-anchor verify; generate the
#                version-matched permission XMLs; run the permission invariant.
#   [3] PACKAGE  emit the slim components.conf and assemble the flashable ZIP.
#
# Hermetic contract: this script trusts NOTHING remote beyond the pinned facts in
# manifest.toml. Same manifest in -> byte-identical inputs out. It never reaches
# the network to "find latest" (that is tools/bump). While any non-deferred
# component still carries sha256 = "PENDING-BUMP", fetch_and_verify fails loudly
# and this build aborts -- by design; run tools/bump first.
#
# This script does NOT flash, mount, or touch any device. It only assembles the
# artifact; the user deploys it.
#
# Usage:   ./build.sh
# Env:     API_LEVEL   target AOSP API for permission generation (default 34)
#          OUT_DIR     output dir for the ZIP            (default: out)
#          BUILD_DIR   scratch/staging dir              (default: build)
#
# Requires: python3 (3.11+), apksigner, apkanalyzer or aapt2, sha256sum/shasum,
#           zip; xmllint optional (validation falls back to ElementTree).
#################################################################

set -euo pipefail

# Resolve the repo root from this script's location so the build is cwd-agnostic.
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

API_LEVEL="${API_LEVEL:-34}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
STAGE="$BUILD_DIR/stage"   # becomes the ZIP root
META="$BUILD_DIR/meta"     # build-only metadata (perm sidecars); NOT shipped

MANIFEST="$ROOT/manifest.toml"

# shellcheck source=lib/fetch.sh
. "$ROOT/lib/fetch.sh"

die() {
    printf 'build: error: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

log() {
    printf 'build: %s\n' "$*" >&2
}

# --- Preconditions ----------------------------------------------------------
need_cmd python3
need_cmd zip
if ! command -v apkanalyzer >/dev/null 2>&1 && ! command -v aapt2 >/dev/null 2>&1; then
    die "need apkanalyzer or aapt2 (Android build-tools) to read APK permissions"
fi
# apksigner / sha256 tools are checked per-file inside fetch_and_verify.

[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

# --- Clean staging ----------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$STAGE/apks" "$STAGE/perms" "$META" "$OUT_DIR"

# --- Emit the slim install-time components.conf from the manifest -----------
log "emitting components.conf"
python3 lib/manifest.py --manifest "$MANIFEST" emit-conf --out "$STAGE/components.conf" \
    || die "failed to emit components.conf"

# --- Load the manifest fetch table (TSV) and the components table -----------
# Two views of the same components, joined on the component name:
#   list (TSV)      -> url / sha256 / signer_cert / type / version_code  (fetch)
#   components.conf  -> pkg / asset / partition / type / perms           (place)
declare -A URL SHA SIGNER FTYPE
declare -A PKG ASSET PERMS CTYPE

while IFS=$'\t' read -r name url sha signer ftype _vcode; do
    case "$name" in '#'*|'') continue ;; esac
    URL["$name"]="$url"
    SHA["$name"]="$sha"
    SIGNER["$name"]="$signer"
    FTYPE["$name"]="$ftype"
done < <(python3 lib/manifest.py --manifest "$MANIFEST" list)

while read -r name pkg asset _partition ctype perms _conflicts; do
    case "$name" in '#'*|'') continue ;; esac
    PKG["$name"]="$pkg"
    ASSET["$name"]="$asset"
    CTYPE["$name"]="$ctype"
    PERMS["$name"]="$perms"
done < "$STAGE/components.conf"

[ "${#URL[@]}" -gt 0 ] || die "no buildable components found in manifest"

# --- Fetch + verify each component, then generate its permission XML --------
for name in "${!URL[@]}"; do
    asset="${ASSET[$name]}"
    dest="$STAGE/$asset"
    log "component $name ($asset)"

    # A scheme-less url is a repo-relative vendored file (e.g. MapsV1's in-repo
    # jar); resolve it to an absolute path so the copy works from any cwd.
    src_url="${URL[$name]}"
    case "$src_url" in
        *://*) : ;;
        *) src_url="$ROOT/$src_url" ;;
    esac

    fetch_and_verify \
        "$src_url" "${SHA[$name]}" "${SIGNER[$name]}" "${FTYPE[$name]}" "$dest" \
        || die "fetch/verify failed for $name"

    # Framework JARs (MapsV1) have no privapp-permissions allowlist; skip perms.
    if [ "${CTYPE[$name]}" = "framework" ]; then
        continue
    fi

    # Extract requested perms ONCE; feed the same list to genperms and the
    # invariant (which auto-detects the sidecar by component name).
    sidecar="$META/${name}.perms"
    python3 lib/genperms.py dump-requested --apk "$dest" --out "$sidecar" \
        || die "failed to dump requested perms for $name"

    python3 lib/genperms.py gen \
        --requested-file "$sidecar" \
        --package "${PKG[$name]}" \
        --api "$API_LEVEL" \
        --out "$STAGE/${PERMS[$name]}" \
        || die "failed to generate permission XML for $name"
done

# --- Separate behavioral-exemptions sysconfig (GmsCore only) ----------------
log "generating sysconfig-microg.xml"
python3 lib/genperms.py sysconfig \
    --package com.google.android.gms \
    --out "$STAGE/perms/sysconfig-microg.xml" \
    || die "failed to generate sysconfig-microg.xml"

# --- CI invariant: the permanent bootloop cure (must pass to ship) ----------
log "running permission invariant"
python3 lib/invariant.py check-perms \
    --manifest "$MANIFEST" \
    --perms-dir "$STAGE/perms" \
    --apks-dir "$META" \
    --api "$API_LEVEL" \
    || die "permission invariant FAILED (a bootloop-inducing mismatch)"

# --- Assemble the flashable ZIP --------------------------------------------
log "assembling ZIP"
cp -a module.prop customize.sh "$STAGE/"
cp -a META-INF "$STAGE/"
mkdir -p "$STAGE/common"
cp -a common/. "$STAGE/common/"
# Phase 1 boot scripts are copied when they exist (not present in Phase 0).
for opt in post-fs-data.sh service.sh; do
    [ -f "$opt" ] && cp -a "$opt" "$STAGE/"
done
# Drop the .gitkeep placeholders from the staged dirs; they are repo-only.
rm -f "$STAGE/apks/.gitkeep" "$STAGE/perms/.gitkeep"

VERSION="$(sed -n 's/^version=//p' module.prop | head -n1)"
[ -n "$VERSION" ] || VERSION="dev"
ZIP_PATH="$OUT_DIR/microg-installer-${VERSION}.zip"
rm -f "$ZIP_PATH"

# Zip from inside the stage so paths are relative to the module root.
( cd "$STAGE" && zip -r -X "$ZIP_PATH" . >/dev/null ) || die "zip assembly failed"

log "built $ZIP_PATH"
printf '%s\n' "$ZIP_PATH"
