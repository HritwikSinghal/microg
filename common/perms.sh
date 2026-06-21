# shellcheck shell=sh
#
# common/perms.sh -- on-device permission-XML SELECTION, VALIDATION and
# PLACEMENT (spec 6.1 / the Phase 1+2 contract). This is the Permissions
# logical unit and it is deliberately narrow:
#
#   SELECT a pre-generated XML  ->  VALIDATE it  ->  PLACE it under the overlay.
#
# It NEVER generates XML. The privapp-permissions allowlists are the
# bootloop cure and are computed at BUILD time by lib/genperms.py (an
# under-listed allowlist boot-loops a stock device under enforce mode), gated
# by a CI invariant. On the device we only choose the right pre-built file,
# sanity-check that it parses, and copy it into "$MODPATH/system/...". Keeping
# generation off-device is what makes the cure trustworthy -- do not weaken it.
#
# Coordination model (contract "who resolves what"): customize.sh resolves the
# partition ONCE per component via place_resolve_partition and passes the
# already-resolved <part> in here, so the app and its permission XML always
# land in the same partition. perms.sh does NOT resolve partitions.
#
# Target paths under "$MODPATH/system" (contract "placement layout"):
#   privapp / framework permission XML:
#       "$MODPATH/system/<part>/etc/permissions/<basename>"
#   sysconfig XML:
#       "$MODPATH/system/<part>/etc/sysconfig/sysconfig-microg.xml"
#
# Reuses log_* from common/log.sh (assumed already sourced + log_init called).
# Sourced library: no `set -e` at file scope (it must not abort the installer).

# One-shot guard so the "xmllint missing, degrading" warning is logged at most
# once per install instead of on every component. Reset only by re-sourcing.
_PERMS_XMLLINT_WARNED=""

# ---------------------------------------------------------------------------
# Selection.
# ---------------------------------------------------------------------------

# perms_select PERMS_REF API
# PERMS_REF is the components.conf perms column, e.g. "perms/gmscore.xml" (the
# filename is already lowercased by the build). API is the device API level.
#
# Echo the in-ZIP source path of the chosen XML (a path under "$MODPATH"), or
# the empty string if nothing suitable exists (the caller logs + treats empty
# as failure). Returns 0.
#
# Per-API variants: Phase 1 ships a single base file, but the selection is
# designed so a future build can drop "perms/<base>-<API>.xml" beside the base
# and have it preferred automatically -- no on-device code change. We derive
# the variant name by inserting "-<API>" before the ".xml" suffix, so
# "perms/gmscore.xml" + API 34 -> "perms/gmscore-34.xml". If that variant file
# exists it wins; otherwise we fall back to the base file.
perms_select() {
	_ps_ref="$1"
	_ps_api="$2"

	# Empty reference is a programming/data error; nothing to select.
	if [ -z "$_ps_ref" ]; then
		printf '%s' ""
		unset _ps_ref _ps_api
		return 0
	fi

	# Build the per-API variant reference by inserting "-<API>" before ".xml".
	# Only attempt this when we have a usable (non-zero) numeric API and the
	# reference actually ends in ".xml"; otherwise just use the base.
	_ps_variant=""
	case "$_ps_api" in
	'' | 0 | *[!0-9]*)
		# No usable API level -- skip variant probing, use the base.
		;;
	*)
		case "$_ps_ref" in
		*.xml)
			# Strip the trailing ".xml" (4 chars) and re-append "-<API>.xml".
			_ps_base="${_ps_ref%.xml}"
			_ps_variant="${_ps_base}-${_ps_api}.xml"
			;;
		esac
		;;
	esac

	# Prefer the API-specific variant when present.
	if [ -n "$_ps_variant" ] && [ -f "$MODPATH/$_ps_variant" ]; then
		printf '%s' "$MODPATH/$_ps_variant"
		unset _ps_ref _ps_api _ps_variant _ps_base
		return 0
	fi

	# Fall back to the base file when it exists.
	if [ -f "$MODPATH/$_ps_ref" ]; then
		printf '%s' "$MODPATH/$_ps_ref"
		unset _ps_ref _ps_api _ps_variant _ps_base
		return 0
	fi

	# Nothing found -- echo empty; caller logs and fails the component.
	printf '%s' ""
	unset _ps_ref _ps_api _ps_variant _ps_base
	return 0
}

# ---------------------------------------------------------------------------
# Validation.
# ---------------------------------------------------------------------------

# perms_validate FILE
# Return 0 if FILE is well-formed XML. Uses `xmllint --noout` when available.
# When xmllint is ABSENT (the typical on-device case -- toybox ships no
# xmllint) we DEGRADE: warn once and accept (return 0) rather than failing the
# install over a missing validator. The build-time pipeline already validated
# every emitted file with xmllint and the CI invariant, so on-device
# validation is a best-effort second line of defence, never a hard gate.
#
# Returns non-zero ONLY when xmllint IS available and reports the file invalid
# (or the file is missing).
perms_validate() {
	_pv_file="$1"

	# A non-existent file can never be valid; this is a real failure regardless
	# of whether a validator is present.
	if [ ! -f "$_pv_file" ]; then
		log_error "perms_validate: file not found: $_pv_file"
		unset _pv_file
		return 1
	fi

	if command -v xmllint >/dev/null 2>&1; then
		if xmllint --noout "$_pv_file" 2>/dev/null; then
			unset _pv_file
			return 0
		fi
		log_error "perms_validate: xmllint rejected $_pv_file"
		unset _pv_file
		return 1
	fi

	# xmllint absent: degrade gracefully. Warn at most once per install.
	if [ -z "$_PERMS_XMLLINT_WARNED" ]; then
		log_warn "perms_validate: xmllint not available; skipping XML validation (build-time validation + CI invariant already cover this)"
		_PERMS_XMLLINT_WARNED="1"
	fi
	unset _pv_file
	return 0
}

# ---------------------------------------------------------------------------
# Placement (internal helper).
# ---------------------------------------------------------------------------

# _perms_place_xml NAME PERMS_REF PART API DEST_DIR_LABEL
# Shared select+validate+copy into "$MODPATH/system/$PART/etc/permissions/".
# Both app and framework permission files live in etc/permissions, so app and
# framework placement differ only in their log label. NAME is purely for the
# log line. Returns 0 on success; non-zero when no file is selected or it fails
# validation.
_perms_place_xml() {
	_pp_name="$1"
	_pp_ref="$2"
	_pp_part="$3"
	_pp_api="$4"
	_pp_label="$5"

	_pp_src="$(perms_select "$_pp_ref" "$_pp_api")"
	if [ -z "$_pp_src" ]; then
		log_error "perms: no permission XML found for $_pp_name (ref=$_pp_ref, api=$_pp_api)"
		unset _pp_name _pp_ref _pp_part _pp_api _pp_label _pp_src
		return 1
	fi

	if ! perms_validate "$_pp_src"; then
		log_error "perms: permission XML invalid for $_pp_name: $_pp_src"
		unset _pp_name _pp_ref _pp_part _pp_api _pp_label _pp_src
		return 1
	fi

	_pp_dir="$MODPATH/system/$_pp_part/etc/permissions"
	_pp_dest="$_pp_dir/$(basename "$_pp_src")"

	if ! mkdir -p "$_pp_dir" 2>/dev/null; then
		log_error "perms: cannot create $_pp_dir for $_pp_name"
		unset _pp_name _pp_ref _pp_part _pp_api _pp_label _pp_src _pp_dir _pp_dest
		return 1
	fi

	# Idempotent overwrite: cp -f replaces any stale copy from a prior flash.
	if ! cp -f "$_pp_src" "$_pp_dest" 2>/dev/null; then
		log_error "perms: failed to copy $_pp_src -> $_pp_dest"
		unset _pp_name _pp_ref _pp_part _pp_api _pp_label _pp_src _pp_dir _pp_dest
		return 1
	fi

	log_info "perms: placed $_pp_label permissions for $_pp_name -> $_pp_dest"
	unset _pp_name _pp_ref _pp_part _pp_api _pp_label _pp_src _pp_dir _pp_dest
	return 0
}

# ---------------------------------------------------------------------------
# Public placement API.
# ---------------------------------------------------------------------------

# perms_place_app NAME PERMS_REF PART API
# Select, validate and place a privapp-permissions allowlist for an app
# component into "$MODPATH/system/$PART/etc/permissions/". Idempotent
# (overwrite). Returns 0 on success; non-zero if the XML is missing or invalid.
perms_place_app() {
	_perms_place_xml "$1" "$2" "$3" "$4" "app"
}

# perms_place_framework NAME PERMS_REF PART API   (Phase 2)
# A framework <library> permission file lives in the SAME etc/permissions dir
# as app allowlists, so placement is identical to perms_place_app aside from
# the log label. Kept as a distinct entry point so customize.sh can dispatch on
# the component `type` and so a future framework-specific rule can diverge here
# without touching the app path.
perms_place_framework() {
	_perms_place_xml "$1" "$2" "$3" "$4" "framework"
}

# perms_place_sysconfig PART
# Copy the SEPARATE behavioral-exemptions file
# "$MODPATH/perms/sysconfig-microg.xml" -> "$MODPATH/system/$PART/etc/sysconfig/".
# Called ONCE by customize.sh (not per row). Idempotent. No-op + return 0 when
# the source is absent (a build may legitimately ship no exemptions).
perms_place_sysconfig() {
	_pc_part="$1"
	_pc_src="$MODPATH/perms/sysconfig-microg.xml"

	if [ ! -f "$_pc_src" ]; then
		log_info "perms: no sysconfig-microg.xml to place (skipping)"
		unset _pc_part _pc_src
		return 0
	fi

	# Best-effort validation; degrades when xmllint is absent (see
	# perms_validate). A genuinely malformed sysconfig is a real failure.
	if ! perms_validate "$_pc_src"; then
		log_error "perms: sysconfig-microg.xml invalid: $_pc_src"
		unset _pc_part _pc_src
		return 1
	fi

	_pc_dir="$MODPATH/system/$_pc_part/etc/sysconfig"
	_pc_dest="$_pc_dir/sysconfig-microg.xml"

	if ! mkdir -p "$_pc_dir" 2>/dev/null; then
		log_error "perms: cannot create $_pc_dir"
		unset _pc_part _pc_src _pc_dir _pc_dest
		return 1
	fi

	if ! cp -f "$_pc_src" "$_pc_dest" 2>/dev/null; then
		log_error "perms: failed to copy $_pc_src -> $_pc_dest"
		unset _pc_part _pc_src _pc_dir _pc_dest
		return 1
	fi

	log_info "perms: placed sysconfig exemptions -> $_pc_dest"
	unset _pc_part _pc_src _pc_dir _pc_dest
	return 0
}
