# shellcheck shell=sh
#
# common/cleanup.sh -- declarative StockGmsRemover (spec 5.3, 7).
#
# Removes stock Google Play / GMS apps from the read-only system image by
# masking their directories in the module overlay. This is the "real GMS
# present -> fully remove" path: microG cannot coexist with stock GMS, so the
# stock priv-app/app dirs must be made to disappear from the merged system view.
#
# Engine portability is the whole point of doing this declaratively. Whiteouts
# created with mknod (the classic magic-mount technique) can silently no-op
# under OverlayFS, and KSU/APatch may run either engine (detected, never
# inferred -- spec 5.3). The Magisk REPLACE sentinel is the portable removal:
# creating a directory under the module's system overlay that contains a file
# named ".replace" tells BOTH magic-mount and the Magisk OverlayFS
# implementation to present the corresponding system directory as empty
# (effectively deleted) in the merged view. So a single mechanism covers every
# supported engine; genuinely engine-specific early-boot work (none is needed
# for the sentinel) would live in post-fs-data.sh.
#
# This is a sourced library: it does NOT `set -e` at file scope and must not
# abort the caller. log_* are assumed in scope (customize.sh / post-fs-data.sh
# source log.sh first; the BATS setup() does the same).

# ---------------------------------------------------------------------------
# Declarative data: known stock GMS / Play Store directory names.
# ---------------------------------------------------------------------------
#
# These are the AOSP/GApps directory names the stock Google stack ships under
# priv-app and/or app across vendors and Android versions. The list is
# intentionally a superset: masking a dir that does not exist is a harmless
# no-op (we only create a sentinel when the masking is requested, and an
# absent stock dir simply has nothing to shadow). Overridable for tests and
# for a future data-driven manifest via $CLEANUP_STOCK_DIRS.
#
#   PrebuiltGmsCore / GmsCore / GmsCoreSc* -- Google Play services
#   GoogleServicesFramework               -- GSF
#   Phonesky / Vending                    -- Play Store
#   GooglePartnerSetup / GoogleLoginService / GoogleBackupTransport -- Play stack
: "${CLEANUP_STOCK_DIRS:=PrebuiltGmsCore GmsCore GmsCoreSc GoogleServicesFramework Phonesky Vending GooglePartnerSetup GoogleLoginService GoogleBackupTransport}"

# Subdirectories of a partition where stock apps live. A given stock app may be
# a priv-app on one device and an ordinary app on another, so we mask both.
: "${CLEANUP_APP_KINDS:=priv-app app}"

# ---------------------------------------------------------------------------
# Internal helper.
# ---------------------------------------------------------------------------

# _cleanup_replace_dir DIR
# Create the overlay directory DIR containing a single ".replace" sentinel
# file, which makes the mount engine present the matching system directory as
# empty. Idempotent: re-creating an existing sentinel is a no-op. Echoes
# nothing; returns 0 on success, non-zero only if the sentinel cannot be
# written (a real-device failure the caller logs).
_cleanup_replace_dir() {
	_cr_dir="$1"
	if [ ! -d "$_cr_dir" ]; then
		mkdir -p "$_cr_dir" 2>/dev/null || {
			unset _cr_dir
			return 1
		}
	fi
	# The sentinel file's content is irrelevant; only its presence matters.
	if [ ! -f "$_cr_dir/.replace" ]; then
		: >"$_cr_dir/.replace" 2>/dev/null || {
			unset _cr_dir
			return 1
		}
	fi
	unset _cr_dir
	return 0
}

# ---------------------------------------------------------------------------
# Public API.
# ---------------------------------------------------------------------------

# cleanup_stock_gms PART ENGINE
#   PART   -- the resolved partition (e.g. product, system, system_ext).
#   ENGINE -- "$(detect_mount_engine)": overlayfs | magic-mount | unknown.
#
# For every known stock dir under every app kind, drop a REPLACE sentinel at
#   "$MODPATH/system/$PART/<kind>/<StockDir>/.replace"
# so the stock GMS/Play directory is masked in the merged system view. The same
# sentinel is the portable removal for every engine, so ENGINE is informational
# here (logged for traceability); it does NOT change the mechanism. Idempotent
# and safe to re-run on upgrade. Returns 0 even when some sentinels fail to
# write (each failure is logged) so one bad path never aborts the install.
cleanup_stock_gms() {
	_cg_part="$1"
	_cg_engine="$2"

	if [ -z "$_cg_part" ]; then
		log_error "cleanup_stock_gms: empty partition, nothing to clean"
		unset _cg_part _cg_engine
		return 0
	fi

	log_info "cleanup_stock_gms: masking stock GMS/Play in '$_cg_part' (engine=${_cg_engine:-unknown}, REPLACE sentinel)"

	_cg_base="$MODPATH/system/$_cg_part"
	for _cg_kind in $CLEANUP_APP_KINDS; do
		for _cg_name in $CLEANUP_STOCK_DIRS; do
			_cg_target="$_cg_base/$_cg_kind/$_cg_name"
			# Skip work already done so re-runs stay quiet and idempotent.
			if [ -f "$_cg_target/.replace" ]; then
				continue
			fi
			if _cleanup_replace_dir "$_cg_target"; then
				log_info "cleanup_stock_gms: REPLACE $_cg_kind/$_cg_name"
			else
				log_warn "cleanup_stock_gms: could not write REPLACE for $_cg_kind/$_cg_name"
			fi
		done
	done

	unset _cg_part _cg_engine _cg_base _cg_kind _cg_name _cg_target
	return 0
}
