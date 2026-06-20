# Phase 1 + Phase 2 -- Inter-module Contracts (single source of truth)

This file is the binding interface contract for the parallel implementation of
Phase 1 (module-only installer) and Phase 2 (Phonesky variant + MapsV1 framework
path). Every implementing agent codes to the function signatures here so the work
can proceed in parallel and integrate without rework. Authoritative background:
`claude/phase1-handoff.md` and `docs/superpowers/specs/2026-06-20-microg-zygisk-installer-design.md`.

## Ground rules (non-negotiable -- from handoff section 2)

- The agent does NOT build, flash, or run on a device. Write code + host BATS
  tests only. Host-side shellcheck/BATS is expected.
- Public repo: never write home paths, private dir names, work email, or device
  codenames. Generic placeholders only.
- ASCII-only in every file.
- On-device scripts only SELECT and PLACE pre-generated XML. They NEVER generate
  XML and NEVER write real partitions (everything lands under `$MODPATH/system`).
- POSIX sh (`#!/system/bin/sh`, `# shellcheck shell=sh` for sourced libs). No
  bashisms. Do not `set -e` at file scope in sourced libraries.
- Every new script must be shellcheck-clean.

## Existing helpers you MUST reuse (already done -- do not reimplement)

### common/log.sh
- `log_init` once before logging (idempotent).
- `log_info` / `log_warn` / `log_error` / `log_debug` (debug gated on `$MICROG_DEBUG`).
- Writes to `$MICROG_LOG_DIR/$MICROG_LOG_FILE` (default
  `/data/adb/microg_installer/selfcheck.log`), mirrors to `ui_print` if defined
  else stderr. Degrades quietly. Tests override `$MICROG_LOG_DIR`.

### common/detect.sh (every probe ECHOES; capture with `$(...)`)
- `detect_api` -> integer (0 if unknown)
- `detect_is64bit` -> `true`|`false`
- `detect_arch` -> `arm64`|`arm`|`x86_64`|`x86`|`unknown`
- `detect_root_manager` -> `magisk`|`kernelsu`|`apatch`|`unknown`
- `detect_mount_engine` -> `overlayfs`|`magic-mount`|`unknown`
- `detect_partitions` -> space-separated canonical order, e.g. `system product system_ext`
- Test seams: `$GETPROP`, `$DETECT_ROOT`, `$DETECT_MOUNTS`, `$DETECT_PART_CANDIDATES`.

### Magisk install env exported into customize.sh
`$MODPATH`, `$API`, `$ARCH`/`$ABI`, `$IS64BIT`, `$BOOTMODE`, and markers
`$KSU`/`$KSU_VER`, `$APATCH`/`$APATCH_VER`, `$MAGISK_VER`/`$MAGISK_VER_CODE`.
`ui_print` is defined by update-binary. There is NO generic `abort` helper.

## components.conf (the install-time input; generated, 7 fixed columns)

Whitespace-separated, one row per non-deferred component, comments start with `#`.
Deferred components (Phonesky, empty url in manifest) are intentionally ABSENT.

```
# name       pkg                      asset               partition  type       perms                conflicts
GmsCore    com.google.android.gms   apks/GmsCore.apk    product    app        perms/gmscore.xml    -
GsfProxy   com.google.android.gsf   apks/GsfProxy.apk   product    app        perms/gsfproxy.xml   -
FakeStore  com.android.vending      apks/FakeStore.apk  product    app        perms/fakestore.xml  Phonesky
MapsV1     com.google.android.maps  apks/maps.jar       product    framework  perms/mapsv1.xml     -
```

- Columns (fixed order): `name pkg asset partition type perms conflicts`.
- `asset` is an in-ZIP path relative to `$MODPATH` (`apks/<Name>.apk` or `apks/maps.jar`).
- `perms` is an in-ZIP path with a LOWERCASED filename: `perms/<name.lower()>.xml`.
- `type` is `app` or `framework`.
- `conflicts` is comma-separated component names, or `-` when none.
- A `perms/sysconfig-microg.xml` is ALSO emitted (behavioral exemptions); it is NOT
  a per-row entry -- handle it once, separately.
- Regenerate a fixture with: `python3 lib/manifest.py emit-conf --out /tmp/components.conf`

## On-device placement layout (target paths under `$MODPATH/system`)

`<part>` = the RESOLVED partition (see `place_resolve_partition` below).

- app priv-app:   `$MODPATH/system/<part>/priv-app/<Name>/<Name>.apk`
- framework jar:  `$MODPATH/system/<part>/framework/<asset basename>`
- privapp/framework permission XML: `$MODPATH/system/<part>/etc/permissions/<basename>`
- sysconfig XML:  `$MODPATH/system/<part>/etc/sysconfig/sysconfig-microg.xml`

## Coordination model (who resolves what)

`customize.sh` is the ONLY coordinator. It resolves the partition ONCE per
component (via `place_resolve_partition`) and passes the RESOLVED partition to
both place_* and perms_* so the app and its permission XML always land in the same
partition. place.sh and perms.sh therefore do NOT resolve partitions themselves --
they receive an already-resolved `<part>`.

## FUNCTION CONTRACTS (the binding interface)

### common/place.sh  (Agent A)

```
place_resolve_partition DECLARED
  # Echo the partition customize.sh should use. Prefer DECLARED if it appears in
  # "$(detect_partitions)"; otherwise echo DECLARED but emit a single log_warn that
  # the declared partition was not detected (fallback). Pure: echoes, returns 0.

place_app NAME ASSET PART
  # Copy "$MODPATH/$ASSET" -> "$MODPATH/system/$PART/priv-app/$NAME/$NAME.apk".
  # Create parent dirs. Idempotent on re-flash: remove any stale "$NAME" priv-app
  # dir first, then place fresh (replace, never merge). log_info what was placed.
  # Return 0 on success; log_error + return non-zero if "$MODPATH/$ASSET" missing.

place_framework NAME ASSET PART        # (Phase 2 path -- implement now)
  # Copy "$MODPATH/$ASSET" -> "$MODPATH/system/$PART/framework/$(basename ASSET)".
  # Create parent dirs, idempotent. Return 0 / non-zero as above.

place_remove NAME PART                  # used by conflict resolution + idempotence
  # Remove "$MODPATH/system/$PART/priv-app/$NAME" (and a framework copy if present)
  # if it exists. Idempotent no-op when absent. Return 0.
```
Keep a Placer-style seam (comment + structure) so a Phase 3 DirectPartitionPlacer
can slot in. No real-partition writes.

### common/perms.sh  (Agent B)

```
perms_select PERMS_REF API
  # PERMS_REF is the components.conf perms column (e.g. perms/gmscore.xml, already
  # lowercased). API is the device API level. Echo the in-ZIP source path to the
  # chosen XML (normally "$MODPATH/$PERMS_REF"). DESIGN for future per-API variants
  # (e.g. prefer "$MODPATH/perms/gmscore-$API.xml" if it exists, else the base
  # file) even though Phase 1 ships a single variant. Echo empty string if no file
  # is found (caller logs + treats as failure). Returns 0.

perms_validate FILE
  # Return 0 if FILE parses as XML. Use `xmllint --noout` when available; when
  # xmllint is absent (typical on device) degrade: log_warn once and accept
  # (return 0) rather than failing the install. Return non-zero only when xmllint
  # IS available and reports the file invalid.

perms_place_app NAME PERMS_REF PART API
  # select + validate + copy chosen XML ->
  #   "$MODPATH/system/$PART/etc/permissions/$(basename chosen)".
  # Idempotent (overwrite). log_info. Return 0 / non-zero (missing or invalid).

perms_place_framework NAME PERMS_REF PART API     # (Phase 2) framework lib perms
  # Same destination dir as app perms: "$MODPATH/system/$PART/etc/permissions/".
  # (A framework <library> permission file lives in etc/permissions too.)

perms_place_sysconfig PART
  # If "$MODPATH/perms/sysconfig-microg.xml" exists, copy it ->
  #   "$MODPATH/system/$PART/etc/sysconfig/sysconfig-microg.xml". Idempotent.
  # Called ONCE by customize.sh (not per row). No-op + return 0 if absent.
```
Never generate XML on device. Selection + validation + placement only.

### common/cleanup.sh  (Agent C)

```
cleanup_stock_gms PART ENGINE
  # Declarative StockGmsRemover. ENGINE is "$(detect_mount_engine)".
  # Prefer the Magisk REPLACE sentinel over mknod whiteouts (whiteouts can
  # silently no-op under OverlayFS). The Magisk REPLACE convention: create the
  # target dir under the module overlay and drop a file named ".replace" in it,
  # i.e. "$MODPATH/system/$PART/priv-app/<StockDir>/.replace", which makes the
  # mount engine present that system dir as empty.
  # Iterate a declarative list of known stock GMS/Play dir names (e.g.
  # PrebuiltGmsCore, GmsCore, GoogleServicesFramework, Phonesky, Vending) under
  # priv-app and app. Idempotent. log_info each REPLACE created. Return 0.
  # Engine-aware: if ENGINE is magic-mount the same REPLACE sentinel applies;
  # genuinely engine-specific early-boot work belongs in post-fs-data.sh.
```
post-fs-data.sh and service.sh are root-level scripts (siblings of customize.sh):

- `post-fs-data.sh`: sources log.sh (+ detect.sh as needed), runs engine-aware
  stock-GMS removal that must happen at EARLY boot (pre-decryption). FBE-safe:
  NEVER touch `/data/data` here. `MODDIR="${0%/*}"`. log to selfcheck.log.
- `service.sh`: boot-gated self-check. Wait until
  `[ "$(getprop sys.boot_completed)" = "1" ]` (bounded loop). Then write a
  self-check summary to selfcheck.log via log.sh ONLY (no placement work):
  detected env, which packages are present in the overlay, final OK/PROBLEM line.

### customize.sh  (Agent D) -- the generic interpreter

```
MODDIR="${MODPATH:?MODPATH must be set}"
. "$MODDIR/common/log.sh"
. "$MODDIR/common/detect.sh"
. "$MODDIR/common/place.sh"
. "$MODDIR/common/perms.sh"
. "$MODDIR/common/cleanup.sh"
log_init
# probe env (api/arch/engine/root mgr), log a banner
# perms_place_sysconfig <resolved part for the primary partition> once
# read "$MODDIR/components.conf" line by line:
#   - skip blank lines and lines beginning with '#'
#   - read 7 fields: name pkg asset partition type perms conflicts
#   - part="$(place_resolve_partition "$partition")"
#   - resolve conflicts: for each comma-separated name in `conflicts` (ignore '-'),
#     purge that component from the overlay so switching variants on re-flash is
#     clean: place_remove <conflictName> <part> AND remove its perms XML. This is
#     the atomic FakeStore<->Phonesky mutual exclusion -- done across place+perms.
#   - dispatch on `type`:
#       app)       place_app NAME ASSET part      && perms_place_app NAME PERMS part API
#       framework) place_framework NAME ASSET part && perms_place_framework NAME PERMS part API
#   - on any failure: log_error and continue to the next row (record a PROBLEM),
#     do not abort the whole install for one bad component.
# edge cases (spec 7): arch mismatch (log_warn), API < 26 (XML harmless, proceed),
# real GMS present (cleanup_stock_gms handles removal).
# Stays a thin interpreter: adding/swapping a component is a components.conf change.
```

## Testing requirements (all agents)

- Follow the existing BATS pattern: `test/test_helper.bash` (helpers
  `getprop_fixture`, `make_fixture_root`, `write_mounts`, `_scratch_dir`),
  `test/detect.bats`, `test/log.bats`. `load test_helper` in `setup()`.
- Mock the device: set `$MODPATH` to a tmpdir under `$(_scratch_dir)`,
  `$MICROG_LOG_DIR` to a tmpdir, `$DETECT_ROOT`/`$DETECT_MOUNTS` to fixtures.
  NEVER write to a real path; never touch the network.
- Source the unit under test in `setup()` (e.g. `source "$COMMON_DIR/place.sh"`);
  also source `log.sh` and `detect.sh` since the unit calls them.
- Each agent runs ONLY its own test file while developing (e.g.
  `bats test/place.bats`) and `shellcheck` on ONLY its own scripts -- do NOT run
  the whole `bats test/` dir or touch other agents' not-yet-written files.
- Agent D (customize): test the interpreter against STUB modules. Build a fake
  `$MODPATH` whose `common/place.sh`, `common/perms.sh`, `common/cleanup.sh` are
  stubs that record their calls (e.g. append "place_app NAME ASSET PART" to a log
  file), plus a `components.conf` fixture and dummy `apks/`+`perms/` files. Assert
  the interpreter parses rows, skips comments/blanks, calls the right function with
  the right args per `type`, performs conflict purge, and calls perms_place_sysconfig
  once. This unit-tests interpreter logic without coupling to real placement.

## Ownership (disjoint -- do not edit outside your set)

- Agent A: `common/place.sh`, `test/place.bats`
- Agent B: `common/perms.sh`, `test/perms.bats`
- Agent C: `common/cleanup.sh`, `post-fs-data.sh`, `service.sh`, `test/cleanup.bats`
- Agent D: `customize.sh`, `test/customize.bats`
- Agent E: `docs/phonesky-sourcing.md`

Do NOT edit: `.github/workflows/build.yml`, `claude/progress.md`,
`claude/phase1-handoff.md`, this file, or any file owned by another agent. The
orchestrator integrates those (adds scripts to the CI shellcheck list, runs the
full suite, updates progress.md) after all agents return.
