#!/usr/bin/env bats
#
# test/log.bats -- host-side unit tests for common/log.sh.
#
# MICROG_LOG_DIR is redirected into a BATS temp dir so the suite never touches
# the real /data/adb path. No device, no network.
#
# Run with:  bats test/

# `run --separate-stderr` (used below) needs bats >= 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
	load test_helper
	# Each test logs into its own temp dir.
	local scratch
	scratch="$(_scratch_dir)"
	export MICROG_LOG_DIR="$scratch/log.$$.${BATS_TEST_NUMBER:-0}"
	rm -rf "$MICROG_LOG_DIR"
	# Keep debug off by default; the debug test sets it explicitly.
	unset MICROG_DEBUG
	# shellcheck source=/dev/null
	source "$COMMON_DIR/log.sh"
}

@test "log_init creates the log dir and file" {
	log_init
	[ -d "$MICROG_LOG_DIR" ]
	[ -f "$MICROG_LOG_DIR/selfcheck.log" ]
	[ "$MICROG_LOG_PATH" = "$MICROG_LOG_DIR/selfcheck.log" ]
}

@test "log_init is idempotent" {
	log_init
	echo "preexisting" >>"$MICROG_LOG_DIR/selfcheck.log"
	log_init
	# Re-init must not truncate existing content.
	grep -q "preexisting" "$MICROG_LOG_DIR/selfcheck.log"
}

@test "log_info writes a timestamped, level-tagged line" {
	log_init
	log_info "hello world"
	run cat "$MICROG_LOG_DIR/selfcheck.log"
	[ "$status" -eq 0 ]
	# Expect: YYYY-MM-DD HH:MM:SS [INFO] hello world
	echo "$output" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \[INFO\] hello world$'
}

@test "log levels are tagged correctly" {
	log_init
	log_info "an info"
	log_warn "a warn"
	log_error "an error"
	grep -q '\[INFO\] an info' "$MICROG_LOG_DIR/selfcheck.log"
	grep -q '\[WARN\] a warn' "$MICROG_LOG_DIR/selfcheck.log"
	grep -q '\[ERROR\] an error' "$MICROG_LOG_DIR/selfcheck.log"
}

@test "log_debug is suppressed unless MICROG_DEBUG is set" {
	log_init
	log_debug "quiet"
	run grep -c 'quiet' "$MICROG_LOG_DIR/selfcheck.log"
	[ "$output" = "0" ]
}

@test "log_debug is emitted when MICROG_DEBUG is set" {
	export MICROG_DEBUG=1
	log_init
	log_debug "loud"
	grep -q '\[DEBUG\] loud' "$MICROG_LOG_DIR/selfcheck.log"
}

@test "MICROG_LOG_FILE override changes the file name" {
	export MICROG_LOG_FILE="custom.log"
	log_init
	log_info "named"
	[ -f "$MICROG_LOG_DIR/custom.log" ]
	grep -q 'named' "$MICROG_LOG_DIR/custom.log"
}

@test "logging degrades quietly when the dir cannot be created" {
	# Point the dir at a path under a regular file so mkdir -p fails.
	local blocker
	blocker="$(_scratch_dir)/blocker.$$"
	: >"$blocker"
	export MICROG_LOG_DIR="$blocker/subdir"
	log_init
	# No file sink, but logging must not error out.
	[ -z "$MICROG_LOG_PATH" ]
	run log_info "no sink"
	[ "$status" -eq 0 ]
}

@test "messages mirror to stderr on a host (no ui_print)" {
	log_init
	# Capture stderr: with no ui_print defined, the mirror goes to stderr.
	run --separate-stderr log_info "to stderr"
	[ "$status" -eq 0 ]
	echo "$stderr" | grep -q '\[INFO\] to stderr'
}
