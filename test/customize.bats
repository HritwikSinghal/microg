#!/usr/bin/env bats
#
# test/customize.bats -- host-side unit tests for the customize.sh interpreter.
#
# customize.sh is a THIN, data-driven interpreter over components.conf. These
# tests exercise its control flow (row parsing, type dispatch, conflict purge,
# once-only sysconfig, per-row failure isolation) WITHOUT depending on the real
# place.sh / perms.sh / cleanup.sh (written in parallel by other agents).
#
# Strategy: build a throwaway $MODPATH whose common/place.sh, common/perms.sh
# and common/cleanup.sh are STUBS. Each stub function appends a record of its
# call and arguments to $MODPATH/calls.log and returns 0, so the test can assert
# exactly what the interpreter invoked, with which arguments. log.sh and
# detect.sh are the REAL libraries (copied in) -- they are pure and already
# unit-tested elsewhere.
#
# Everything lives under BATS temp dirs; no real path is written and the network
# is never touched.
#
# Run with:  bats test/customize.bats

bats_require_minimum_version 1.5.0

# --------------------------------------------------------------------------
# Fixture builders.
# --------------------------------------------------------------------------

# _write_stub_lib PATH NAME...: write a stub library at PATH defining each NAMEd
# function to log "NAME <args>" to $MODPATH/calls.log and return 0. The stubs
# reference $MODPATH at call time (it is exported into customize.sh's env).
_write_stub_place() {
	cat >"$MODPATH/common/place.sh" <<'STUB'
# shellcheck shell=sh
# Stub place.sh -- records calls, performs minimal real side effects so the
# interpreter's conflict-purge XML removal has something to act on.
place_resolve_partition() {
	# Echo the declared partition unchanged (the real lib may warn on a miss).
	printf '%s' "$1"
	printf 'place_resolve_partition %s\n' "$1" >>"$MODPATH/calls.log"
	return 0
}
place_app() {
	printf 'place_app %s %s %s\n' "$1" "$2" "$3" >>"$MODPATH/calls.log"
	return 0
}
place_framework() {
	printf 'place_framework %s %s %s\n' "$1" "$2" "$3" >>"$MODPATH/calls.log"
	return 0
}
place_remove() {
	printf 'place_remove %s %s\n' "$1" "$2" >>"$MODPATH/calls.log"
	return 0
}
STUB
}

_write_stub_perms() {
	cat >"$MODPATH/common/perms.sh" <<'STUB'
# shellcheck shell=sh
# Stub perms.sh -- records calls and returns 0.
perms_place_app() {
	printf 'perms_place_app %s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$MODPATH/calls.log"
	return 0
}
perms_place_framework() {
	printf 'perms_place_framework %s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$MODPATH/calls.log"
	return 0
}
perms_place_sysconfig() {
	printf 'perms_place_sysconfig %s\n' "$1" >>"$MODPATH/calls.log"
	return 0
}
STUB
}

_write_stub_cleanup() {
	cat >"$MODPATH/common/cleanup.sh" <<'STUB'
# shellcheck shell=sh
# Stub cleanup.sh -- records calls and returns 0.
cleanup_stock_gms() {
	printf 'cleanup_stock_gms %s %s\n' "$1" "$2" >>"$MODPATH/calls.log"
	return 0
}
STUB
}

# _write_components CONTENT: write a components.conf with verbatim CONTENT.
_write_components() {
	printf '%s\n' "$1" >"$MODPATH/components.conf"
}

# _default_components: a representative table covering all branches --
# comment + blank lines, two app rows, a framework row, and a conflicts entry
# (FakeStore conflicts with Phonesky).
_default_components() {
	_write_components '# name       pkg                      asset               partition  type       perms                conflicts
# (a comment line and a blank line below must be skipped)

GmsCore    com.google.android.gms   apks/GmsCore.apk    product    app        perms/gmscore.xml    -
FakeStore  com.android.vending      apks/FakeStore.apk  product    app        perms/fakestore.xml  Phonesky
MapsV1     com.google.android.maps  apks/maps.jar       product    framework  perms/mapsv1.xml     -'
}

# --------------------------------------------------------------------------
# setup: build a fake $MODPATH with real log/detect + stub place/perms/cleanup,
# dummy assets, and a components.conf, then point logging + getprop at fixtures.
# Tests call `run_customize` to source-execute the interpreter.
# --------------------------------------------------------------------------

setup() {
	load test_helper

	local scratch
	scratch="$(_scratch_dir)"

	# Fresh module staging root for this test.
	export MODPATH="$scratch/mod.$$.${BATS_TEST_NUMBER:-0}"
	rm -rf "$MODPATH"
	mkdir -p "$MODPATH/common" "$MODPATH/apks" "$MODPATH/perms"

	# Real, pure libraries the interpreter genuinely depends on.
	cp "$COMMON_DIR/log.sh" "$MODPATH/common/log.sh"
	cp "$COMMON_DIR/detect.sh" "$MODPATH/common/detect.sh"

	# Stub libraries that record calls.
	_write_stub_place
	_write_stub_perms
	_write_stub_cleanup

	# Dummy assets + perms files (the stubs do not read them, but a future
	# real-lib swap and the conflict-purge XML logic expect plausible paths).
	: >"$MODPATH/apks/GmsCore.apk"
	: >"$MODPATH/apks/FakeStore.apk"
	: >"$MODPATH/apks/maps.jar"
	: >"$MODPATH/perms/gmscore.xml"
	: >"$MODPATH/perms/fakestore.xml"
	: >"$MODPATH/perms/mapsv1.xml"
	: >"$MODPATH/perms/sysconfig-microg.xml"

	# Default component table (individual tests may overwrite it).
	_default_components

	# Redirect logging into a temp dir; never touch the real /data path.
	export MICROG_LOG_DIR="$scratch/log.$$.${BATS_TEST_NUMBER:-0}"
	rm -rf "$MICROG_LOG_DIR"
	unset MICROG_DEBUG

	# Pin the install env so detect.sh has deterministic, host-safe inputs.
	getprop_fixture getprop-arm64-api33.txt
	export API=33
	# Clear root-manager env signals so detection cannot leak from the host.
	unset KSU KSU_VER APATCH APATCH_VER MAGISK_VER MAGISK_VER_CODE
	# Empty DETECT_ROOT keeps partition/engine probes deterministic on a host
	# (no fixture markers => engine "unknown", which the interpreter handles).
	export DETECT_ROOT=""
}

# run_customize: execute the interpreter in a subshell. customize.sh is SOURCED
# in production; we run it via `sh` so a fatal `exit 1` cannot kill the test
# harness, while the sourced-library control flow is identical.
run_customize() {
	run sh "$REPO_ROOT/customize.sh"
}

# calls: cat the recorded call log (empty if the interpreter never reached a
# stub). Helper for readable assertions.
calls() {
	cat "$MODPATH/calls.log" 2>/dev/null
}

# --------------------------------------------------------------------------
# Tests.
# --------------------------------------------------------------------------

@test "interpreter runs to completion on a valid table" {
	run_customize
	[ "$status" -eq 0 ]
}

@test "comments and blank lines are skipped (only data rows dispatched)" {
	run_customize
	[ "$status" -eq 0 ]
	# Three data rows => exactly three place_app/place_framework dispatches.
	local n
	n="$(calls | grep -Ec '^(place_app|place_framework) ')"
	[ "$n" -eq 3 ]
}

@test "app rows call place_app + perms_place_app with resolved name/asset/part" {
	run_customize
	[ "$status" -eq 0 ]
	# GmsCore: app in product.
	calls | grep -q '^place_app GmsCore apks/GmsCore.apk product$'
	calls | grep -q '^perms_place_app GmsCore perms/gmscore.xml product 33$'
}

@test "framework row calls place_framework + perms_place_framework" {
	run_customize
	[ "$status" -eq 0 ]
	calls | grep -q '^place_framework MapsV1 apks/maps.jar product$'
	calls | grep -q '^perms_place_framework MapsV1 perms/mapsv1.xml product 33$'
}

@test "app dispatch never calls framework placement (and vice versa)" {
	run_customize
	[ "$status" -eq 0 ]
	# GmsCore is an app: it must not be placed as a framework.
	run ! grep -q '^place_framework GmsCore' "$MODPATH/calls.log"
	# MapsV1 is a framework: it must not be placed as an app.
	run ! grep -q '^place_app MapsV1' "$MODPATH/calls.log"
}

@test "conflict purge: place_remove invoked for the conflicting name" {
	run_customize
	[ "$status" -eq 0 ]
	# FakeStore declares a conflict with Phonesky => purge Phonesky first.
	calls | grep -q '^place_remove Phonesky product$'
}

@test "conflict purge removes the conflicting component's permission XML" {
	# Seed a stale Phonesky permission XML in the overlay (lowercased-name
	# convention: perms/<name.lower()>.xml -> etc/permissions/<name.lower()>.xml).
	mkdir -p "$MODPATH/system/product/etc/permissions"
	: >"$MODPATH/system/product/etc/permissions/phonesky.xml"
	run_customize
	[ "$status" -eq 0 ]
	# The purge must have deleted it.
	[ ! -e "$MODPATH/system/product/etc/permissions/phonesky.xml" ]
}

@test "non-conflicting rows ('-') trigger no place_remove" {
	# A table with only a '-' conflicts column.
	_write_components 'GmsCore    com.google.android.gms   apks/GmsCore.apk    product    app        perms/gmscore.xml    -'
	run_customize
	[ "$status" -eq 0 ]
	run ! grep -q '^place_remove ' "$MODPATH/calls.log"
}

@test "perms_place_sysconfig is called exactly once" {
	run_customize
	[ "$status" -eq 0 ]
	local n
	n="$(calls | grep -c '^perms_place_sysconfig ')"
	[ "$n" -eq 1 ]
}

@test "sysconfig is placed in the partition declared on the first data row" {
	run_customize
	[ "$status" -eq 0 ]
	calls | grep -q '^perms_place_sysconfig product$'
}

@test "cleanup_stock_gms is called once with the resolved partition" {
	run_customize
	[ "$status" -eq 0 ]
	local n
	n="$(calls | grep -c '^cleanup_stock_gms ')"
	[ "$n" -eq 1 ]
	calls | grep -q '^cleanup_stock_gms product '
}

@test "one failing component does not abort the remaining rows" {
	# Make place_app fail ONLY for GmsCore; the other rows must still run.
	cat >"$MODPATH/common/place.sh" <<'STUB'
# shellcheck shell=sh
place_resolve_partition() { printf '%s' "$1"; return 0; }
place_app() {
	printf 'place_app %s %s %s\n' "$1" "$2" "$3" >>"$MODPATH/calls.log"
	[ "$1" = "GmsCore" ] && return 1
	return 0
}
place_framework() {
	printf 'place_framework %s %s %s\n' "$1" "$2" "$3" >>"$MODPATH/calls.log"
	return 0
}
place_remove() {
	printf 'place_remove %s %s\n' "$1" "$2" >>"$MODPATH/calls.log"
	return 0
}
STUB
	run_customize
	# Interpreter completes (problems are isolated, not fatal).
	[ "$status" -eq 0 ]
	# GmsCore failed, but FakeStore (app) and MapsV1 (framework) still ran.
	calls | grep -q '^place_app FakeStore apks/FakeStore.apk product$'
	calls | grep -q '^place_framework MapsV1 apks/maps.jar product$'
	# The failing component is recorded as a problem in the log.
	grep -q 'failed to place app component GmsCore' "$MICROG_LOG_DIR/selfcheck.log"
}

@test "an unknown component type is skipped, not fatal" {
	_write_components 'WeirdOne   com.example.weird        apks/weird.apk      product    widget     perms/weird.xml      -
GmsCore    com.google.android.gms   apks/GmsCore.apk    product    app        perms/gmscore.xml    -'
	run_customize
	[ "$status" -eq 0 ]
	# Unknown type produced no place_* dispatch for it...
	run ! grep -q 'WeirdOne' "$MODPATH/calls.log"
	# ...but the valid row after it still ran.
	calls | grep -q '^place_app GmsCore apks/GmsCore.apk product$'
	grep -q "unknown component type 'widget'" "$MICROG_LOG_DIR/selfcheck.log"
}

@test "a malformed row (too few fields) is skipped, not fatal" {
	_write_components 'BrokenRow  only three fields
GmsCore    com.google.android.gms   apks/GmsCore.apk    product    app        perms/gmscore.xml    -'
	run_customize
	[ "$status" -eq 0 ]
	calls | grep -q '^place_app GmsCore apks/GmsCore.apk product$'
	grep -q 'malformed components.conf row' "$MICROG_LOG_DIR/selfcheck.log"
}

@test "missing MODPATH is a fatal setup error (exit non-zero)" {
	unset MODPATH
	# With MODPATH unset, ${MODPATH:?} makes the script fail immediately.
	run sh "$REPO_ROOT/customize.sh"
	[ "$status" -ne 0 ]
}

@test "missing components.conf is a fatal setup error (exit 1)" {
	rm -f "$MODPATH/components.conf"
	run_customize
	[ "$status" -eq 1 ]
	grep -q 'components.conf not found' "$MICROG_LOG_DIR/selfcheck.log"
}

@test "a missing required library is a fatal setup error" {
	rm -f "$MODPATH/common/place.sh"
	run_customize
	[ "$status" -ne 0 ]
}

@test "API < 26 proceeds with a warning (XML inert but harmless)" {
	export API=25
	getprop_fixture getprop-arm32-api27.txt
	run_customize
	[ "$status" -eq 0 ]
	# Still placed everything...
	calls | grep -q '^place_app GmsCore apks/GmsCore.apk product$'
	# ...and warned about the inert XML.
	grep -q 'API 25 < 26' "$MICROG_LOG_DIR/selfcheck.log"
}

@test "the final summary records OK when there are no problems" {
	run_customize
	[ "$status" -eq 0 ]
	grep -q 'install complete: all components placed (OK)' "$MICROG_LOG_DIR/selfcheck.log"
}

# --------------------------------------------------------------------------
# Fix #1 regression: the overlay MUST be permission/owner/context normalized.
#
# Plain cp/mkdir leave the wrong mode + SELinux context, so PackageManager
# silently ignores the APKs and etc/permissions allowlists. customize.sh must
# normalize "$MODPATH/system" after placement. We assert both the preferred
# path (set_perm_recursive invoked with the canonical args) and the manual
# fallback (a placed file ends up mode 0644).
# --------------------------------------------------------------------------

# _shim_set_perm_recursive: put an executable named set_perm_recursive early on
# PATH that records its argv to $MODPATH/setperm.log, so `command -v` finds it
# and the interpreter prefers it over the manual fallback. (On a real install
# this is a function sourced from util_functions.sh; an on-PATH executable is an
# equivalent, test-injectable seam since the code probes via `command -v`.)
_shim_set_perm_recursive() {
	mkdir -p "$MODPATH/shim-bin"
	cat >"$MODPATH/shim-bin/set_perm_recursive" <<SHIM
#!/bin/sh
printf '%s\n' "\$*" >>"$MODPATH/setperm.log"
exit 0
SHIM
	chmod 0755 "$MODPATH/shim-bin/set_perm_recursive"
}

@test "fix1: set_perm_recursive is invoked against the overlay with canonical args" {
	# The stub place/perms libs do not create real files, so seed an overlay dir
	# the normalizer can act on (mirrors a successful placement).
	mkdir -p "$MODPATH/system/product/etc/permissions"
	_shim_set_perm_recursive
	PATH="$MODPATH/shim-bin:$PATH" run sh "$REPO_ROOT/customize.sh"
	[ "$status" -eq 0 ]
	# Exactly the canonical Magisk normalization call on the overlay root.
	grep -qx "$MODPATH/system 0 0 0755 0644" "$MODPATH/setperm.log"
}

@test "fix1: manual fallback chmods placed permission XML to 0644" {
	# Use the REAL place/perms libs so a genuine etc/permissions/*.xml is placed,
	# then let the manual fallback (no set_perm_recursive on PATH) normalize it.
	cp "$COMMON_DIR/place.sh" "$MODPATH/common/place.sh"
	cp "$COMMON_DIR/perms.sh" "$MODPATH/common/perms.sh"
	# A single-app table keeps the assertion focused.
	_write_components 'GmsCore    com.google.android.gms   apks/GmsCore.apk    product    app        perms/gmscore.xml    -'
	# Real perms.sh validates+copies this file; give it well-formed XML.
	printf '%s\n' '<?xml version="1.0"?><permissions></permissions>' >"$MODPATH/perms/gmscore.xml"
	# Detect 'product' as a real partition so place_resolve_partition keeps it.
	export DETECT_ROOT="$MODPATH/detroot"
	mkdir -p "$DETECT_ROOT/system" "$DETECT_ROOT/product"
	export DETECT_PART_CANDIDATES="system system_ext product vendor"
	# Make the placed APK world-writable up front so a no-op normalizer would be
	# visibly detectable (the assertion below would then fail).
	run sh "$REPO_ROOT/customize.sh"
	[ "$status" -eq 0 ]
	local xml="$MODPATH/system/product/etc/permissions/gmscore.xml"
	[ -f "$xml" ]
	# Mode must be exactly 0644 after normalization (portable stat: %a octal).
	local mode
	mode="$(stat -c '%a' "$xml" 2>/dev/null || stat -f '%Lp' "$xml" 2>/dev/null)"
	[ "$mode" = "644" ]
	# And a placed APK dir must be 0755.
	local appdir="$MODPATH/system/product/priv-app/GmsCore"
	[ -d "$appdir" ]
	local dmode
	dmode="$(stat -c '%a' "$appdir" 2>/dev/null || stat -f '%Lp' "$appdir" 2>/dev/null)"
	[ "$dmode" = "755" ]
}

@test "fix1: normalization is a safe no-op when nothing was placed" {
	# Empty table => no overlay tree => normalizer must not error.
	_write_components '# nothing here'
	run_customize
	[ "$status" -eq 0 ]
	grep -q 'normalize: no overlay' "$MICROG_LOG_DIR/selfcheck.log"
}

# --------------------------------------------------------------------------
# Fix #2 regression: customize.sh records the RESOLVED partitions so
# post-fs-data masks the right overlay paths (not a bogus system/* glob).
# --------------------------------------------------------------------------

@test "fix2: resolved partitions are recorded to .microg-partitions (deduped)" {
	run_customize
	[ "$status" -eq 0 ]
	[ -f "$MODPATH/.microg-partitions" ]
	# All three default rows resolve to 'product'; the primary is 'product' too,
	# so the deduped manifest must contain exactly one 'product' line.
	local n
	n="$(grep -c '^product$' "$MODPATH/.microg-partitions")"
	[ "$n" -eq 1 ]
	# No bogus component-dir names leaked in as partitions.
	run ! grep -q 'priv-app' "$MODPATH/.microg-partitions"
}

# --------------------------------------------------------------------------
# Fix #3 regression: conflict purge removes API-variant permission XML too, not
# just the base file, so a FakeStore<->Phonesky reflash cannot leave two
# coexisting allowlists.
# --------------------------------------------------------------------------

@test "fix3: conflict purge removes API-variant permission XML (phonesky-34.xml)" {
	# Seed BOTH a base and an API-variant allowlist for the conflicting Phonesky.
	mkdir -p "$MODPATH/system/product/etc/permissions"
	: >"$MODPATH/system/product/etc/permissions/phonesky.xml"
	: >"$MODPATH/system/product/etc/permissions/phonesky-34.xml"
	# An unrelated allowlist must survive (the glob is stem-anchored).
	: >"$MODPATH/system/product/etc/permissions/gmscore.xml"
	run_customize
	[ "$status" -eq 0 ]
	# FakeStore conflicts with Phonesky => both phonesky XMLs purged.
	[ ! -e "$MODPATH/system/product/etc/permissions/phonesky.xml" ]
	[ ! -e "$MODPATH/system/product/etc/permissions/phonesky-34.xml" ]
	# Unrelated allowlist untouched.
	[ -e "$MODPATH/system/product/etc/permissions/gmscore.xml" ]
}
