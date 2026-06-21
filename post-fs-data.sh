#!/system/bin/sh
#
# post-fs-data.sh -- EARLY-boot stock-GMS removal (spec 5.3, 7).
#
# Runs in the post-fs-data stage, which executes BEFORE /data is decrypted on
# File-Based-Encryption (FBE) devices. The hard constraint from the edge-case
# checklist: this stage must NEVER touch /data/data -- it is not yet available
# and reading/writing it here either fails or corrupts user state. All this
# script does is ensure the declarative REPLACE sentinels that mask stock
# GMS/Play directories are present in the module overlay, which is the removal
# work that has to be in place before the system is mounted for real boot.
#
# The sentinels are normally written at install time by customize.sh. Re-laying
# them here makes removal robust across the early-boot window (and across a
# partial install) without doing any partition writes: everything lands under
# "$MODDIR/system", exactly like the installer.
#
# MODDIR is this script's own directory (Magisk passes the module path as the
# script location). POSIX sh, no bashisms, no `set -e`.

# On device Magisk invokes this script directly, so its own path ("${0%/*}")
# is the module dir. A pre-set MODDIR wins (host tests / sourcing).
: "${MODDIR:=${0%/*}}"

# Log to the same selfcheck.log the installer and service.sh use.
# shellcheck source=/dev/null
. "$MODDIR/common/log.sh"
# detect.sh gives us the mount engine so the log records which engine was live
# at early boot; the REPLACE mechanism itself is engine-portable.
# shellcheck source=/dev/null
. "$MODDIR/common/detect.sh"
# shellcheck source=/dev/null
. "$MODDIR/common/cleanup.sh"

log_init
log_info "post-fs-data: early-boot stock-GMS masking (FBE-safe; /data/data untouched)"

# Engine is detected, never inferred from the root manager (spec 5.3).
engine="$(detect_mount_engine)"

# Mask stock GMS/Play across every partition the module overlay actually
# targets. We read the partition manifest customize.sh wrote
# ("$MODDIR/.microg-partitions", one RESOLVED partition name per line) rather
# than globbing "$MODDIR/system/*". The glob is WRONG for the default bare-
# `system` layout: there the children of system/ are component subdirs
# (priv-app, etc, framework), not partition names, so globbing would spray
# bogus sentinels into nonsense paths (system/priv-app/priv-app/...) and never
# mask the real stock GMS. The manifest is the single source of truth and maps
# 1:1 to the overlay path cleanup_stock_gms writes ("$MODDIR/system/<part>/...").
masked_any=0
parts_file="$MODDIR/.microg-partitions"
if [ -f "$parts_file" ]; then
	# `|| [ -n "$part" ]` handles a final line with no trailing newline.
	while IFS= read -r part || [ -n "$part" ]; do
		# Skip blank lines defensively (a truncated write must never expand to an
		# empty partition, which cleanup_stock_gms treats as a no-op anyway).
		[ -z "$part" ] && continue
		cleanup_stock_gms "$part" "$engine"
		masked_any=1
	done <"$parts_file"
fi

# Fallback: no manifest (e.g. a partial/old install that predates it). Mask the
# default `system` partition so stock GMS removal still happens rather than
# silently doing nothing. This matches the manifest's default primary partition.
if [ "$masked_any" = "0" ]; then
	log_warn "post-fs-data: no partition manifest at $parts_file; falling back to 'system'"
	cleanup_stock_gms "system" "$engine"
fi

log_info "post-fs-data: done"
