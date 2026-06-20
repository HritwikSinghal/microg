#!/usr/bin/env bats
#
# test/detect.bats -- host-side unit tests for common/detect.sh.
#
# Runs purely on the host with fixtures: no device, no network. Detection's
# two indirection seams (the GETPROP program and the DETECT_ROOT / DETECT_MOUNTS
# filesystem prefix) are pointed at mocks so every probe is exercised against
# known inputs.
#
# Run with:  bats test/

# Each @test runs in its own bats subshell, so `export DETECT_ROOT=...` inside a
# test is the correct, intended scope. shellcheck (which does not model the bats
# preprocessor) flags these as subshell-local modifications; suppress those two
# info-level codes file-wide.
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# Source the library under test. Sourcing must be side-effect free.
	# shellcheck source=/dev/null
	source "$COMMON_DIR/detect.sh"
	# Clear env-based root-manager signals so the host environment cannot leak
	# into the on-disk-marker tests.
	unset KSU KSU_VER APATCH APATCH_VER MAGISK_VER MAGISK_VER_CODE
}

# --------------------------------------------------------------------------
# detect_api / detect_arch / detect_is64bit -- driven by getprop fixtures.
# --------------------------------------------------------------------------

@test "arm64 API 33: api/arch/is64bit" {
	getprop_fixture getprop-arm64-api33.txt
	[ "$(detect_api)" = "33" ]
	[ "$(detect_arch)" = "arm64" ]
	[ "$(detect_is64bit)" = "true" ]
}

@test "arm32 API 27: api/arch/is64bit (32-bit case)" {
	getprop_fixture getprop-arm32-api27.txt
	[ "$(detect_api)" = "27" ]
	[ "$(detect_arch)" = "arm" ]
	[ "$(detect_is64bit)" = "false" ]
}

@test "x86_64 API 34: api/arch/is64bit" {
	getprop_fixture getprop-x86_64-api34.txt
	[ "$(detect_api)" = "34" ]
	[ "$(detect_arch)" = "x86_64" ]
	[ "$(detect_is64bit)" = "true" ]
}

@test "empty getprop: safe fallbacks (api=0, arch=unknown, is64bit=false)" {
	getprop_fixture getprop-empty.txt
	[ "$(detect_api)" = "0" ]
	[ "$(detect_arch)" = "unknown" ]
	[ "$(detect_is64bit)" = "false" ]
}

# --------------------------------------------------------------------------
# detect_root_manager -- env signals and on-disk markers via DETECT_ROOT.
# --------------------------------------------------------------------------

@test "root manager: Magisk via /data/adb/magisk dir" {
	local root
	root="$(make_fixture_root)"
	mkdir -p "$root/data/adb/magisk"
	export DETECT_ROOT="$root"
	[ "$(detect_root_manager)" = "magisk" ]
}

@test "root manager: KernelSU via /data/adb/ksud marker" {
	local root
	root="$(make_fixture_root)"
	mkdir -p "$root/data/adb"
	touch "$root/data/adb/ksud"
	export DETECT_ROOT="$root"
	[ "$(detect_root_manager)" = "kernelsu" ]
}

@test "root manager: KernelSU via KSU=true env wins even with magisk dir" {
	local root
	root="$(make_fixture_root)"
	mkdir -p "$root/data/adb/magisk"
	export DETECT_ROOT="$root"
	export KSU="true"
	[ "$(detect_root_manager)" = "kernelsu" ]
}

@test "root manager: APatch via /data/adb/apd marker" {
	local root
	root="$(make_fixture_root)"
	mkdir -p "$root/data/adb"
	touch "$root/data/adb/apd"
	export DETECT_ROOT="$root"
	[ "$(detect_root_manager)" = "apatch" ]
}

@test "root manager: unknown when no signals present" {
	local root
	root="$(make_fixture_root)"
	mkdir -p "$root/data/adb"
	export DETECT_ROOT="$root"
	[ "$(detect_root_manager)" = "unknown" ]
}

# --------------------------------------------------------------------------
# detect_mount_engine -- engine probed from mount table / mirror, NOT inferred
# from the root manager (spec 5.3).
# --------------------------------------------------------------------------

@test "mount engine: OverlayFS from /proc/mounts overlay on /system" {
	local root mounts
	root="$(make_fixture_root)"
	mounts="$(write_mounts "$root" \
		"overlay /system overlay ro,relatime,lowerdir=/system 0 0")"
	export DETECT_ROOT="$root"
	export DETECT_MOUNTS="$mounts"
	[ "$(detect_mount_engine)" = "overlayfs" ]
}

@test "mount engine: KSU+OverlayFS API 34 scenario" {
	# KernelSU configured with OverlayFS. The engine must come from the mount
	# table, independent of the (KSU) root manager.
	local root mounts
	root="$(make_fixture_root)"
	mkdir -p "$root/data/adb"
	touch "$root/data/adb/ksud"
	mounts="$(write_mounts "$root" \
		"overlay / overlay rw,relatime,lowerdir=/ 0 0")"
	export DETECT_ROOT="$root"
	export DETECT_MOUNTS="$mounts"
	getprop_fixture getprop-x86_64-api34.txt
	[ "$(detect_root_manager)" = "kernelsu" ]
	[ "$(detect_mount_engine)" = "overlayfs" ]
}

@test "mount engine: Magisk magic-mount from mirror tree" {
	# Magisk+magic-mount API 33 scenario: no overlay mount, mirror dir present.
	local root mounts
	root="$(make_fixture_root)"
	mkdir -p "$root/data/adb/magisk"
	mkdir -p "$root/data/adb/.magisk/mirror"
	mounts="$(write_mounts "$root" \
		"/dev/block/dm-0 /system ext4 ro,relatime 0 0")"
	export DETECT_ROOT="$root"
	export DETECT_MOUNTS="$mounts"
	getprop_fixture getprop-arm64-api33.txt
	[ "$(detect_root_manager)" = "magisk" ]
	[ "$(detect_mount_engine)" = "magic-mount" ]
}

@test "mount engine: unknown when neither overlay nor mirror present" {
	local root mounts
	root="$(make_fixture_root)"
	mounts="$(write_mounts "$root" \
		"/dev/block/dm-0 /system ext4 ro,relatime 0 0")"
	export DETECT_ROOT="$root"
	export DETECT_MOUNTS="$mounts"
	[ "$(detect_mount_engine)" = "unknown" ]
}

@test "mount engine: overlay on non-system mount is ignored" {
	# An overlay mounted somewhere unrelated (e.g. /tmp) must not be read as
	# the system mount engine.
	local root mounts
	root="$(make_fixture_root)"
	mounts="$(write_mounts "$root" \
		"overlay /tmp/work overlay rw 0 0")"
	export DETECT_ROOT="$root"
	export DETECT_MOUNTS="$mounts"
	[ "$(detect_mount_engine)" = "unknown" ]
}

# --------------------------------------------------------------------------
# detect_partitions -- presence by directory existence under DETECT_ROOT.
# --------------------------------------------------------------------------

@test "partitions: full layout system/product/system_ext present, ordered" {
	local root
	root="$(make_fixture_root)"
	mkdir -p "$root/system" "$root/product" "$root/system_ext"
	export DETECT_ROOT="$root"
	# Canonical order from DETECT_PART_CANDIDATES: system system_ext product ...
	[ "$(detect_partitions)" = "system system_ext product" ]
}

@test "partitions: missing-partition layout (system only)" {
	local root
	root="$(make_fixture_root)"
	mkdir -p "$root/system"
	export DETECT_ROOT="$root"
	[ "$(detect_partitions)" = "system" ]
}

@test "partitions: nested /system/product is detected as product" {
	local root
	root="$(make_fixture_root)"
	mkdir -p "$root/system/product"
	export DETECT_ROOT="$root"
	# system dir exists (parent of product) plus product nested under it.
	[ "$(detect_partitions)" = "system product" ]
}

@test "partitions: empty when no partition dirs exist" {
	local root
	root="$(make_fixture_root)"
	export DETECT_ROOT="$root"
	[ "$(detect_partitions)" = "" ]
}

# --------------------------------------------------------------------------
# Side-effect freedom: sourcing + probing must not write anything.
# --------------------------------------------------------------------------

@test "detection is read-only: fixture root stays empty after probes" {
	local root
	root="$(make_fixture_root)"
	export DETECT_ROOT="$root"
	getprop_fixture getprop-arm64-api33.txt
	detect_api >/dev/null
	detect_arch >/dev/null
	detect_is64bit >/dev/null
	detect_root_manager >/dev/null
	detect_mount_engine >/dev/null
	detect_partitions >/dev/null
	# The probes must not have created any file or directory in the root.
	run find "$root" -mindepth 1
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
