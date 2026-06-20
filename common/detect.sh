# shellcheck shell=sh
#
# common/detect.sh -- pure, read-only environment probes (spec 5.2 unit 1).
#
# This is the Detection logical unit: it ONLY reads. No mounting, no writing,
# no file creation, no side effects. Every probe is exposed as a function that
# echoes a single value on stdout, so callers can capture it:
#
#     api="$(detect_api)"
#     arch="$(detect_arch)"
#     [ "$(detect_is64bit)" = "true" ] && ...
#     mgr="$(detect_root_manager)"          # magisk | kernelsu | apatch | unknown
#     engine="$(detect_mount_engine)"       # overlayfs | magic-mount | unknown
#     parts="$(detect_partitions)"          # space-separated: system product ...
#
# API style (consistent across the file): each detect_* function ECHOES a
# value and returns 0. They do not export variables, so there are no hidden
# globals for customize.sh to track -- it captures what it needs.
#
# ---------------------------------------------------------------------------
# Testability: a single indirection per input source
# ---------------------------------------------------------------------------
# Detection must run on a developer host with mocked inputs (spec 8). To make
# that possible WITHOUT touching the detection logic, every read goes through
# one of two seams that tests can override:
#
#   1. Properties: read via the `_getprop` wrapper, which calls the program
#      named in $GETPROP (default: the real `getprop`). A BATS test sets
#      GETPROP to a fixture script (e.g. a wrapper over a getprop-*.txt file)
#      so detection sees mocked property values.
#
#   2. Files / dirs: every filesystem read is prefixed with $DETECT_ROOT
#      (default: empty = real root "/"). A test points DETECT_ROOT at a
#      fixture tree so /data/adb/magisk, /proc/mounts, etc. resolve into the
#      fixture instead of the live system. The /proc/mounts path is separately
#      overridable via $DETECT_MOUNTS for convenience.
#
# Neither seam changes behaviour on a real device, where the defaults select
# the genuine getprop and the real filesystem.
#
# Do not `set -e` here: this is a sourced library and must not abort the
# caller's shell.

# ---------------------------------------------------------------------------
# Indirection seams (all overridable from the environment for tests).
# ---------------------------------------------------------------------------

# Program used to read system properties. Real device: `getprop`. Tests point
# this at a fixture command. Word-splitting is intentional so callers may set
# e.g. GETPROP="sh /path/to/fake-getprop.sh".
: "${GETPROP:=getprop}"

# Filesystem root prefix for every read. Empty means the real root. Tests set
# this to a fixture directory. A trailing slash is NOT required; paths below
# always include their own leading slash.
: "${DETECT_ROOT:=}"

# Path to the kernel mount table. Defaults to <root>/proc/mounts but is broken
# out so a test can point it at a single fixture file without a full /proc
# tree. Resolved lazily in detect_mount_engine so DETECT_ROOT set after
# sourcing still applies.
: "${DETECT_MOUNTS:=}"

# Candidate partitions to probe, in a stable order. Android may expose any
# subset of these as top-level mount points or symlinked dirs.
: "${DETECT_PART_CANDIDATES:=system system_ext product vendor odm oem}"

# ---------------------------------------------------------------------------
# Internal helpers.
# ---------------------------------------------------------------------------

# _getprop NAME [DEFAULT]
# Read a single property through the overridable GETPROP program. Echoes the
# trimmed value, or DEFAULT (empty if unset) when the property is missing or
# the program is unavailable. $GETPROP is intentionally unquoted to allow a
# multi-word test command.
_getprop() {
	_gp_name="$1"
	_gp_default="${2:-}"
	# shellcheck disable=SC2086
	_gp_val="$($GETPROP "$_gp_name" 2>/dev/null)"
	if [ -z "$_gp_val" ]; then
		_gp_val="$_gp_default"
	fi
	printf '%s' "$_gp_val"
	unset _gp_name _gp_default _gp_val
	return 0
}

# _mounts_path: resolve the mount table path honouring overrides.
_mounts_path() {
	if [ -n "$DETECT_MOUNTS" ]; then
		printf '%s' "$DETECT_MOUNTS"
	else
		printf '%s' "${DETECT_ROOT}/proc/mounts"
	fi
}

# ---------------------------------------------------------------------------
# Public probes.
# ---------------------------------------------------------------------------

# detect_api: Android SDK / API level (integer), e.g. 33. Echoes "0" when it
# cannot be determined so numeric comparisons by callers stay well-defined.
detect_api() {
	_api="$(_getprop ro.build.version.sdk 0)"
	# Guard against a non-numeric value from a malformed fixture or property.
	case "$_api" in
	'' | *[!0-9]*) _api=0 ;;
	esac
	printf '%s' "$_api"
	unset _api
	return 0
}

# detect_is64bit: "true" if the device runs a 64-bit primary ABI, else
# "false". Derived from ro.product.cpu.abi (the primary ABI) so it reflects
# what Android actually loads, matching how IS64BIT is used downstream.
detect_is64bit() {
	_abi="$(_getprop ro.product.cpu.abi)"
	case "$_abi" in
	*64*) printf '%s' "true" ;;
	*) printf '%s' "false" ;;
	esac
	unset _abi
	return 0
}

# detect_arch: normalised CPU architecture token, one of:
#   arm64 | arm | x86_64 | x86 | unknown
# Normalised from the primary ABI so callers can select matching native libs
# without re-parsing ABI strings.
detect_arch() {
	_abi="$(_getprop ro.product.cpu.abi)"
	case "$_abi" in
	arm64* | aarch64*) printf '%s' "arm64" ;;
	armeabi* | armv* | arm) printf '%s' "arm" ;;
	x86_64 | x86-64) printf '%s' "x86_64" ;;
	x86 | i?86) printf '%s' "x86" ;;
	*) printf '%s' "unknown" ;;
	esac
	unset _abi
	return 0
}

# detect_root_manager: which root solution is installed, one of:
#   magisk | kernelsu | apatch | unknown
#
# Order matters. KernelSU and APatch are checked before Magisk because a
# device can carry leftover Magisk artifacts; the more specific signals win.
# Signals (spec 5.3 and root-manager knowledge):
#   - KernelSU: KSU=true / KSU_VER in env, or <root>/data/adb/ksud present.
#   - APatch:   APATCH env set, or <root>/data/adb/apd present.
#   - Magisk:   MAGISK_VER in env, or <root>/data/adb/magisk present.
# Env signals are checked first (cheap, set during a live install), then the
# on-disk markers (also visible to host fixtures via DETECT_ROOT).
detect_root_manager() {
	_adb="${DETECT_ROOT}/data/adb"

	# KernelSU.
	if [ "${KSU:-}" = "true" ] || [ -n "${KSU_VER:-}" ]; then
		printf '%s' "kernelsu"
		unset _adb
		return 0
	fi
	if [ -e "$_adb/ksud" ] || [ -d "$_adb/ksu" ]; then
		printf '%s' "kernelsu"
		unset _adb
		return 0
	fi

	# APatch.
	if [ -n "${APATCH:-}" ] || [ -n "${APATCH_VER:-}" ]; then
		printf '%s' "apatch"
		unset _adb
		return 0
	fi
	if [ -e "$_adb/apd" ] || [ -d "$_adb/ap" ]; then
		printf '%s' "apatch"
		unset _adb
		return 0
	fi

	# Magisk.
	if [ -n "${MAGISK_VER:-}" ] || [ -n "${MAGISK_VER_CODE:-}" ]; then
		printf '%s' "magisk"
		unset _adb
		return 0
	fi
	if [ -d "$_adb/magisk" ] || [ -e "$_adb/magisk.db" ]; then
		printf '%s' "magisk"
		unset _adb
		return 0
	fi

	printf '%s' "unknown"
	unset _adb
	return 0
}

# detect_mount_engine: how the systemless overlay is mounted, one of:
#   overlayfs | magic-mount | unknown
#
# CRITICAL (spec 5.3): detect the ENGINE itself, never infer it from the root
# manager -- KernelSU and APatch can each be configured for either engine, and
# whiteout/removal semantics differ. We probe observable state:
#
#   1. OverlayFS: the live mount table shows an `overlay` filesystem mounted
#      on /system (or /, /product, /system_ext). This is the strongest signal
#      and is read from the (overridable) mount table.
#   2. Magic-mount: Magisk's mirror tree exists (<root>/data/adb/.magisk/mirror
#      or the legacy /sbin/.magisk/mirror), the fingerprint of magic-mount.
#
# If neither is observable the engine is "unknown" (caller should prefer the
# portable declarative REPLACE removal regardless).
detect_mount_engine() {
	_mounts="$(_mounts_path)"

	# 1. OverlayFS via the mount table. Match an `overlay` filesystem whose
	#    mount point is a system partition. /proc/mounts columns are:
	#    <src> <mountpoint> <fstype> <opts> <dump> <pass>.
	if [ -r "$_mounts" ]; then
		# Look for: overlay mounted on a system-ish path. We check fstype
		# (3rd field) == overlay AND mountpoint (2nd field) under /system,
		# /product, /system_ext or exactly /.
		if awk '
			$3 == "overlay" {
				mp = $2
				if (mp == "/" || mp == "/system" || mp == "/product" || \
				    mp == "/system_ext" || \
				    index(mp, "/system/") == 1 || \
				    index(mp, "/product/") == 1 || \
				    index(mp, "/system_ext/") == 1) {
					found = 1
				}
			}
			END { exit(found ? 0 : 1) }
		' "$_mounts" 2>/dev/null; then
			printf '%s' "overlayfs"
			unset _mounts
			return 0
		fi
	fi

	# 2. Magisk magic-mount mirror tree.
	if [ -d "${DETECT_ROOT}/data/adb/.magisk/mirror" ] ||
		[ -d "${DETECT_ROOT}/sbin/.magisk/mirror" ] ||
		[ -d "${DETECT_ROOT}/debug_ramdisk/.magisk/mirror" ]; then
		printf '%s' "magic-mount"
		unset _mounts
		return 0
	fi

	printf '%s' "unknown"
	unset _mounts
	return 0
}

# detect_partitions: which OS partitions exist on this device, as a
# space-separated list in the canonical order of DETECT_PART_CANDIDATES, e.g.
# "system product system_ext". A partition counts as present when its
# top-level directory exists under the detection root (real device: a mounted
# partition or a /system/<part> symlink target). Echoes an empty string if
# none are found (degenerate; caller should treat as system-only).
#
# "system" is always considered present on a real device, but here we still
# probe it so a fixture can model a stripped layout (missing-partition test).
detect_partitions() {
	_found=""
	for _part in $DETECT_PART_CANDIDATES; do
		# A partition may appear as a top-level dir (/product) or nested
		# under /system (/system/product) on devices that symlink them.
		if [ -d "${DETECT_ROOT}/$_part" ] ||
			[ -d "${DETECT_ROOT}/system/$_part" ]; then
			if [ -z "$_found" ]; then
				_found="$_part"
			else
				_found="$_found $_part"
			fi
		fi
	done
	printf '%s' "$_found"
	unset _found _part
	return 0
}
