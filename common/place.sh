# shellcheck shell=sh
#
# common/place.sh -- the ModuleOverlayPlacer (spec 5.2 placement unit).
#
# This unit copies pre-staged assets (APKs, framework jars) from inside the
# flashable ZIP ("$MODPATH/<asset>") into the systemless module overlay tree
# under "$MODPATH/system/<part>/...". It NEVER writes to a real partition: the
# mount engine (OverlayFS / magic-mount) is what later projects "$MODPATH/system"
# over the live system. All this code does is arrange files under $MODPATH.
#
# Dependencies (assumed already in scope; do NOT source them here):
#   - log_* from common/log.sh        (log_init done by customize.sh)
#   - detect_partitions from common/detect.sh
# customize.sh sources every library before sourcing this one; the BATS setup()
# for place.bats sources log.sh + detect.sh + place.sh in that order.
#
# Coordination model (see claude/phase1-2-contracts.md): customize.sh is the ONLY
# coordinator. It resolves the partition ONCE per component via
# place_resolve_partition and passes the RESOLVED <part> to both place_* and
# perms_*. The place_* functions therefore do NOT resolve partitions themselves.
#
# ---------------------------------------------------------------------------
# Placer seam (Phase 3 extension point)
# ---------------------------------------------------------------------------
# Phase 1/2 ship the ModuleOverlayPlacer: every destination is rooted at
# "$MODPATH/system/<part>" so the root manager mounts it systemlessly. A future
# Phase 3 DirectPartitionPlacer (writing straight to a real, remounted-rw
# partition) can slot in by overriding the single seam below -- the public
# place_app / place_framework / place_remove API and their call sites stay
# unchanged. Keep the destination-root computation funnelled through
# _place_overlay_root so the alternate Placer only has to replace that one
# function (e.g. echo "/$PART" instead of "$MODPATH/system/$PART").
#
# _place_overlay_root PART
#   Echo the absolute base directory that "<part>"'s tree is rooted at. The
#   ModuleOverlayPlacer roots everything under the module's system overlay.
_place_overlay_root() {
	printf '%s' "$MODPATH/system/$1"
}

# ---------------------------------------------------------------------------
# place_resolve_partition DECLARED
# ---------------------------------------------------------------------------
# Echo the partition customize.sh should actually use for a component whose
# components.conf row DECLARES partition DECLARED (e.g. "product"). Prefer
# DECLARED when it appears in the live "$(detect_partitions)" set; otherwise
# echo DECLARED unchanged but emit a single log_warn that the declared
# partition was not detected (the overlay still creates the dir, so placement
# is best-effort rather than fatal). Pure: echoes the choice, returns 0.
#
# Whole-word match against the space-separated partition list so a declared
# "system" does not spuriously match "system_ext".
place_resolve_partition() {
	_prp_declared="$1"
	_prp_parts="$(detect_partitions)"

	for _prp_have in $_prp_parts; do
		if [ "$_prp_have" = "$_prp_declared" ]; then
			printf '%s' "$_prp_declared"
			unset _prp_declared _prp_parts _prp_have
			return 0
		fi
	done

	# Declared partition not among the detected set: warn once, fall back to
	# the declared name so the overlay dir is still created where the manifest
	# expects it.
	log_warn "declared partition '$_prp_declared' not detected (have: ${_prp_parts:-none}); using it anyway"
	printf '%s' "$_prp_declared"
	unset _prp_declared _prp_parts _prp_have
	return 0
}

# ---------------------------------------------------------------------------
# place_app NAME ASSET PART
# ---------------------------------------------------------------------------
# Copy "$MODPATH/$ASSET" -> "<root>/priv-app/$NAME/$NAME.apk" where <root> is
# _place_overlay_root PART. Creates parent dirs. Idempotent on re-flash: any
# stale "$NAME" priv-app dir is removed first, then placed fresh, so a re-flash
# replaces rather than merges or duplicates. log_info what was placed.
# Returns 0 on success; log_error + non-zero if "$MODPATH/$ASSET" is missing.
place_app() {
	_pa_name="$1"
	_pa_asset="$2"
	_pa_part="$3"
	_pa_src="$MODPATH/$_pa_asset"

	if [ ! -f "$_pa_src" ]; then
		log_error "place_app: asset not found for '$_pa_name': $_pa_src"
		unset _pa_name _pa_asset _pa_part _pa_src
		return 1
	fi

	_pa_dir="$(_place_overlay_root "$_pa_part")/priv-app/$_pa_name"
	_pa_dest="$_pa_dir/$_pa_name.apk"

	# Replace, never merge: drop any prior copy of this app dir before staging.
	rm -rf "$_pa_dir"
	if ! mkdir -p "$_pa_dir"; then
		log_error "place_app: could not create dir for '$_pa_name': $_pa_dir"
		unset _pa_name _pa_asset _pa_part _pa_src _pa_dir _pa_dest
		return 1
	fi

	if ! cp "$_pa_src" "$_pa_dest"; then
		log_error "place_app: copy failed for '$_pa_name': $_pa_src -> $_pa_dest"
		unset _pa_name _pa_asset _pa_part _pa_src _pa_dir _pa_dest
		return 1
	fi

	log_info "place_app: placed '$_pa_name' at $_pa_dest"
	unset _pa_name _pa_asset _pa_part _pa_src _pa_dir _pa_dest
	return 0
}

# ---------------------------------------------------------------------------
# place_framework NAME ASSET PART     (Phase 2 path -- implemented now)
# ---------------------------------------------------------------------------
# Copy "$MODPATH/$ASSET" -> "<root>/framework/$(basename ASSET)". Creates parent
# dirs. Idempotent: the single destination file is overwritten in place (a
# framework jar is one file, not a per-name dir, so there is no stale dir to
# purge). Returns 0 on success; log_error + non-zero if the asset is missing.
place_framework() {
	_pf_name="$1"
	_pf_asset="$2"
	_pf_part="$3"
	_pf_src="$MODPATH/$_pf_asset"

	if [ ! -f "$_pf_src" ]; then
		log_error "place_framework: asset not found for '$_pf_name': $_pf_src"
		unset _pf_name _pf_asset _pf_part _pf_src
		return 1
	fi

	_pf_base="$(basename "$_pf_asset")"
	_pf_dir="$(_place_overlay_root "$_pf_part")/framework"
	_pf_dest="$_pf_dir/$_pf_base"

	if ! mkdir -p "$_pf_dir"; then
		log_error "place_framework: could not create dir for '$_pf_name': $_pf_dir"
		unset _pf_name _pf_asset _pf_part _pf_src _pf_base _pf_dir _pf_dest
		return 1
	fi

	# Overwrite any prior copy so a re-flash replaces rather than appends.
	rm -f "$_pf_dest"
	if ! cp "$_pf_src" "$_pf_dest"; then
		log_error "place_framework: copy failed for '$_pf_name': $_pf_src -> $_pf_dest"
		unset _pf_name _pf_asset _pf_part _pf_src _pf_base _pf_dir _pf_dest
		return 1
	fi

	log_info "place_framework: placed '$_pf_name' at $_pf_dest"
	unset _pf_name _pf_asset _pf_part _pf_src _pf_base _pf_dir _pf_dest
	return 0
}

# ---------------------------------------------------------------------------
# place_remove NAME PART
# ---------------------------------------------------------------------------
# Remove a component's overlay footprint: its priv-app/<NAME> dir and, if the
# placer staged a framework jar named "<NAME>.jar", that jar too. Used by
# conflict resolution (the FakeStore<->Phonesky mutual exclusion) and by
# re-flash idempotence. Idempotent no-op when nothing is present. Always 0.
#
# NOTE: this removes ONLY the priv-app dir keyed by NAME and a same-named
# framework jar. A framework component whose asset basename differs from NAME
# (e.g. MapsV1 -> maps.jar) is not covered here by design -- conflicts in
# Phase 1/2 are between app variants (FakeStore/Phonesky), and the contract
# scopes place_remove to "$NAME" priv-app plus an optional framework copy.
place_remove() {
	_pr_name="$1"
	_pr_part="$2"
	_pr_root="$(_place_overlay_root "$_pr_part")"
	_pr_app_dir="$_pr_root/priv-app/$_pr_name"
	_pr_fw_jar="$_pr_root/framework/$_pr_name.jar"

	if [ -d "$_pr_app_dir" ]; then
		rm -rf "$_pr_app_dir"
		log_info "place_remove: removed priv-app for '$_pr_name' ($_pr_app_dir)"
	fi

	if [ -f "$_pr_fw_jar" ]; then
		rm -f "$_pr_fw_jar"
		log_info "place_remove: removed framework jar for '$_pr_name' ($_pr_fw_jar)"
	fi

	unset _pr_name _pr_part _pr_root _pr_app_dir _pr_fw_jar
	return 0
}
