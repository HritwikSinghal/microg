#!/usr/bin/env bats
#
# test/perms.bats -- host-side unit tests for common/perms.sh.
#
# The device is fully mocked: $MODPATH is a per-test tmpdir under the BATS
# scratch dir, $MICROG_LOG_DIR is a separate tmpdir, and all fixture XML lives
# under "$MODPATH/perms". Nothing is written to a real path; no network.
#
# perms.sh calls log_* and (optionally) xmllint. setup() sources log.sh then
# perms.sh, matching the contract. xmllint may or may not be present on the
# host: the validation tests guard the assertions that require it so the suite
# passes either way (it exercises the degrade path when xmllint is absent).
#
# Run with:  bats test/perms.bats

# Each @test runs in its own bats subshell, so `export VAR=...` inside a test is
# correctly test-local. shellcheck (which does not model the bats preprocessor)
# reports these as subshell-local; suppress those info-level codes file-wide.
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper

	local scratch
	scratch="$(_scratch_dir)"

	# Mock device root for placement and the in-ZIP perms/ source dir.
	export MODPATH="$scratch/modpath.$$.${BATS_TEST_NUMBER:-0}"
	# Log into a separate temp dir so the suite never touches /data/adb.
	export MICROG_LOG_DIR="$scratch/log.$$.${BATS_TEST_NUMBER:-0}"
	rm -rf "$MODPATH" "$MICROG_LOG_DIR"
	mkdir -p "$MODPATH/perms"

	# Source the helpers perms.sh relies on, then the unit under test.
	# shellcheck source=/dev/null
	source "$COMMON_DIR/log.sh"
	# shellcheck source=/dev/null
	source "$COMMON_DIR/perms.sh"
	log_init
}

# --------------------------------------------------------------------------
# Fixtures.
# --------------------------------------------------------------------------

# write_valid_perms PATH [PACKAGE]
# Write a well-formed privapp-permissions allowlist matching genperms output.
write_valid_perms() {
	local path="$1"
	local pkg="${2:-com.google.android.gms}"
	mkdir -p "$(dirname "$path")"
	cat >"$path" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<permissions>
  <privapp-permissions package="$pkg">
    <permission name="android.permission.FAKE_PACKAGE_SIGNATURE"/>
    <permission name="android.permission.INSTALL_PACKAGES"/>
  </privapp-permissions>
</permissions>
EOF
}

# write_valid_sysconfig PATH
write_valid_sysconfig() {
	local path="$1"
	mkdir -p "$(dirname "$path")"
	cat >"$path" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<permissions>
  <allow-in-power-save package="com.google.android.gms"/>
  <allow-unthrottled-location package="com.google.android.gms"/>
</permissions>
EOF
}

# write_malformed_xml PATH -- an unclosed tag, rejected by xmllint.
write_malformed_xml() {
	local path="$1"
	mkdir -p "$(dirname "$path")"
	printf '%s\n' '<permissions><privapp-permissions package="x">' >"$path"
}

# has_xmllint -- true when xmllint is on PATH (controls the strict assertions).
has_xmllint() {
	command -v xmllint >/dev/null 2>&1
}

# clean_bin_without_xmllint
# Build a bin dir holding only the externals perms.sh + log.sh need (date, cp,
# mkdir, basename, ...) but NOT xmllint, and echo its path. Pointing PATH at it
# forces perms_validate's `command -v xmllint` to miss while keeping log.sh's
# `date` and the placement `cp`/`mkdir` working -- so we exercise the genuine
# degrade branch on a host that DOES have xmllint, without emptying PATH wholesale.
clean_bin_without_xmllint() {
	local bd="$MODPATH/clean-bin"
	mkdir -p "$bd"
	local t p
	for t in date printf cp mkdir basename find grep cat sh env rm ls; do
		p="$(command -v "$t" 2>/dev/null)" || continue
		[ -n "$p" ] && ln -sf "$p" "$bd/$t"
	done
	printf '%s' "$bd"
}

# --------------------------------------------------------------------------
# perms_select.
# --------------------------------------------------------------------------

@test "perms_select returns the base file when only the base exists" {
	write_valid_perms "$MODPATH/perms/gmscore.xml"
	run perms_select "perms/gmscore.xml" 34
	[ "$status" -eq 0 ]
	[ "$output" = "$MODPATH/perms/gmscore.xml" ]
}

@test "perms_select prefers a per-API variant when present" {
	write_valid_perms "$MODPATH/perms/gmscore.xml"
	write_valid_perms "$MODPATH/perms/gmscore-34.xml"
	run perms_select "perms/gmscore.xml" 34
	[ "$status" -eq 0 ]
	[ "$output" = "$MODPATH/perms/gmscore-34.xml" ]
}

@test "perms_select falls back to base when the API variant is absent" {
	write_valid_perms "$MODPATH/perms/gmscore.xml"
	# A variant for a DIFFERENT api exists; the requested api has none.
	write_valid_perms "$MODPATH/perms/gmscore-33.xml"
	run perms_select "perms/gmscore.xml" 34
	[ "$status" -eq 0 ]
	[ "$output" = "$MODPATH/perms/gmscore.xml" ]
}

@test "perms_select echoes empty when no file is found" {
	run perms_select "perms/missing.xml" 34
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "perms_select uses the base when API is unknown (0)" {
	write_valid_perms "$MODPATH/perms/gmscore.xml"
	# Even if a numeric-looking variant existed, api 0 must not probe variants.
	write_valid_perms "$MODPATH/perms/gmscore-0.xml"
	run perms_select "perms/gmscore.xml" 0
	[ "$status" -eq 0 ]
	[ "$output" = "$MODPATH/perms/gmscore.xml" ]
}

@test "perms_select echoes empty for an empty reference" {
	run perms_select "" 34
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# --------------------------------------------------------------------------
# perms_validate.
# --------------------------------------------------------------------------

@test "perms_validate accepts well-formed XML" {
	write_valid_perms "$MODPATH/perms/gmscore.xml"
	run perms_validate "$MODPATH/perms/gmscore.xml"
	[ "$status" -eq 0 ]
}

@test "perms_validate rejects malformed XML when xmllint is available, else degrades" {
	write_malformed_xml "$MODPATH/perms/bad.xml"
	run perms_validate "$MODPATH/perms/bad.xml"
	if has_xmllint; then
		# With a real validator, malformed XML must be rejected.
		[ "$status" -ne 0 ]
	else
		# Without xmllint we degrade: accept rather than fail the install.
		[ "$status" -eq 0 ]
	fi
}

@test "perms_validate fails on a missing file regardless of xmllint" {
	run perms_validate "$MODPATH/perms/does-not-exist.xml"
	[ "$status" -ne 0 ]
}

@test "perms_validate degrades (returns 0) when xmllint is absent" {
	# A valid file so any failure can only come from the validator path itself.
	write_valid_perms "$MODPATH/perms/gmscore.xml"
	if has_xmllint; then
		# Force the no-xmllint branch by pointing PATH at a bin dir that holds
		# every external log.sh/perms.sh need EXCEPT xmllint (see helper).
		local clean_bin
		clean_bin="$(clean_bin_without_xmllint)"
		PATH="$clean_bin" run perms_validate "$MODPATH/perms/gmscore.xml"
		[ "$status" -eq 0 ]
		# The degrade warning must have been logged.
		grep -q 'xmllint not available' "$MICROG_LOG_DIR/selfcheck.log"
	else
		# xmllint already absent on this host: exercise the same path directly.
		write_valid_perms "$MODPATH/perms/gmscore.xml"
		run perms_validate "$MODPATH/perms/gmscore.xml"
		[ "$status" -eq 0 ]
	fi
}

# --------------------------------------------------------------------------
# perms_place_app.
# --------------------------------------------------------------------------

@test "perms_place_app copies XML to system/<part>/etc/permissions/<basename>" {
	write_valid_perms "$MODPATH/perms/gmscore.xml"
	run perms_place_app "GmsCore" "perms/gmscore.xml" "product" 34
	[ "$status" -eq 0 ]
	[ -f "$MODPATH/system/product/etc/permissions/gmscore.xml" ]
}

@test "perms_place_app prefers the per-API variant basename at the destination" {
	write_valid_perms "$MODPATH/perms/gmscore.xml"
	write_valid_perms "$MODPATH/perms/gmscore-34.xml"
	run perms_place_app "GmsCore" "perms/gmscore.xml" "product" 34
	[ "$status" -eq 0 ]
	[ -f "$MODPATH/system/product/etc/permissions/gmscore-34.xml" ]
	[ ! -f "$MODPATH/system/product/etc/permissions/gmscore.xml" ]
}

@test "perms_place_app fails when the referenced XML is missing" {
	run perms_place_app "GmsCore" "perms/gmscore.xml" "product" 34
	[ "$status" -ne 0 ]
	[ ! -f "$MODPATH/system/product/etc/permissions/gmscore.xml" ]
}

@test "perms_place_app fails on malformed XML when xmllint is available" {
	if ! has_xmllint; then
		skip "xmllint not available; malformed XML is accepted by design"
	fi
	write_malformed_xml "$MODPATH/perms/gmscore.xml"
	run perms_place_app "GmsCore" "perms/gmscore.xml" "product" 34
	[ "$status" -ne 0 ]
	[ ! -f "$MODPATH/system/product/etc/permissions/gmscore.xml" ]
}

@test "perms_place_app is idempotent: placing twice overwrites cleanly" {
	write_valid_perms "$MODPATH/perms/gmscore.xml" "com.google.android.gms"
	run perms_place_app "GmsCore" "perms/gmscore.xml" "product" 34
	[ "$status" -eq 0 ]

	# Change the source, place again: the destination must reflect the new copy
	# and there must be exactly one file (overwrite, not duplicate).
	write_valid_perms "$MODPATH/perms/gmscore.xml" "com.example.changed"
	run perms_place_app "GmsCore" "perms/gmscore.xml" "product" 34
	[ "$status" -eq 0 ]
	grep -q 'com.example.changed' "$MODPATH/system/product/etc/permissions/gmscore.xml"
	run find "$MODPATH/system/product/etc/permissions" -name 'gmscore.xml'
	[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

# --------------------------------------------------------------------------
# perms_place_framework.
# --------------------------------------------------------------------------

@test "perms_place_framework lands in the same etc/permissions dir" {
	write_valid_perms "$MODPATH/perms/mapsv1.xml" "com.google.android.maps"
	run perms_place_framework "MapsV1" "perms/mapsv1.xml" "product" 34
	[ "$status" -eq 0 ]
	[ -f "$MODPATH/system/product/etc/permissions/mapsv1.xml" ]
}

@test "perms_place_framework fails when the referenced XML is missing" {
	run perms_place_framework "MapsV1" "perms/mapsv1.xml" "product" 34
	[ "$status" -ne 0 ]
}

# --------------------------------------------------------------------------
# perms_place_sysconfig.
# --------------------------------------------------------------------------

@test "perms_place_sysconfig copies sysconfig-microg.xml to etc/sysconfig" {
	write_valid_sysconfig "$MODPATH/perms/sysconfig-microg.xml"
	run perms_place_sysconfig "product"
	[ "$status" -eq 0 ]
	[ -f "$MODPATH/system/product/etc/sysconfig/sysconfig-microg.xml" ]
}

@test "perms_place_sysconfig is a no-op (returns 0) when the file is absent" {
	run perms_place_sysconfig "product"
	[ "$status" -eq 0 ]
	[ ! -e "$MODPATH/system/product/etc/sysconfig/sysconfig-microg.xml" ]
}

@test "perms_place_sysconfig is idempotent: placing twice overwrites cleanly" {
	write_valid_sysconfig "$MODPATH/perms/sysconfig-microg.xml"
	run perms_place_sysconfig "product"
	[ "$status" -eq 0 ]
	run perms_place_sysconfig "product"
	[ "$status" -eq 0 ]
	[ -f "$MODPATH/system/product/etc/sysconfig/sysconfig-microg.xml" ]
	run find "$MODPATH/system/product/etc/sysconfig" -name 'sysconfig-microg.xml'
	[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}
