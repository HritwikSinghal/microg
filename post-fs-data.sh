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
# targets, so we cover whatever partition customize.sh placed microG into. We
# look at the overlay tree under "$MODDIR/system" rather than the live system,
# keeping all work inside the module and off real partitions.
masked_any=0
if [ -d "$MODDIR/system" ]; then
	for partdir in "$MODDIR"/system/*; do
		[ -d "$partdir" ] || continue
		part="${partdir##*/}"
		cleanup_stock_gms "$part" "$engine"
		masked_any=1
	done
fi

if [ "$masked_any" = "0" ]; then
	log_warn "post-fs-data: no overlay partitions under $MODDIR/system; nothing to mask"
fi

log_info "post-fs-data: done"
