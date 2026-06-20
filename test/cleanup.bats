#!/usr/bin/env bats
#
# test/cleanup.bats -- host-side unit tests for common/cleanup.sh and the
# self-check logic in service.sh.
#
# The device is fully mocked: $MODPATH and $MICROG_LOG_DIR point at BATS temp
# dirs, so the REPLACE sentinels and log file are written under the test
# scratch area and NEVER touch a real partition or /data. No network.
#
# Run with:  bats test/cleanup.bats

bats_require_minimum_version 1.5.0

# Each @test runs in its own bats subshell, so `export VAR=...` inside a test
# is correctly test-local. shellcheck cannot model the bats preprocessor and
# flags those as subshell-local; suppress the two info codes file-wide.
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper

	local scratch
	scratch="$(_scratch_dir)"

	# Mock device: module overlay root and log dir both in the scratch area.
	export MODPATH="$scratch/modpath.$$.${BATS_TEST_NUMBER:-0}"
	export MICROG_LOG_DIR="$scratch/log.$$.${BATS_TEST_NUMBER:-0}"
	rm -rf "$MODPATH" "$MICROG_LOG_DIR"
	mkdir -p "$MODPATH"

	# Keep debug quiet and clear any leaked root-manager env signals.
	unset MICROG_DEBUG KSU KSU_VER APATCH APATCH_VER MAGISK_VER MAGISK_VER_CODE

	# Pin the declarative stock-dir / app-kind lists so assertions are stable
	# regardless of future additions to the production defaults.
	export CLEANUP_STOCK_DIRS="PrebuiltGmsCore GmsCore GoogleServicesFramework Phonesky Vending"
	export CLEANUP_APP_KINDS="priv-app app"

	# Units call log_*; source the deps then the units under test.
	# shellcheck source=/dev/null
	source "$COMMON_DIR/log.sh"
	# shellcheck source=/dev/null
	source "$COMMON_DIR/detect.sh"
	# shellcheck source=/dev/null
	source "$COMMON_DIR/cleanup.sh"
	log_init
}

# Assert a REPLACE sentinel exists at the expected overlay path.
assert_replace() {
	local part="$1" kind="$2" name="$3"
	[ -f "$MODPATH/system/$part/$kind/$name/.replace" ] \
		|| { echo "missing .replace for $part/$kind/$name" >&2; return 1; }
}

# --------------------------------------------------------------------------
# cleanup_stock_gms -- sentinel creation across kinds and dirs.
# --------------------------------------------------------------------------

@test "cleanup_stock_gms creates .replace sentinels for every stock dir under priv-app and app" {
	run cleanup_stock_gms product overlayfs
	[ "$status" -eq 0 ]

	for kind in priv-app app; do
		for name in PrebuiltGmsCore GmsCore GoogleServicesFramework Phonesky Vending; do
			assert_replace product "$kind" "$name"
		done
	done
}

@test "cleanup_stock_gms sentinel files exist and are regular empty files" {
	cleanup_stock_gms product overlayfs
	local f="$MODPATH/system/product/priv-app/PrebuiltGmsCore/.replace"
	[ -f "$f" ]
	# REPLACE marker content is irrelevant; it must be a plain (empty) file.
	[ ! -s "$f" ]
}

@test "cleanup_stock_gms honors the resolved partition argument" {
	cleanup_stock_gms system_ext overlayfs
	assert_replace system_ext priv-app GmsCore
	assert_replace system_ext app Vending
	# Nothing should have been written under a different partition.
	[ ! -d "$MODPATH/system/product" ]
}

# --------------------------------------------------------------------------
# Idempotence -- running twice is clean and changes nothing.
# --------------------------------------------------------------------------

@test "cleanup_stock_gms is idempotent (second run is a no-op, same tree)" {
	cleanup_stock_gms product magic-mount
	local before
	before="$(find "$MODPATH/system" | sort)"

	run cleanup_stock_gms product magic-mount
	[ "$status" -eq 0 ]

	local after
	after="$(find "$MODPATH/system" | sort)"
	[ "$before" = "$after" ]
}

@test "cleanup_stock_gms does not clobber a pre-existing sentinel" {
	cleanup_stock_gms product overlayfs
	local f="$MODPATH/system/product/priv-app/GmsCore/.replace"
	# Write a marker so we can prove the second run does not recreate/truncate.
	echo "sentinel-kept" >"$f"
	cleanup_stock_gms product overlayfs
	grep -q "sentinel-kept" "$f"
}

# --------------------------------------------------------------------------
# Engine awareness -- same portable mechanism for both engines.
# --------------------------------------------------------------------------

@test "cleanup_stock_gms works under ENGINE=overlayfs" {
	run cleanup_stock_gms product overlayfs
	[ "$status" -eq 0 ]
	assert_replace product priv-app GmsCore
}

@test "cleanup_stock_gms works under ENGINE=magic-mount" {
	run cleanup_stock_gms product magic-mount
	[ "$status" -eq 0 ]
	assert_replace product priv-app GmsCore
}

@test "cleanup_stock_gms produces identical overlay trees for both engines" {
	# The REPLACE sentinel is engine-portable, so the resulting masking tree
	# must be byte-for-byte the same regardless of the detected engine.
	export MODPATH_OVL="$MODPATH.ovl"
	export MODPATH_MM="$MODPATH.mm"
	rm -rf "$MODPATH_OVL" "$MODPATH_MM"

	MODPATH="$MODPATH_OVL" cleanup_stock_gms product overlayfs
	MODPATH="$MODPATH_MM" cleanup_stock_gms product magic-mount

	local ovl mm
	ovl="$(cd "$MODPATH_OVL" && find . | sort)"
	mm="$(cd "$MODPATH_MM" && find . | sort)"
	[ "$ovl" = "$mm" ]
}

@test "cleanup_stock_gms with empty partition is a safe no-op" {
	run cleanup_stock_gms "" overlayfs
	[ "$status" -eq 0 ]
	# No partition dir should have been created.
	[ ! -d "$MODPATH/system" ] || [ -z "$(find "$MODPATH/system" -mindepth 1 2>/dev/null)" ]
}

@test "cleanup_stock_gms logs a REPLACE line per created sentinel" {
	cleanup_stock_gms product overlayfs
	# 5 stock dirs x 2 kinds = 10 REPLACE lines on a first run.
	run grep -c 'REPLACE' "$MICROG_LOG_DIR/selfcheck.log"
	[ "$status" -eq 0 ]
	[ "$output" -ge 10 ]
}

# --------------------------------------------------------------------------
# service.sh self-check -- bounded boot loop + OK/PROBLEM verdict.
# --------------------------------------------------------------------------

# Source service.sh with main suppressed so we can drive its functions.
# boot_getprop VALUE
# Wire detect.sh/service.sh's GETPROP seam to a fixture that reports
# sys.boot_completed == VALUE, reusing the project's fake-getprop mock.
boot_getprop() {
	local value="$1"
	local fixture="$MODPATH/boot-getprop.txt"
	printf '[sys.boot_completed]: [%s]\n' "$value" >"$fixture"
	export GETPROP_FIXTURE="$fixture"
	export GETPROP="sh $FIXTURES_DIR/fake-getprop.sh"
}

load_service() {
	export SVC_NO_MAIN=1
	# On device MODDIR == the module dir == MODPATH. Mirror that here: point
	# MODDIR at our mocked MODPATH (so the overlay scan sees the dirs the tests
	# create under $MODPATH/system) and link in the real common/ libs so the
	# script's `. "$MODDIR/common/..."` sources resolve. Sourcing service.sh
	# re-sources log.sh, which resets MICROG_LOG_PATH, so re-init the log sink.
	export MODDIR="$MODPATH"
	ln -snf "$COMMON_DIR" "$MODPATH/common"
	# shellcheck source=/dev/null
	source "$REPO_ROOT/service.sh"
	log_init
}

@test "service.sh svc_wait_boot returns 0 when boot_completed=1 (bounded loop)" {
	load_service
	boot_getprop 1
	export SVC_BOOT_SLEEP=0
	export SVC_BOOT_MAX_TRIES=3
	run svc_wait_boot
	[ "$status" -eq 0 ]
}

@test "service.sh svc_wait_boot is bounded: gives up (non-zero) when boot never completes" {
	load_service
	# getprop always reports not-completed; the loop must still terminate.
	boot_getprop 0
	export SVC_BOOT_SLEEP=0
	export SVC_BOOT_MAX_TRIES=5
	run svc_wait_boot
	[ "$status" -ne 0 ]
}

@test "service.sh self-check writes OK verdict for a populated overlay" {
	load_service
	# Populate the overlay with a placed microG package dir.
	mkdir -p "$MODPATH/system/product/priv-app/GmsCore"
	touch "$MODPATH/system/product/priv-app/GmsCore/GmsCore.apk"
	getprop_fixture getprop-arm64-api33.txt

	run svc_selfcheck
	[ "$status" -eq 0 ]
	grep -q 'verdict OK' "$MICROG_LOG_DIR/selfcheck.log"
	grep -q 'GmsCore' "$MICROG_LOG_DIR/selfcheck.log"
}

@test "service.sh self-check writes PROBLEM verdict for an empty overlay" {
	load_service
	# No microG dirs placed.
	mkdir -p "$MODPATH/system/product/priv-app"
	getprop_fixture getprop-arm64-api33.txt

	run svc_selfcheck
	[ "$status" -ne 0 ]
	grep -q 'verdict PROBLEM' "$MICROG_LOG_DIR/selfcheck.log"
}

@test "service.sh self-check logs detected environment line" {
	load_service
	mkdir -p "$MODPATH/system/product/priv-app/GmsCore"
	getprop_fixture getprop-arm64-api33.txt
	svc_selfcheck || true
	grep -Eq 'selfcheck: env api=33 arch=arm64' "$MICROG_LOG_DIR/selfcheck.log"
}

@test "service.sh svc_main runs end-to-end with fake boot and populated overlay" {
	load_service
	mkdir -p "$MODPATH/system/product/priv-app/FakeStore"
	boot_getprop 1
	export SVC_BOOT_SLEEP=0
	export SVC_BOOT_MAX_TRIES=2
	run svc_main
	[ "$status" -eq 0 ]
	grep -q 'verdict OK' "$MICROG_LOG_DIR/selfcheck.log"
}
