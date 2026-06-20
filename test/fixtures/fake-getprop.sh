#!/bin/sh
# fixtures/fake-getprop.sh -- mock `getprop` for host BATS tests.
#
# Reads property name/value pairs from the file named in $GETPROP_FIXTURE and
# answers a single query the way Android's `getprop NAME` does:
#   - `fake-getprop.sh NAME` prints the value for NAME (empty line if absent).
#   - `fake-getprop.sh` with no args prints all "[name]: [value]" lines (the
#     bare `getprop` listing form); detection never relies on this but it keeps
#     the mock faithful.
#
# Fixture file format (one per line), matching `getprop` listing output:
#   [ro.build.version.sdk]: [33]
#   [ro.product.cpu.abi]: [arm64-v8a]
#
# Lines that are blank or start with '#' are ignored, so fixtures can carry
# comments.
#
# detect.sh invokes this as the program named in $GETPROP, e.g.
#   GETPROP="sh /abs/test/fixtures/fake-getprop.sh"
# with $GETPROP_FIXTURE pointing at the chosen scenario file.

set -u

fixture="${GETPROP_FIXTURE:-}"
if [ -z "$fixture" ] || [ ! -r "$fixture" ]; then
	# No fixture: behave like getprop for a missing property (empty output).
	exit 0
fi

name="${1:-}"

if [ -z "$name" ]; then
	# Bare listing form.
	grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$fixture"
	exit 0
fi

# Parse "[name]: [value]" lines and echo the value for the requested name.
# Use awk for a precise bracket match so a property name that is a prefix of
# another (e.g. ro.build.version.sdk vs ...sdk_int) does not mis-hit.
awk -v want="$name" '
	/^[[:space:]]*#/ { next }
	{
		# Expect: [name]: [value]
		line = $0
		# Extract name between the first pair of brackets.
		if (match(line, /^\[[^]]*\]/)) {
			key = substr(line, RSTART + 1, RLENGTH - 2)
			if (key == want) {
				rest = substr(line, RSTART + RLENGTH)
				# rest looks like ": [value]"; pull text inside its brackets.
				if (match(rest, /\[.*\]/)) {
					val = substr(rest, RSTART + 1, RLENGTH - 2)
					print val
					found = 1
					exit
				}
			}
		}
	}
	END { if (!found) print "" }
' "$fixture"
