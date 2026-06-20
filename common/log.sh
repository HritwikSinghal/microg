# shellcheck shell=sh
#
# common/log.sh -- structured logging for the microG installer.
#
# Sourced function library (POSIX sh / bash). It writes timestamped,
# level-tagged lines to a fixed log file and, when running interactively,
# mirrors them to the user-visible channel:
#   - the Magisk/KSU/APatch installer UI via ui_print, if that function is
#     defined by the calling environment (module_installer.sh defines it), or
#   - stderr otherwise (e.g. on a developer host).
#
# Design notes for callers (customize.sh, post-fs-data.sh, service.sh):
#   - Source this file, then call `log_init` once before logging.
#   - Use log_info / log_warn / log_error / log_debug for messages.
#   - The log directory defaults to /data/adb/microg_installer but is
#     overridable via $MICROG_LOG_DIR so host tests (BATS) can redirect it to
#     a temp dir. The log file name is overridable via $MICROG_LOG_FILE.
#   - Debug output is suppressed unless $MICROG_DEBUG is a non-empty value.
#
# This file must be safe to source on a non-Android host: it makes no
# Android-only assumptions at source time and never calls `set -e` at file
# scope (that would abort the caller's shell on the first non-zero command).

# ---------------------------------------------------------------------------
# Configuration (all overridable from the environment for testability).
# ---------------------------------------------------------------------------

# Default on-device location per spec 5.1 / 8. A host test points
# MICROG_LOG_DIR at a temp directory before sourcing or before log_init.
: "${MICROG_LOG_DIR:=/data/adb/microg_installer}"
: "${MICROG_LOG_FILE:=selfcheck.log}"

# Resolved absolute path to the active log file. Populated by log_init.
MICROG_LOG_PATH=""

# ---------------------------------------------------------------------------
# Internal helpers.
# ---------------------------------------------------------------------------

# _log_timestamp: emit a sortable local timestamp. `date` is universally
# present on Android (toybox) and hosts; if it is somehow missing we degrade
# to an empty stamp rather than failing the log call.
_log_timestamp() {
	date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' '????-??-?? ??:??:??'
}

# _log_emit LEVEL MESSAGE...
# Core writer: formats one line and sends it to the log file plus the
# interactive channel. Never returns non-zero for an ordinary message so a
# failed log write cannot abort an installer that ignores its return code.
_log_emit() {
	_lvl="$1"
	shift
	_ts="$(_log_timestamp)"
	_line="$_ts [$_lvl] $*"

	# Append to the log file when a destination is known and writable. The
	# redirect is guarded so a read-only or missing path degrades quietly.
	if [ -n "$MICROG_LOG_PATH" ]; then
		printf '%s\n' "$_line" >>"$MICROG_LOG_PATH" 2>/dev/null || true
	fi

	# Mirror to the user. ui_print is provided by the module installer
	# environment; when absent (host / direct shell) fall back to stderr.
	if command -v ui_print >/dev/null 2>&1; then
		ui_print "$_line" 2>/dev/null || true
	else
		printf '%s\n' "$_line" >&2 2>/dev/null || true
	fi

	unset _lvl _ts _line
	return 0
}

# ---------------------------------------------------------------------------
# Public API.
# ---------------------------------------------------------------------------

# log_init: prepare the log directory and file. Idempotent and safe to call
# more than once. Returns 0 even if the directory cannot be created (the
# emitters degrade to the interactive channel only) so that a missing /data
# mount never aborts the caller.
log_init() {
	MICROG_LOG_PATH="$MICROG_LOG_DIR/$MICROG_LOG_FILE"

	# Create the directory tree if missing. mkdir -p is a no-op when it
	# already exists. Failure is non-fatal: we just lose the file sink.
	if [ ! -d "$MICROG_LOG_DIR" ]; then
		mkdir -p "$MICROG_LOG_DIR" 2>/dev/null || true
	fi

	# Touch the file so later appends and tests have something to read. If
	# the directory creation failed, clear the path so emitters skip the
	# file sink instead of erroring on every line.
	if [ -d "$MICROG_LOG_DIR" ]; then
		: >>"$MICROG_LOG_PATH" 2>/dev/null || MICROG_LOG_PATH=""
	else
		MICROG_LOG_PATH=""
	fi

	return 0
}

# log_info MESSAGE...   informational progress.
log_info() {
	_log_emit "INFO" "$@"
}

# log_warn MESSAGE...   recoverable problem; install continues.
log_warn() {
	_log_emit "WARN" "$@"
}

# log_error MESSAGE...  serious problem; caller decides whether to abort.
log_error() {
	_log_emit "ERROR" "$@"
}

# log_debug MESSAGE...  verbose tracing, suppressed unless MICROG_DEBUG is set
# to a non-empty value. Kept cheap when disabled.
log_debug() {
	if [ -n "${MICROG_DEBUG:-}" ]; then
		_log_emit "DEBUG" "$@"
	fi
	return 0
}
