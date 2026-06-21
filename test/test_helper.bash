# test_helper.bash -- shared helpers for the microG installer BATS suite.
#
# Sourced by every *.bats file. Provides:
#   - REPO_ROOT / COMMON_DIR / FIXTURES_DIR path resolution.
#   - getprop_fixture: wire detect.sh's GETPROP seam to a fixture file.
#   - make_fixture_root: create a throwaway DETECT_ROOT tree under BATS_TEST_TMPDIR.
#   - write_mounts: write a /proc/mounts fixture for the mount-engine probe.
#
# These helpers only touch BATS-provided temp dirs; they never write to the
# real system, hit the network, or require a device. Tests run with
# `bats test/` on any host.

# Resolve the repository root from this file's location (test/ is a direct
# child of the repo root). BASH_SOURCE[0] is this helper.
#
# COMMON_DIR and FIXTURES_DIR are consumed by the .bats files that `load` this
# helper, not within the helper itself; the directives below tell shellcheck
# they are used externally when it lints this file standalone.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck disable=SC2034  # used by .bats files that source this helper
COMMON_DIR="$REPO_ROOT/common"
# shellcheck disable=SC2034  # used by .bats files that source this helper
FIXTURES_DIR="$TEST_DIR/fixtures"

# A per-test scratch directory. BATS sets BATS_TEST_TMPDIR (>= 1.x) per test;
# fall back to BATS_TMPDIR for older releases.
_scratch_dir() {
	printf '%s' "${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}"
}

# getprop_fixture FIXTURE_BASENAME
# Point detect.sh's overridable GETPROP program at the fake-getprop mock,
# backed by the named fixture file under test/fixtures. Exports GETPROP and
# GETPROP_FIXTURE for the current test.
getprop_fixture() {
	local fixture="$FIXTURES_DIR/$1"
	[ -r "$fixture" ] || {
		echo "missing getprop fixture: $fixture" >&2
		return 1
	}
	export GETPROP_FIXTURE="$fixture"
	# Run the mock with sh; the value is intentionally multi-word so detect.sh
	# word-splits it into "sh <script>".
	export GETPROP="sh $FIXTURES_DIR/fake-getprop.sh"
}

# make_fixture_root
# Create an empty DETECT_ROOT tree for this test and echo its path. Callers
# then `mkdir`/`touch` the markers they want (e.g. data/adb/magisk) and set
# DETECT_ROOT to the returned path. Each test gets a unique subdir so they do
# not interfere.
make_fixture_root() {
	local root
	root="$(_scratch_dir)/root.$$.${BATS_TEST_NUMBER:-0}"
	rm -rf "$root"
	mkdir -p "$root"
	printf '%s' "$root"
}

# write_mounts ROOT CONTENT
# Write CONTENT as the /proc/mounts fixture inside a fixture ROOT and echo the
# resulting path (suitable for $DETECT_MOUNTS). CONTENT is taken verbatim.
write_mounts() {
	local root="$1"
	local content="$2"
	mkdir -p "$root/proc"
	printf '%s\n' "$content" >"$root/proc/mounts"
	printf '%s' "$root/proc/mounts"
}
