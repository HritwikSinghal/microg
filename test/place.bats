#!/usr/bin/env bats
#
# test/place.bats -- host-side unit tests for common/place.sh.
#
# The device is fully mocked: $MODPATH is a throwaway tmpdir, $MICROG_LOG_DIR is
# redirected into a temp dir, and detect_partitions is driven by the detect.sh
# seams ($DETECT_ROOT / $DETECT_PART_CANDIDATES). Nothing here writes to a real
# path or touches the network.
#
# Run with:  bats test/place.bats

bats_require_minimum_version 1.5.0

# Each @test runs in its own bats subshell, so `export VAR=...` inside a test is
# correctly scoped. shellcheck cannot model the bats preprocessor and flags
# these as subshell-local; suppress those two info-level codes file-wide.
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper

	# Logging into a per-test temp dir; never the real /data/adb path.
	local scratch
	scratch="$(_scratch_dir)"
	export MICROG_LOG_DIR="$scratch/log.$$.${BATS_TEST_NUMBER:-0}"
	rm -rf "$MICROG_LOG_DIR"
	unset MICROG_DEBUG

	# Mock $MODPATH: the in-ZIP root that place.sh reads assets from and writes
	# the overlay tree under.
	export MODPATH="$scratch/modpath.$$.${BATS_TEST_NUMBER:-0}"
	rm -rf "$MODPATH"
	mkdir -p "$MODPATH/apks"

	# detect_partitions is seam-driven. Point DETECT_ROOT at a fixture tree and
	# constrain the candidate set so tests fully control which partitions the
	# probe reports. Default fixture: product present (the manifest's declared
	# partition for the GMS components).
	export DETECT_ROOT="$scratch/detroot.$$.${BATS_TEST_NUMBER:-0}"
	rm -rf "$DETECT_ROOT"
	mkdir -p "$DETECT_ROOT/system" "$DETECT_ROOT/product"
	export DETECT_PART_CANDIDATES="system system_ext product vendor"

	# Source dependencies first (place.sh assumes log_* and detect_partitions
	# are in scope), then the unit under test.
	# shellcheck source=/dev/null
	source "$COMMON_DIR/log.sh"
	# shellcheck source=/dev/null
	source "$COMMON_DIR/detect.sh"
	# shellcheck source=/dev/null
	source "$COMMON_DIR/place.sh"

	log_init
}

# Helper: stage a dummy asset with known content inside $MODPATH.
_stage_asset() {
	local rel="$1" content="$2"
	mkdir -p "$MODPATH/$(dirname "$rel")"
	printf '%s' "$content" >"$MODPATH/$rel"
}

# --------------------------------------------------------------------------
# place_app -- happy path, replace-on-reflash, missing asset.
# --------------------------------------------------------------------------

@test "place_app creates priv-app/<Name>/<Name>.apk and copies the asset" {
	_stage_asset "apks/GmsCore.apk" "APKBODY-v1"
	run place_app "GmsCore" "apks/GmsCore.apk" "product"
	[ "$status" -eq 0 ]

	local dest="$MODPATH/system/product/priv-app/GmsCore/GmsCore.apk"
	[ -f "$dest" ]
	[ "$(cat "$dest")" = "APKBODY-v1" ]
}

@test "place_app re-flash is idempotent: replaces, never duplicates or merges" {
	_stage_asset "apks/GmsCore.apk" "APKBODY-v1"
	run place_app "GmsCore" "apks/GmsCore.apk" "product"
	[ "$status" -eq 0 ]

	# Drop a stale leftover that a naive merge would keep around.
	touch "$MODPATH/system/product/priv-app/GmsCore/stale.apk"

	# Re-flash with new content.
	_stage_asset "apks/GmsCore.apk" "APKBODY-v2"
	run place_app "GmsCore" "apks/GmsCore.apk" "product"
	[ "$status" -eq 0 ]

	local dir="$MODPATH/system/product/priv-app/GmsCore"
	# Fresh content won.
	[ "$(cat "$dir/GmsCore.apk")" = "APKBODY-v2" ]
	# Stale file is gone (replace, not merge).
	[ ! -e "$dir/stale.apk" ]
	# Exactly one .apk under the app dir (no duplicates).
	run find "$dir" -maxdepth 1 -name '*.apk'
	[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

@test "place_app on a missing asset returns non-zero and logs an error" {
	# No asset staged.
	run place_app "GmsCore" "apks/GmsCore.apk" "product"
	[ "$status" -ne 0 ]
	# No overlay dir should have been created.
	[ ! -d "$MODPATH/system/product/priv-app/GmsCore" ]
	# Error was logged.
	grep -q '\[ERROR\] place_app:' "$MICROG_LOG_DIR/selfcheck.log"
}

# --------------------------------------------------------------------------
# place_framework -- happy path under framework/<basename>, idempotent.
# --------------------------------------------------------------------------

@test "place_framework creates framework/<basename> from the asset" {
	_stage_asset "apks/maps.jar" "JARBODY-v1"
	run place_framework "MapsV1" "apks/maps.jar" "product"
	[ "$status" -eq 0 ]

	local dest="$MODPATH/system/product/framework/maps.jar"
	[ -f "$dest" ]
	[ "$(cat "$dest")" = "JARBODY-v1" ]
}

@test "place_framework re-flash overwrites in place (no duplicate jars)" {
	_stage_asset "apks/maps.jar" "JARBODY-v1"
	run place_framework "MapsV1" "apks/maps.jar" "product"
	[ "$status" -eq 0 ]

	_stage_asset "apks/maps.jar" "JARBODY-v2"
	run place_framework "MapsV1" "apks/maps.jar" "product"
	[ "$status" -eq 0 ]

	local dir="$MODPATH/system/product/framework"
	[ "$(cat "$dir/maps.jar")" = "JARBODY-v2" ]
	run find "$dir" -maxdepth 1 -name 'maps.jar'
	[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

@test "place_framework on a missing asset returns non-zero and logs an error" {
	run place_framework "MapsV1" "apks/maps.jar" "product"
	[ "$status" -ne 0 ]
	[ ! -f "$MODPATH/system/product/framework/maps.jar" ]
	grep -q '\[ERROR\] place_framework:' "$MICROG_LOG_DIR/selfcheck.log"
}

# --------------------------------------------------------------------------
# place_remove -- idempotent removal of priv-app + same-named framework jar.
# --------------------------------------------------------------------------

@test "place_remove deletes an existing priv-app dir" {
	_stage_asset "apks/FakeStore.apk" "FAKE"
	run place_app "FakeStore" "apks/FakeStore.apk" "product"
	[ "$status" -eq 0 ]
	[ -d "$MODPATH/system/product/priv-app/FakeStore" ]

	run place_remove "FakeStore" "product"
	[ "$status" -eq 0 ]
	[ ! -d "$MODPATH/system/product/priv-app/FakeStore" ]
}

@test "place_remove is a no-op (returns 0) when nothing is present" {
	run place_remove "FakeStore" "product"
	[ "$status" -eq 0 ]
	[ ! -d "$MODPATH/system/product/priv-app/FakeStore" ]
}

@test "place_remove is idempotent across repeated calls" {
	_stage_asset "apks/FakeStore.apk" "FAKE"
	place_app "FakeStore" "apks/FakeStore.apk" "product"
	run place_remove "FakeStore" "product"
	[ "$status" -eq 0 ]
	# Second removal on an already-clean overlay must still succeed.
	run place_remove "FakeStore" "product"
	[ "$status" -eq 0 ]
	[ ! -d "$MODPATH/system/product/priv-app/FakeStore" ]
}

@test "place_remove also clears a same-named framework jar" {
	_stage_asset "apks/Foo.jar" "FOO"
	# Stage a framework jar whose basename matches the component name.
	run place_framework "Foo" "apks/Foo.jar" "product"
	[ "$status" -eq 0 ]
	[ -f "$MODPATH/system/product/framework/Foo.jar" ]

	run place_remove "Foo" "product"
	[ "$status" -eq 0 ]
	[ ! -f "$MODPATH/system/product/framework/Foo.jar" ]
}

# --------------------------------------------------------------------------
# place_resolve_partition -- prefer a detected partition; warn + fall back when
# the declared one is absent.
# --------------------------------------------------------------------------

@test "place_resolve_partition returns the declared partition when detected" {
	# Default fixture has system + product present.
	run place_resolve_partition "product"
	[ "$status" -eq 0 ]
	[ "$output" = "product" ]
}

@test "place_resolve_partition falls back and warns when declared is absent" {
	# Rebuild the detection root WITHOUT system_ext so it is undetected.
	rm -rf "$DETECT_ROOT"
	mkdir -p "$DETECT_ROOT/system" "$DETECT_ROOT/product"

	# place_resolve_partition echoes its choice on stdout and emits the warning
	# on the log mirror (stderr on a host). Separate the streams so $output is
	# the resolved partition only, uncontaminated by the warning line.
	run --separate-stderr place_resolve_partition "system_ext"
	[ "$status" -eq 0 ]
	# Falls back to the declared name unchanged.
	[ "$output" = "system_ext" ]
	# A single warning was logged.
	grep -q "\[WARN\] declared partition 'system_ext' not detected" \
		"$MICROG_LOG_DIR/selfcheck.log"
}

@test "place_resolve_partition does not confuse system with system_ext" {
	# Only system_ext present, declaring 'system' must be treated as absent
	# (whole-word match, not substring).
	rm -rf "$DETECT_ROOT"
	mkdir -p "$DETECT_ROOT/system_ext"

	run --separate-stderr place_resolve_partition "system"
	[ "$status" -eq 0 ]
	[ "$output" = "system" ]
	grep -q "\[WARN\] declared partition 'system' not detected" \
		"$MICROG_LOG_DIR/selfcheck.log"
}

# --------------------------------------------------------------------------
# Fix #4: defense-in-depth -- an empty name or partition must never let the
# rm -rf collapse onto a parent dir and wipe sibling components.
# --------------------------------------------------------------------------

@test "place_app refuses an empty name and does not touch the overlay" {
	# Pre-seed a sibling so we can prove it is NOT deleted by a bad call.
	mkdir -p "$MODPATH/system/product/priv-app/Sibling"
	: >"$MODPATH/system/product/priv-app/Sibling/keep"
	_stage_asset "apks/GmsCore.apk" "BODY"
	run place_app "" "apks/GmsCore.apk" "product"
	[ "$status" -ne 0 ]
	# The whole priv-app dir (and the sibling) must still be intact.
	[ -e "$MODPATH/system/product/priv-app/Sibling/keep" ]
}

@test "place_app refuses an empty partition" {
	_stage_asset "apks/GmsCore.apk" "BODY"
	run place_app "GmsCore" "apks/GmsCore.apk" ""
	[ "$status" -ne 0 ]
	grep -q '\[ERROR\] place_app: refusing' "$MICROG_LOG_DIR/selfcheck.log"
}

@test "place_remove refuses an empty name and leaves siblings intact" {
	mkdir -p "$MODPATH/system/product/priv-app/Sibling"
	: >"$MODPATH/system/product/priv-app/Sibling/keep"
	run place_remove "" "product"
	# A guarded no-op (returns 0) -- but it must NOT have wiped the priv-app dir.
	[ "$status" -eq 0 ]
	[ -e "$MODPATH/system/product/priv-app/Sibling/keep" ]
}

@test "place_remove refuses an empty partition" {
	mkdir -p "$MODPATH/system/product/priv-app/FakeStore"
	run place_remove "FakeStore" ""
	[ "$status" -eq 0 ]
	# Nothing under product touched (the guard fired before computing the path).
	[ -d "$MODPATH/system/product/priv-app/FakeStore" ]
}
