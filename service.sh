#!/system/bin/sh
#
# service.sh -- boot-gated self-check (spec 7: "service.sh before PMS ready").
#
# Runs in Magisk's late_start service stage. It does NO placement work -- all
# files are already in the overlay by install/post-fs-data time. Its only job
# is to wait until the framework is up (PackageManager has scanned the system
# apps) and then write a human-readable self-check summary to selfcheck.log:
# the detected environment, which microG packages are present in the overlay
# tree, and a final OK / PROBLEM verdict an operator can grep for.
#
# Boot gating: we wait until `getprop sys.boot_completed` == 1, but the wait is
# a BOUNDED loop -- it can never spin forever even if the property never flips
# (a wedged boot, or a host test). The cap is SVC_BOOT_MAX_TRIES iterations of
# SVC_BOOT_SLEEP seconds each; on timeout we still emit a verdict (PROBLEM) so
# the log always has a final line.
#
# Testability: getprop is read through the $GETPROP seam (same convention as
# detect.sh), the loop bounds are overridable, and the sleep is wrapped so a
# host test can make it instant. POSIX sh, no bashisms, no `set -e`.

# On device Magisk invokes this script directly, so its own path ("${0%/*}")
# is the module dir. A pre-set MODDIR wins, which lets a host test point the
# sourced script at the repo root without spoofing $0.
: "${MODDIR:=${0%/*}}"

# shellcheck source=/dev/null
. "$MODDIR/common/log.sh"
# shellcheck source=/dev/null
. "$MODDIR/common/detect.sh"

# Boot-wait bounds (overridable for tests). Defaults: ~120 s worst case.
: "${SVC_BOOT_MAX_TRIES:=120}"
: "${SVC_BOOT_SLEEP:=1}"

# Property reader program, same seam detect.sh exposes so tests inject a fixture
# getprop. Intentionally word-split when invoked (may be "sh fake-getprop.sh").
: "${GETPROP:=getprop}"

# microG package -> overlay directory names we expect to find under a partition
# once placement succeeded. Mirrors components.conf priv-app dir names.
: "${SVC_MICROG_DIRS:=GmsCore GsfProxy FakeStore Phonesky MapsV1}"

# _svc_sleep SECONDS -- wrapped sleep so a test can no-op it (SVC_BOOT_SLEEP=0
# skips the real sleep entirely, keeping the bounded loop instant on a host).
_svc_sleep() {
	[ "$SVC_BOOT_SLEEP" = "0" ] && return 0
	sleep "$1" 2>/dev/null || return 0
}

# _svc_boot_completed -- echo the current sys.boot_completed value via $GETPROP.
_svc_boot_completed() {
	# shellcheck disable=SC2086
	$GETPROP sys.boot_completed 2>/dev/null
}

# svc_wait_boot -- bounded wait for sys.boot_completed=1.
# Returns 0 once boot completed, non-zero if the cap was hit first. The cap
# makes the loop terminating by construction (no unbounded `while true`).
svc_wait_boot() {
	_wb_i=0
	while [ "$_wb_i" -lt "$SVC_BOOT_MAX_TRIES" ]; do
		if [ "$(_svc_boot_completed)" = "1" ]; then
			unset _wb_i
			return 0
		fi
		_wb_i=$((_wb_i + 1))
		_svc_sleep "$SVC_BOOT_SLEEP"
	done
	unset _wb_i
	return 1
}

# svc_selfcheck -- write the environment + presence summary and a final verdict.
# Returns 0 if the verdict is OK, non-zero if PROBLEM (so the exit status is
# meaningful to a caller/test, in addition to the logged line).
svc_selfcheck() {
	_sc_api="$(detect_api)"
	_sc_arch="$(detect_arch)"
	_sc_engine="$(detect_mount_engine)"
	_sc_mgr="$(detect_root_manager)"
	log_info "selfcheck: env api=$_sc_api arch=$_sc_arch engine=$_sc_engine root=$_sc_mgr"

	# Scan the overlay tree for expected microG package dirs across partitions.
	_sc_found=""
	if [ -d "$MODDIR/system" ]; then
		for _sc_name in $SVC_MICROG_DIRS; do
			for _sc_kind in priv-app app framework; do
				# A framework component is a jar, but its dir/marker still
				# lands under the partition; checking all three kinds keeps
				# this presence-check type-agnostic.
				for _sc_partdir in "$MODDIR"/system/*; do
					[ -d "$_sc_partdir/$_sc_kind/$_sc_name" ] || continue
					_sc_found="$_sc_found $_sc_name"
					break
				done
				case " $_sc_found " in *" $_sc_name "*) break ;; esac
			done
		done
	fi
	# Trim leading space for a tidy log line.
	_sc_found="${_sc_found# }"

	if [ -n "$_sc_found" ]; then
		log_info "selfcheck: microG packages present in overlay: $_sc_found"
		log_info "selfcheck: verdict OK"
		unset _sc_api _sc_arch _sc_engine _sc_mgr _sc_found _sc_name _sc_kind _sc_partdir
		return 0
	fi

	log_error "selfcheck: no microG packages found in overlay tree"
	log_error "selfcheck: verdict PROBLEM"
	unset _sc_api _sc_arch _sc_engine _sc_mgr _sc_found _sc_name _sc_kind _sc_partdir
	return 1
}

# main -- gate on boot, then run the self-check. Sourcing this file for tests
# (SVC_NO_MAIN set) skips main so individual functions can be exercised.
svc_main() {
	log_init
	log_info "service: waiting for sys.boot_completed (bounded: ${SVC_BOOT_MAX_TRIES}x${SVC_BOOT_SLEEP}s)"
	if svc_wait_boot; then
		log_info "service: boot completed; running self-check"
	else
		log_warn "service: boot-wait cap reached without sys.boot_completed=1; running self-check anyway"
	fi
	svc_selfcheck
}

if [ -z "${SVC_NO_MAIN:-}" ]; then
	svc_main
fi
