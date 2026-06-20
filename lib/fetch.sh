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
#   type=framework -- a JAR (maps.jar). sha256 ONLY; apksigner cannot verify a
#                     plain library JAR, so signature/cert anchors are skipped.
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

# _fetch_download <url> <dest> -- fetch <url> to <dest>, or fail non-zero.
#
# A url WITHOUT a "scheme://" prefix is treated as a local filesystem path and
# copied (the vendored-source case, e.g. MapsV1's in-repo jar). build.sh resolves
# such paths to absolute before calling. A url WITH a scheme is downloaded:
# prefers curl, falls back to wget; fails loudly if neither exists.
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
            if [ ! -f "$url" ]; then
                _fetch_err "vendored file not found: $url"
                return 1
            fi
            if ! cp "$url" "$dest"; then
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
        if ! curl -fSL -s -o "$dest" "$url"; then
            _fetch_err "curl failed to download: $url"
            return 1
        fi
    elif _fetch_have wget; then
        if ! wget -q -O "$dest" "$url"; then
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

# _fetch_cert_sha256 <apk> -- print the lowercase, colon-stripped SHA-256 of the
# signing CERTIFICATE (not the public key), or fail non-zero.
#
# We grep the line that contains BOTH "certificate" and "SHA-256 digest:".
# apksigner labels it either:
#   "Signer #1 certificate SHA-256 digest: <hex>"        (v1/v2)
#   "Signer (minSdkVersion=..) certificate SHA-256 digest: <hex>"  (v3)
# Crucially we must NOT match "... public key SHA-256 digest: ...". Requiring the
# word "certificate" on the line excludes the public-key lines.
_fetch_cert_sha256() {
    apk="$1"

    # --print-certs implies verification; capture stdout, discard noise on stderr.
    certs_out="$(apksigner verify --print-certs "$apk" 2>/dev/null)"
    if [ -z "$certs_out" ]; then
        _fetch_err "apksigner --print-certs produced no output for $apk"
        return 1
    fi

    # Pick lines with "certificate" AND "SHA-256 digest:", take the last hex field.
    # awk: match both substrings, then print the final whitespace-delimited token.
    digest="$(
        printf '%s\n' "$certs_out" \
            | awk '/certificate/ && /SHA-256 digest:/ { print $NF }' \
            | head -n1
    )"

    if [ -z "$digest" ]; then
        _fetch_err "could not find a 'certificate SHA-256 digest:' line for $apk"
        return 1
    fi

    # Normalize: strip any colons (some tools colon-delimit), lowercase.
    printf '%s' "$digest" | tr -d ':' | tr 'A-F' 'a-f'
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
_fetch_verify_cert() {
    apk="$1"
    expected="$2"

    actual="$(_fetch_cert_sha256 "$apk")"
    if [ -z "$actual" ]; then
        return 1  # _fetch_cert_sha256 already reported the reason.
    fi

    expected="$(printf '%s' "$expected" | tr -d ':' | tr 'A-F' 'a-f')"
    if [ "$actual" != "$expected" ]; then
        _fetch_err "signer certificate mismatch for $apk"
        _fetch_err "  expected signer_cert_sha256: $expected"
        _fetch_err "  actual signer_cert_sha256:   $actual"
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
        # framework = a library JAR (maps.jar). apksigner cannot verify it; the
        # sha256 anchor above is the full trust check for this branch.
        printf 'fetch: verified (framework, sha256-only): %s\n' "$dest" >&2
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
