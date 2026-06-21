#!/system/bin/sh
# shellcheck shell=sh
#
#################################################################
# microG Universal Installer -- customize.sh (generic interpreter)
#
# Magisk convention: this script is SOURCED by module_installer.sh
# (itself sourced by META-INF/.../update-binary) AFTER the module
# files have been extracted to $MODPATH. The root manager exports
# the install environment we rely on, notably:
#   MODPATH    : the module's staging dir under /data/adb/...
#   API        : device API level
#   ARCH / ABI : CPU architecture
#   IS64BIT    : true on 64-bit
#   BOOTMODE   : true when flashed from the manager app
#   KSU / APATCH (when set) : non-Magisk root manager markers
#
# ROLE: this is the generic, DATA-DRIVEN interpreter over
# components.conf (spec sections 5.4 and 10). It does NOT itself
# know any component names. It:
#   1. sources the helper libraries (log, detect, place, perms, cleanup)
#   2. probes the device environment and logs a banner
#   3. places the behavioural sysconfig XML once
#   4. iterates each non-comment, non-blank row of components.conf,
#      resolving the partition, purging declared conflicts, then
#      dispatching on the row's `type` to the place_* / perms_* pair
#   5. removes a real (stock) GMS install via the declarative remover
#
# It stays a THIN interpreter: adding or swapping a component is a
# components.conf data change, not a code change here. The real
# placement/permission/cleanup behaviour lives in the sourced libs.
#
# Because this file is SOURCED, a bare `exit` would terminate the
# whole installer. We therefore only `exit 1` on a truly fatal setup
# error (missing MODPATH, missing libraries, missing components.conf);
# per-component failures are isolated (logged, counted, skipped) and
# never abort the run.
#
# IMPORTANT: module mode never writes real partitions. Everything is
# staged under $MODPATH (on writable /data); the "partition" column in
# components.conf is only a path prefix inside the overlay.
#################################################################

# ---------------------------------------------------------------------------
# Fatal setup checks. These run before logging is available, so they must
# report via ui_print (if defined) / stderr and `exit 1` -- a missing module
# root or library means nothing downstream can work.
# ---------------------------------------------------------------------------

# MODDIR is the module staging root. ${MODPATH:?} aborts (in a sourced context
# this still propagates a non-zero status) if MODPATH is unset/empty.
MODDIR="${MODPATH:?MODPATH must be set by the installer environment}"

# _fatal MESSAGE: emit before log_init is available, then exit the installer.
# Used only for unrecoverable setup errors.
_fatal() {
	if command -v ui_print >/dev/null 2>&1; then
		ui_print "! microG installer: $*"
	else
		printf '%s\n' "microG installer: $*" >&2
	fi
	exit 1
}

# Source the helper libraries. Each is mandatory; a missing one is fatal.
for _lib in log detect place perms cleanup; do
	if [ ! -r "$MODDIR/common/$_lib.sh" ]; then
		_fatal "missing required library common/$_lib.sh"
	fi
	# shellcheck source=/dev/null
	. "$MODDIR/common/$_lib.sh"
done
unset _lib

# Logging is now available for everything below.
log_init

# The component table is mandatory; without it there is nothing to install.
COMPONENTS_CONF="$MODDIR/components.conf"
if [ ! -r "$COMPONENTS_CONF" ]; then
	log_error "components.conf not found at $COMPONENTS_CONF -- nothing to install"
	exit 1
fi

# ---------------------------------------------------------------------------
# Environment probe + banner.
#
# API is exported by the installer; fall back to detect_api when absent (host
# runs, or a root manager that does not export it). detect.sh probes echo their
# result, so they are captured here once and reused.
# ---------------------------------------------------------------------------

DEV_API="${API:-$(detect_api)}"
case "$DEV_API" in
'' | *[!0-9]*) DEV_API=0 ;;
esac
DEV_ARCH="$(detect_arch)"
DEV_ENGINE="$(detect_mount_engine)"
DEV_ROOTMGR="$(detect_root_manager)"
DEV_PARTS="$(detect_partitions)"

log_info "microG Universal Installer -- placing components"
log_info "env: api=$DEV_API arch=$DEV_ARCH engine=$DEV_ENGINE root=$DEV_ROOTMGR"
log_info "partitions detected: ${DEV_PARTS:-<none>}"

# Edge case (spec 7): API < 26 predates the privileged-permission allowlist
# mechanism. The XML is harmless there (ignored), so we proceed and just note
# it once for the self-check log.
if [ "$DEV_API" -gt 0 ] && [ "$DEV_API" -lt 26 ]; then
	log_warn "device API $DEV_API < 26: privileged-permission XML is harmless but inert; proceeding"
fi

# Track per-component problems without aborting. A non-zero count is surfaced
# at the end and by the boot-time self-check (service.sh).
PROBLEMS=0

# ---------------------------------------------------------------------------
# Behavioural sysconfig XML -- placed ONCE, not per row.
#
# It belongs in the primary partition. We resolve the partition declared on the
# first data row of components.conf (the partition all components share in
# practice); if the table has no data rows we fall back to "system". Using
# place_resolve_partition keeps the sysconfig in the same partition the
# components land in.
# ---------------------------------------------------------------------------

# _first_declared_partition: echo the partition column of the first
# non-comment, non-blank components.conf row, or empty if there is none.
_first_declared_partition() {
	while IFS= read -r _l || [ -n "$_l" ]; do
		case "$_l" in
		'' | '#'*) continue ;;
		esac
		# shellcheck disable=SC2086
		# Intentional word-splitting: read the 4th whitespace-delimited field.
		set -- $_l
		if [ "$#" -ge 4 ]; then
			printf '%s' "$4"
		fi
		return 0
	done <"$COMPONENTS_CONF"
	return 0
}

_primary_declared="$(_first_declared_partition)"
[ -n "$_primary_declared" ] || _primary_declared="system"
PRIMARY_PART="$(place_resolve_partition "$_primary_declared")"
unset _primary_declared

perms_place_sysconfig "$PRIMARY_PART" ||
	{ log_error "sysconfig placement failed"; PROBLEMS=$((PROBLEMS + 1)); }

# ---------------------------------------------------------------------------
# Resolved-partition manifest for early-boot masking.
#
# post-fs-data.sh must mask stock GMS in exactly the partition(s) this install
# placed microG into. It cannot reliably DERIVE those by globbing
# "$MODDIR/system/*": for the default bare-`system` layout the children of
# system/ are priv-app/etc/framework (component subdirs), NOT partition names,
# so a glob would invent bogus partitions. Instead we record every RESOLVED
# partition here (the same value place_resolve_partition returns and that
# _place_overlay_root roots the overlay at) into a small newline-delimited file,
# deduped, and post-fs-data.sh iterates that. The path stays in lockstep with
# the overlay: partition P maps to "$MODDIR/system/P/...".
# ---------------------------------------------------------------------------

MICROG_PARTS_FILE="$MODDIR/.microg-partitions"
# Start fresh each install so a stale partition from a prior flash cannot
# linger and cause masking in a partition we no longer use. Truncate is
# best-effort; a failure only degrades post-fs-data to its "system" fallback.
: >"$MICROG_PARTS_FILE" 2>/dev/null || log_warn "could not create $MICROG_PARTS_FILE; early-boot masking will fall back to 'system'"

# _record_partition PART: append PART to the manifest unless already present.
# Deduped so repeated components in one partition yield a single line. Empty
# input is ignored (a blank partition is never a real overlay target).
_record_partition() {
	_rp_part="$1"
	[ -z "$_rp_part" ] && { unset _rp_part; return 0; }
	[ -f "$MICROG_PARTS_FILE" ] || { unset _rp_part; return 0; }
	# Whole-line match so "system" does not suppress "system_ext".
	if ! grep -qxF "$_rp_part" "$MICROG_PARTS_FILE" 2>/dev/null; then
		printf '%s\n' "$_rp_part" >>"$MICROG_PARTS_FILE" 2>/dev/null ||
			log_warn "could not record partition '$_rp_part' to $MICROG_PARTS_FILE"
	fi
	unset _rp_part
}

# The sysconfig (and stock-GMS cleanup below) live in the primary partition, so
# it must be masked too even if no component row resolves to it.
_record_partition "$PRIMARY_PART"

# ---------------------------------------------------------------------------
# Conflict purge helper.
#
# For each comma-separated component name in a row's `conflicts` column (the
# literal "-" means none), remove that component from the overlay across BOTH
# place and perms so switching variants on re-flash is clean and atomic. This
# is the FakeStore <-> Phonesky mutual exclusion: placing one purges the other.
#
# We do not know the conflicting component's perms basename (it is not in this
# row), so we clear ITS permission XML by the lowercased-name convention
# documented in the contract: perms/<name.lower()>.xml -> the placed file is
# system/<part>/etc/permissions/<name.lower()>.xml.
# ---------------------------------------------------------------------------

# _purge_conflicts CONFLICTS PART: purge every conflicting component name.
_purge_conflicts() {
	_pc_conflicts="$1"
	_pc_part="$2"
	[ -z "$_pc_conflicts" ] && return 0
	[ "$_pc_conflicts" = "-" ] && return 0

	# Split on commas. Save/restore IFS rather than running in a subshell so
	# place_remove's logging and side effects happen in the caller's context.
	_pc_oldifs="$IFS"
	IFS=','
	for _pc_name in $_pc_conflicts; do
		IFS="$_pc_oldifs"
		[ -z "$_pc_name" ] && continue
		[ "$_pc_name" = "-" ] && continue
		log_info "conflict purge: removing $_pc_name from $_pc_part"
		# Remove the app/framework payload.
		place_remove "$_pc_name" "$_pc_part" ||
			log_warn "conflict purge: place_remove $_pc_name failed (continuing)"
		# Remove its permission XML (lowercased-name convention). perms.sh names
		# the placed file from the perms-ref basename stem, optionally with an
		# "-<API>" suffix (e.g. phonesky.xml AND phonesky-34.xml). On a
		# variant<->variant reflash (FakeStore<->Phonesky) the conflicting
		# component may have landed as EITHER the base or an API variant, so we
		# must purge both the base and every "<stem>-*.xml" variant -- removing
		# only the base would leave a stale phonesky-34.xml allowlist coexisting
		# with the newly placed component's allowlist.
		_pc_lower="$(printf '%s' "$_pc_name" | tr '[:upper:]' '[:lower:]')"
		_pc_permdir="$MODDIR/system/$_pc_part/etc/permissions"
		# Guard: never let an empty stem/part expand the glob to the whole
		# permissions dir (or a parent) -- a blank conflict name must be a no-op,
		# not an `rm` of unrelated allowlists.
		if [ -n "$_pc_lower" ] && [ -n "$_pc_part" ] && [ -d "$_pc_permdir" ]; then
			# Base file plus "-<API>" variants. The for-loop over a glob is the
			# POSIX-safe way to handle "no match" (the literal pattern is then
			# simply skipped by the -e test) without nullglob.
			for _pc_xml in "$_pc_permdir/$_pc_lower.xml" "$_pc_permdir/$_pc_lower"-*.xml; do
				[ -e "$_pc_xml" ] || continue
				rm -f "$_pc_xml" 2>/dev/null ||
					log_warn "conflict purge: could not remove $_pc_xml"
			done
		fi
		unset _pc_lower _pc_permdir _pc_xml
		IFS=','
	done
	IFS="$_pc_oldifs"

	unset _pc_conflicts _pc_part _pc_oldifs _pc_name _pc_lower _pc_permdir _pc_xml
	return 0
}

# ---------------------------------------------------------------------------
# Main loop: interpret components.conf row by row.
#
# Reading via `while read` keeps memory flat and naturally splits fields. The
# `|| [ -n "$line" ]` tail handles a final line with no trailing newline.
# ---------------------------------------------------------------------------

while IFS= read -r line || [ -n "$line" ]; do
	# Skip blank lines and comments.
	case "$line" in
	'' | '#'*) continue ;;
	esac

	# Parse the 7 fixed columns: name pkg asset partition type perms conflicts.
	# Intentional word-splitting of the whitespace-delimited row.
	# shellcheck disable=SC2086
	set -- $line
	if [ "$#" -lt 7 ]; then
		log_error "malformed components.conf row (expected 7 fields, got $#): $line"
		PROBLEMS=$((PROBLEMS + 1))
		continue
	fi
	name="$1"
	# pkg ($2) is informational here; the libraries key off name/asset/perms.
	asset="$3"
	declared_part="$4"
	ctype="$5"
	perms="$6"
	conflicts="$7"

	# Resolve the partition ONCE and pass the resolved value to both place_*
	# and perms_* so the payload and its permission XML share a partition.
	part="$(place_resolve_partition "$declared_part")"

	# Record it for early-boot masking (post-fs-data reads this manifest).
	_record_partition "$part"

	# Purge declared conflicts before placing this component (atomic swap).
	_purge_conflicts "$conflicts" "$part"

	# Dispatch on type. A single component's failure is isolated: log_error,
	# count a PROBLEM, and continue to the next row.
	case "$ctype" in
	app)
		if place_app "$name" "$asset" "$part" &&
			perms_place_app "$name" "$perms" "$part" "$DEV_API"; then
			log_info "placed app $name in $part"
		else
			log_error "failed to place app component $name (asset=$asset)"
			PROBLEMS=$((PROBLEMS + 1))
		fi
		;;
	framework)
		if place_framework "$name" "$asset" "$part" &&
			perms_place_framework "$name" "$perms" "$part" "$DEV_API"; then
			log_info "placed framework $name in $part"
		else
			log_error "failed to place framework component $name (asset=$asset)"
			PROBLEMS=$((PROBLEMS + 1))
		fi
		;;
	*)
		log_error "unknown component type '$ctype' for $name -- skipping"
		PROBLEMS=$((PROBLEMS + 1))
		;;
	esac
done <"$COMPONENTS_CONF"

# ---------------------------------------------------------------------------
# Stock GMS removal (spec 7: a real GMS / Play install must be shadowed so
# microG is the only provider). Declarative + idempotent; engine-aware via the
# detected mount engine. Placed in the primary partition's overlay.
# ---------------------------------------------------------------------------

cleanup_stock_gms "$PRIMARY_PART" "$DEV_ENGINE" ||
	{ log_warn "stock GMS cleanup reported a problem"; PROBLEMS=$((PROBLEMS + 1)); }

# ---------------------------------------------------------------------------
# Overlay permission/ownership/SELinux normalization (CRITICAL).
#
# Everything above lands files via plain `cp`/`mkdir`, which inherit the
# installer's umask and an unpredictable SELinux context. Magisk does NOT
# auto-normalize "$MODPATH/system" -- its own template explicitly calls
# set_perm_recursive for exactly this reason. If the overlay keeps the wrong
# mode/owner/context, PackageManager silently ignores the APKs and the
# etc/permissions/*.xml allowlists, so microG never gets its privileged perms
# (and service.sh's presence-only check would still report OK -- a silent
# failure). We therefore normalize the whole overlay to the canonical Magisk
# system layout: dirs 0755, files 0644, owner 0:0, context system_file.
#
# Preference order:
#   1. set_perm_recursive (sourced from util_functions.sh during a BOOTMODE
#      install). It is the canonical idiom and sets mode, owner AND context in
#      one call. We probe for it via `command -v` so a context where it is
#      absent (an unusual recovery, or a host test) does not error.
#   2. A manual find-based fallback: chmod dirs/files, best-effort chown 0:0,
#      and a chcon guarded by `command -v` (chcon is missing on some recoveries).
#
# Idempotent and safe when "$MODPATH/system" does not exist (nothing placed).
# ---------------------------------------------------------------------------

# _normalize_overlay: apply the canonical system perms/owner/context to the
# whole module overlay. Returns 0 always (best-effort; a perms failure must not
# abort the install -- it is surfaced via the log instead).
_normalize_overlay() {
	_no_root="$MODPATH/system"
	if [ ! -d "$_no_root" ]; then
		log_info "normalize: no overlay at $_no_root (nothing placed); skipping"
		unset _no_root
		return 0
	fi

	if command -v set_perm_recursive >/dev/null 2>&1; then
		# Canonical Magisk call: dirs 0755, files 0644, owner 0:0; it applies the
		# default system_file context too. Word-split is not a concern (fixed args).
		if set_perm_recursive "$_no_root" 0 0 0755 0644; then
			log_info "normalize: set_perm_recursive applied to $_no_root (0:0 0755/0644 +context)"
		else
			log_warn "normalize: set_perm_recursive reported a problem on $_no_root"
		fi
		unset _no_root
		return 0
	fi

	# Fallback: set_perm_recursive unavailable. Apply the same end state by hand.
	log_warn "normalize: set_perm_recursive unavailable; applying manual chmod/chown/chcon fallback"
	# Directories 0755, files 0644. Two passes keep it portable (no find -perm
	# arithmetic, no GNU-only predicates -- toybox find supports -type/-exec).
	find "$_no_root" -type d -exec chmod 0755 {} + 2>/dev/null ||
		log_warn "normalize: chmod 0755 on dirs failed (continuing)"
	find "$_no_root" -type f -exec chmod 0644 {} + 2>/dev/null ||
		log_warn "normalize: chmod 0644 on files failed (continuing)"
	# Ownership must be root:root for PackageManager to trust a system app. On a
	# real install we are root; on a host test chown will fail harmlessly.
	chown -R 0:0 "$_no_root" 2>/dev/null ||
		log_warn "normalize: chown 0:0 failed (expected off-device; continuing)"
	# SELinux context: chcon is absent on some recoveries -- guard it. Use the
	# same system_file context set_perm_recursive would apply.
	if command -v chcon >/dev/null 2>&1; then
		chcon -R u:object_r:system_file:s0 "$_no_root" 2>/dev/null ||
			log_warn "normalize: chcon system_file failed (continuing)"
	else
		log_warn "normalize: chcon unavailable; SELinux context left as-is"
	fi
	log_info "normalize: manual fallback applied to $_no_root"
	unset _no_root
	return 0
}

_normalize_overlay

# ---------------------------------------------------------------------------
# Summary. We never abort the install for component problems; the boot-time
# self-check (service.sh) re-verifies what actually landed in the overlay.
# ---------------------------------------------------------------------------

if [ "$PROBLEMS" -eq 0 ]; then
	log_info "install complete: all components placed (OK)"
else
	log_warn "install complete with $PROBLEMS problem(s) -- see log (PROBLEM)"
fi
