#!/usr/bin/env bash
# lib/fetch.sh -- download + 3-anchor verify library, SOURCED by build.sh.
#
# This is a function library, not a standalone script. It deliberately does NOT
# `set -e` at file scope (that would propagate into the sourcing shell and abort
# build.sh on the first non-zero check). Every function checks return codes
# explicitly and returns non-zero on failure; callers must check the return.
#
# Public function:
#   fetch_and_verify <url> <expected_sha256> <expected_signer_cert_sha256> \
#                    <type> <dest_path>
#
# Verification (design spec section 6):
#   type=app       -- 3 anchors, ALL must pass before the file is accepted:
#                       1. sha256sum == expected_sha256                 (integrity)
#                       2. `apksigner verify` exits 0                   (valid sig)
#                       3. apksigner --print-certs cert SHA-256 ==
#                          expected_signer_cert_sha256                  (publisher)
#   type=framework -- a library JAR (maps.jar). sha256 + a guard that the asset
#                     is NOT an installable APK (no AndroidManifest.xml). The
#                     signer-cert/signature anchors are inapplicable to a library
#                     JAR, but the not-an-APK guard prevents a real APK from being
#                     mislabeled "framework" and skipping those anchors.
#
# If expected_sha256 == "PENDING-BUMP" the function fails loudly and tells the
# user to run tools/bump (build.sh must not proceed with an unpinned hash).
#
# shellcheck shell=bash

# Sentinel that means "no real hash pinned yet". Keep in sync with lib/manifest.py.
FETCH_PENDING_SENTINEL="PENDING-BUMP"

# _fetch_err <message...> -- print a clear, prefixed error to stderr.
_fetch_err() {
    printf 'fetch: error: %s\n' "$*" >&2
}

# _fetch_have <cmd> -- return 0 if command exists on PATH, else 1.
_fetch_have() {
    command -v "$1" >/dev/null 2>&1
}

# _fetch_sha256 <file> -- print the lowercase hex sha256 of <file>, or fail.
# Prefers sha256sum (coreutils, present in CI); falls back to `shasum -a 256`.
_fetch_sha256() {
    file="$1"
    if _fetch_have sha256sum; then
        # cut on the first space: output is "<hash>  <file>".
        sha256sum "$file" 2>/dev/null | cut -d' ' -f1
        return "${PIPESTATUS[0]:-0}"
    fi
    if _fetch_have shasum; then
        shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1
        return "${PIPESTATUS[0]:-0}"
    fi
    _fetch_err "no sha256 tool found (need sha256sum or shasum)"
    return 1
}

# _fetch_vendor_root -- print the absolute directory that vendored (scheme-less)
# sources must stay under. Defaults to "$ROOT/vendor" when ROOT is exported by
# build.sh; falls back to "$ROOT" if the narrower vendor dir does not exist, and
# to the cwd if ROOT is unset (keeps the library usable standalone / in tests).
_fetch_vendor_root() {
    root="${ROOT:-$(pwd)}"
    if [ -d "$root/vendor" ]; then
        printf '%s/vendor' "$root"
    else
        printf '%s' "$root"
    fi
}

# _fetch_download <url> <dest> -- fetch <url> to <dest>, or fail non-zero.
#
# A url WITHOUT a "scheme://" prefix is treated as a local filesystem path and
# copied (the vendored-source case, e.g. MapsV1's in-repo jar). build.sh resolves
# such paths to absolute before calling. A url WITH a scheme is downloaded:
# prefers curl, falls back to wget; fails loudly if neither exists.
#
# SECURITY (vendored path traversal): a scheme-less url comes from the manifest,
# which tools/bump rewrites from a network index. Because it is then "verified"
# by sha256 alone, an attacker-controlled "../../etc/..." could pull an arbitrary
# local file into the artifact. build.sh resolves the repo-relative value to an
# absolute path (and rejects leading-slash / ".." there) BEFORE calling us, so we
# accept an absolute path here. As defense in depth -- and to protect any direct
# caller -- we reject a ".." segment and authoritatively assert the canonicalized
# source resolves to a path under the vendored root (this also defeats a symlink
# inside vendor/ that points outside it).
_fetch_download() {
    url="$1"
    dest="$2"

    if [ -z "$url" ]; then
        _fetch_err "empty url (component may be deferred and should not be fetched)"
        return 1
    fi

    # No "://" scheme -> a local (vendored) file path: copy instead of download.
    case "$url" in
        *://*) : ;;  # remote url, fall through to curl/wget
        *)
            # Reject any ".." path segment. Matched bounded by start/end or a
            # slash so a filename that merely contains ".." (e.g. "a..b.jar") is
            # not falsely rejected. (No leading-slash check: build.sh passes an
            # already-resolved absolute path; the containment assertion below is
            # the real boundary.)
            case "$url" in
                ..|../*|*/..|*/../*)
                    _fetch_err "vendored url must not contain a '..' segment: $url"
                    return 1
                    ;;
            esac

            if [ ! -f "$url" ]; then
                _fetch_err "vendored file not found: $url"
                return 1
            fi

            # Canonicalize source and the vendored root, then assert containment.
            # This defends against symlinks inside vendor/ pointing outside it.
            vendor_root="$(_fetch_vendor_root)"
            canon_root="$(cd "$vendor_root" 2>/dev/null && pwd -P)"
            canon_src="$(cd "$(dirname "$url")" 2>/dev/null && pwd -P)/$(basename "$url")"
            if [ -z "$canon_root" ] || [ -z "$canon_src" ]; then
                _fetch_err "could not canonicalize vendored path: $url"
                return 1
            fi
            case "$canon_src" in
                "$canon_root"/*) : ;;  # ok: strictly under the vendored root
                *)
                    _fetch_err "vendored source escapes the vendored root: $url"
                    _fetch_err "  resolved: $canon_src"
                    _fetch_err "  allowed under: $canon_root/"
                    return 1
                    ;;
            esac

            if ! cp "$canon_src" "$dest"; then
                _fetch_err "failed to copy vendored file: $url -> $dest"
                return 1
            fi
            if [ ! -s "$dest" ]; then
                _fetch_err "vendored file is empty: $url"
                return 1
            fi
            return 0
            ;;
    esac

    if _fetch_have curl; then
        # -f: fail on HTTP >=400; -L: follow redirects (GitHub assets redirect);
        # -S: show errors with -s; -o: output file.
        # --retry 3 + --retry-connrefused + --retry-delay 2: survive transient
        # 5xx / connection refusals in CI without masking a real hard failure
        # (curl still exits non-zero once retries are exhausted).
        if ! curl -fSL -s --retry 3 --retry-connrefused --retry-delay 2 \
                -o "$dest" "$url"; then
            _fetch_err "curl failed to download: $url"
            return 1
        fi
    elif _fetch_have wget; then
        # --tries=3 + --waitretry=2: same transient-failure tolerance as curl.
        if ! wget -q --tries=3 --waitretry=2 -O "$dest" "$url"; then
            _fetch_err "wget failed to download: $url"
            return 1
        fi
    else
        _fetch_err "no downloader found (need curl or wget)"
        return 1
    fi

    if [ ! -s "$dest" ]; then
        _fetch_err "download produced an empty file: $dest <- $url"
        return 1
    fi
    return 0
}

# _fetch_verify_sha256 <file> <expected> -- integrity anchor. 0 on match.
_fetch_verify_sha256() {
    file="$1"
    expected="$2"

    actual="$(_fetch_sha256 "$file")"
    if [ -z "$actual" ]; then
        _fetch_err "could not compute sha256 of $file"
        return 1
    fi

    # Normalize to lowercase for a case-insensitive compare.
    actual="$(printf '%s' "$actual" | tr 'A-F' 'a-f')"
    expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"

    if [ "$actual" != "$expected" ]; then
        _fetch_err "sha256 mismatch for $file"
        _fetch_err "  expected: $expected"
        _fetch_err "  actual:   $actual"
        return 1
    fi
    return 0
}

# _fetch_cert_sha256_all <apk> -- print EVERY signer certificate SHA-256 digest,
# one per line, normalized (colons stripped, lowercase). Fail non-zero only when
# apksigner produces no output at all; an empty digest set is a valid (if
# rejectable) result that the caller distinguishes from a tool error.
#
# We grep lines that contain BOTH "certificate" and "SHA-256 digest:".
# apksigner labels each signer's cert as either:
#   "Signer #1 certificate SHA-256 digest: <hex>"                  (v1/v2)
#   "Signer (minSdkVersion=..) certificate SHA-256 digest: <hex>"  (v3)
# A co-signed APK prints one such line PER signer; we must surface them all so
# the caller can enforce that there is exactly one trusted signer (see
# _fetch_verify_cert). We must NOT match "... public key SHA-256 digest: ...";
# requiring the word "certificate" on the line excludes the public-key lines.
_fetch_cert_sha256_all() {
    apk="$1"

    # --print-certs implies verification; capture stdout, discard noise on stderr.
    certs_out="$(apksigner verify --print-certs "$apk" 2>/dev/null)"
    if [ -z "$certs_out" ]; then
        _fetch_err "apksigner --print-certs produced no output for $apk"
        return 1
    fi

    # Emit the last whitespace-delimited token (the hex digest) of every matching
    # line -- one digest per signer -- normalized to colon-stripped lowercase.
    printf '%s\n' "$certs_out" \
        | awk '/certificate/ && /SHA-256 digest:/ { print $NF }' \
        | tr -d ':' \
        | tr 'A-F' 'a-f'
    return 0
}

# _fetch_assert_not_apk <file> -- guard for type=framework. Returns 0 only when
# <file> is genuinely NOT an installable Android package (APK).
#
# WHY: `type` is read straight from the manifest, which tools/bump rewrites from a
# network index. A real APK mislabeled "framework" would otherwise skip BOTH
# signature anchors (signature-valid + signer-cert pin) and be trusted on sha256
# alone -- letting an attacker who can influence the index ship an unsigned or
# wrongly-signed privileged app.
#
# DISCRIMINATOR: an archive is an installable Android *package* iff it contains
# AndroidManifest.xml at its root. That is precisely what apksigner/PackageManager
# require. We deliberately do NOT key on the presence of a JAR signature block
# (META-INF/*.RSA/*.SF): the legitimate framework asset, MapsV1's
# com.google.android.maps.jar, is itself a *signed* library jar (it carries
# META-INF/NOGAPPS.RSA) but has NO AndroidManifest.xml -- it is a shared-library
# dex jar, not an APK. Keying on the signature block would wrongly reject it.
#
# If unzip is unavailable we cannot probe; we then fall back to trusting the
# manifest-supplied type. Residual assumption (documented): the manifest/bump
# pipeline is the trust anchor for the type field when no archive inspector
# exists. CI always has unzip, so this fallback is a last resort, not the norm.
_fetch_assert_not_apk() {
    file="$1"

    if ! _fetch_have unzip; then
        _fetch_err "warning: unzip unavailable; cannot confirm $file is not an APK;" \
            "trusting manifest type=framework"
        return 0
    fi

    # If unzip cannot list the archive it is not a valid zip, hence cannot be an
    # APK (which is a zip) -> acceptable as a non-APK framework asset.
    listing="$(unzip -l "$file" 2>/dev/null)"
    if [ -z "$listing" ]; then
        return 0
    fi

    # An APK has AndroidManifest.xml at the archive root. Match it anchored to a
    # path boundary so "foo/AndroidManifest.xml" inside an asset dir does not
    # count, only a root-level entry. unzip -l prints the path in the last field.
    if printf '%s\n' "$listing" \
        | awk '{print $NF}' \
        | grep -qx 'AndroidManifest.xml'; then
        _fetch_err "asset declared type=framework but is an APK (has AndroidManifest.xml): $file"
        _fetch_err "  SECURITY: an installable package must be type=app (3-anchor verified),"
        _fetch_err "            not accepted on sha256 alone."
        return 1
    fi
    return 0
}

# _fetch_verify_signature <apk> -- authenticity anchor part 1: signature valid.
_fetch_verify_signature() {
    apk="$1"
    if apksigner verify "$apk" >/dev/null 2>&1; then
        return 0
    fi
    _fetch_err "apksigner verify FAILED (invalid or missing signature): $apk"
    return 1
}

# _fetch_verify_cert <apk> <expected_cert_sha256> -- authenticity anchor part 2.
#
# A privileged system app must be bound to EXACTLY ONE trusted signing key, so
# we reject anything but a single signer matching the pin. Concretely we fail if:
#   - apksigner produced no usable output (tool error), or
#   - zero certificate digests were found, or
#   - MORE THAN ONE distinct signer certificate is present (co-signed APK: an
#     extra key could otherwise satisfy a per-signer match on the wrong signer),
#   - the single present digest does not equal the pinned expected digest.
# Counting DISTINCT digests means an APK that merely repeats the same signer
# across signature schemes (v1/v2/v3 all the same cert) still passes.
_fetch_verify_cert() {
    apk="$1"
    expected="$2"

    actuals="$(_fetch_cert_sha256_all "$apk")"
    if [ -z "$actuals" ]; then
        # Either a tool error (already reported) or zero matching lines.
        _fetch_err "no signer certificate SHA-256 digest found for $apk"
        return 1
    fi

    # Collapse to the set of DISTINCT digests and count them.
    distinct="$(printf '%s\n' "$actuals" | sed '/^$/d' | LC_ALL=C sort -u)"
    count="$(printf '%s\n' "$distinct" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [ "$count" -gt 1 ]; then
        _fetch_err "APK has $count distinct signer certificates: $apk"
        _fetch_err "  SECURITY: a privileged system app must have exactly one signer."
        while IFS= read -r d; do
            [ -n "$d" ] && _fetch_err "  signer cert: $d"
        done <<EOF
$distinct
EOF
        return 1
    fi

    expected="$(printf '%s' "$expected" | tr -d ':' | tr 'A-F' 'a-f')"
    # Exactly one distinct digest here; compare it to the pin.
    if [ "$distinct" != "$expected" ]; then
        _fetch_err "signer certificate mismatch for $apk"
        _fetch_err "  expected signer_cert_sha256: $expected"
        _fetch_err "  actual signer_cert_sha256:   $distinct"
        _fetch_err "  SECURITY: a different signing key published this APK."
        return 1
    fi
    return 0
}

# fetch_and_verify <url> <expected_sha256> <expected_signer_cert_sha256> \
#                  <type> <dest_path>
#
# Download then verify per <type>. Returns 0 only when ALL applicable anchors
# pass and the verified file is in place at <dest_path>. On any failure the
# (possibly partial) download is removed and a non-zero status is returned.
fetch_and_verify() {
    if [ "$#" -ne 5 ]; then
        _fetch_err "fetch_and_verify needs 5 args:" \
            "<url> <sha256> <signer_cert_sha256> <type> <dest_path>"
        return 2
    fi

    url="$1"
    expected_sha256="$2"
    expected_cert="$3"
    apk_type="$4"
    dest="$5"

    # Guard: an unpinned hash means bump never ran. Fail loudly, do not download.
    if [ "$expected_sha256" = "$FETCH_PENDING_SENTINEL" ]; then
        _fetch_err "sha256 is '$FETCH_PENDING_SENTINEL' for $url"
        _fetch_err "  the manifest has no real hash pinned yet."
        _fetch_err "  run: tools/bump   (then re-run the build)"
        return 1
    fi

    case "$apk_type" in
        app|framework) : ;;
        *)
            _fetch_err "unknown type '$apk_type' (expected 'app' or 'framework')"
            return 2
            ;;
    esac

    # Required tools per type. sha256 tool is always required.
    if ! _fetch_have sha256sum && ! _fetch_have shasum; then
        _fetch_err "missing sha256 tool (need sha256sum or shasum)"
        return 1
    fi
    if [ "$apk_type" = "app" ] && ! _fetch_have apksigner; then
        _fetch_err "missing apksigner (required to verify type=app signer cert)"
        return 1
    fi

    # Ensure destination directory exists.
    dest_dir="$(dirname "$dest")"
    if ! mkdir -p "$dest_dir" 2>/dev/null; then
        _fetch_err "cannot create destination directory: $dest_dir"
        return 1
    fi

    printf 'fetch: downloading %s\n' "$url" >&2
    if ! _fetch_download "$url" "$dest"; then
        rm -f "$dest"
        return 1
    fi

    # Anchor 1 (both types): integrity.
    if ! _fetch_verify_sha256 "$dest" "$expected_sha256"; then
        rm -f "$dest"
        return 1
    fi

    if [ "$apk_type" = "framework" ]; then
        # framework = a library JAR (maps.jar). apksigner cannot verify it, so the
        # sha256 anchor above is the integrity check. But before accepting
        # sha256-only we must confirm the asset is NOT actually a signed APK that
        # was mislabeled in the manifest -- otherwise both signature anchors are
        # silently skipped. A library jar (even a signed one, like MapsV1) has no
        # AndroidManifest.xml and passes; a real APK is rejected.
        if ! _fetch_assert_not_apk "$dest"; then
            rm -f "$dest"
            return 1
        fi
        printf 'fetch: verified (framework, sha256 + not-an-apk): %s\n' "$dest" >&2
        return 0
    fi

    # type=app: anchor 2 (valid signature) + anchor 3 (publisher cert match).
    if ! _fetch_verify_signature "$dest"; then
        rm -f "$dest"
        return 1
    fi
    if ! _fetch_verify_cert "$dest" "$expected_cert"; then
        rm -f "$dest"
        return 1
    fi

    printf 'fetch: verified (3 anchors: sha256 + signature + signer cert): %s\n' \
        "$dest" >&2
    return 0
}
