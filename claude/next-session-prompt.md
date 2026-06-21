# Handoff prompt -- microG Universal Installer (post-v0.1.0 hardening done; next: VALIDATE, then matrix doc / sync-adapter placement / Phase 3 or release)

Copy the prompt below into a fresh session to continue this project with clean
context. Everything it needs is on disk; it does not need the prior conversation.

---

## Prompt for the next agent

You are picking up a long-running project in this repository (work from the repo
root): a single flashable ZIP that installs microG as privileged system apps on
stock Android, working across Magisk / KernelSU / APatch as a systemless module
overlay. The design is DONE and approved. Phases 0, 1, and 2 are CODE-COMPLETE and
host-tested; v0.1.0 was cut once and its tag later removed during a history
cleanup. The most recent session (Session 6) did a repo-wide bug hunt + fixes and a
requirements-hardening pass (permission allowlisting, sync adapters, spoofing docs)
WITHOUT running tests or builds (the user deferred that to themselves to save
tokens). So your FIRST job is validation -- see step 0 below.

### First: read these, in order (do not skip)
1. `claude/progress.md` -- the phase tracker + authoritative status; read the
   Session 6 entry under "Decisions & Notes" for what just changed.
2. `docs/superpowers/specs/2026-06-20-microg-zygisk-installer-design.md` -- the
   full design spec (source of truth). Focus on sections 5-7 (build + perms) and
   10-12.
3. `claude/phase1-2-contracts.md` -- the binding inter-module function contract the
   on-device scripts implement. Any new on-device code must honor it.
4. `claude/phase1-handoff.md` -- the Phase 1 brief (still accurate background).
5. `docs/signature-spoofing.md` -- the spoofing prerequisite/guide (written in
   Session 6).
6. `CLAUDE.md` (this repo) + your global instructions + your project-memory store.

### Step 0 (DO THIS FIRST): validate Session 6's unrun work
Session 6 changed correctness-critical code and updated tests but did NOT run them.
Before anything else, run the host checks and FIX any breakage:
- `python3 -m pytest test/ -v`  (the Python suite was reworked for the new perms
  data model + the new unknown-perm guard; confirm it is green).
- `npx --yes bats test/`  (`bats` is not on PATH; BATS suite should be unaffected).
- `shellcheck` the scripts in the `.github/workflows/build.yml` checks list.
- A hermetic build is the real validation of the permission work, because the
  fail-closed guard only fires where the actual APKs exist. The `build` job needs
  real APK hashes (see Option E) and Android build-tools (apkanalyzer); the user
  runs device-facing steps. If you cannot build, at minimum confirm the unit suite
  passes and say clearly that a full build was not run.
Report the result. Do not proceed to feature work until the suite is green.

### Current repo state (verified as of Session 6)
On-device runtime (Phase 0/1/2, unchanged in structure):
- `common/detect.sh`, `common/log.sh` -- env probes + logging.
- `common/place.sh` -- ModuleOverlayPlacer: `place_resolve_partition`, `place_app`,
  `place_framework`, `place_remove`. `_place_overlay_root` is the Phase-3 seam.
  IMPORTANT LIMITATION: every `type=app` row is placed into `priv-app/`; there is
  NO `system/app` (non-priv-app) path yet (blocks un-deferring the sync adapters --
  see Option C).
- `common/perms.sh` -- `perms_select` (API-variant aware), `perms_validate`,
  `perms_place_app` / `perms_place_framework` / `perms_place_sysconfig`.
- `common/cleanup.sh` -- `cleanup_stock_gms PART ENGINE`.
- `customize.sh` -- generic components.conf interpreter (conflict purge, per-row
  failure isolation, type dispatch). Session 6 added `set -f`/`set +f` around the
  two `set -- $line` row splits (noglob-safe field parsing).
- `post-fs-data.sh` -- early-boot REPLACE re-lay, reads the resolved partitions
  from `$MODDIR/.microg-partitions` (written by customize.sh). `service.sh` --
  bounded boot-gate then self-check verdict to `selfcheck.log`. customize.sh also
  now runs `set_perm_recursive $MODPATH/system 0 0 0755 0644` (with a guarded
  chmod/chown/chcon fallback) so placed files get correct mode/owner/context.

Build / CI / data (this is where Session 6's main work landed):
- `manifest.toml` -- build-time source of truth. Now 7 components: GmsCore,
  GsfProxy, FakeStore, MapsV1 (framework), Phonesky (deferred), and TWO new
  DEFERRED, off-by-default sync adapters: `com.google.android.syncadapters.contacts`
  and `...calendar` (Google-signed; empty url + PENDING-BUMP + placeholder cert).
- `data/platform-perms-{30,33,34,35}.txt` -- NEW data model. Each is the full AOSP
  platform-permission table (`<name><TAB><protectionLevel>`) extracted from the
  AOSP core/res manifest at a pinned release tag (30 r48, 33 r83, 34 r67, 35 r20),
  documented in each file header. The old `data/privileged-perms-{30,34}.txt` were
  REMOVED -- nothing reads them anymore.
- `lib/genperms.py` -- derives BOTH the privileged set (level contains
  "privileged") and the full platform set from the platform-perms tables; a target
  `--api` unions all covered levels <= it (`PINNED_APIS=(30,33,34,35)`). New
  `extract-perms --aosp-manifest --api --out` subcommand regenerates a table.
  Allowlist semantics unchanged: `granted = requested & privileged + FAKE`.
  sysconfig now emits all three canonical exemptions (power-save,
  data-usage-save, unthrottled-location).
- `lib/invariant.py` -- `check-perms` now runs a FAIL-CLOSED unknown-permission
  guard: any requested `android.permission.*` not in the pinned platform tables
  (and not the microG-custom FAKE_PACKAGE_SIGNATURE) fails the build, refusing to
  guess whether an unknown platform perm is privileged. The under-list check is now
  authoritative (privileged set comes from AOSP). `check-signer` unchanged.
- `lib/fetch.sh`, `build.sh`, `tools/bump`, `.github/workflows/{build,bump}.yml`.
  Session 6 hardening here: signer-cert gate runs on every path (build.yml diffs
  against the merge-base and FAILS CLOSED if the base manifest is unobtainable on a
  PR), third-party actions SHA-pinned, least-privilege `permissions:`, deterministic
  ZIP, multi-signer cert handling, framework-asset validation, bump downgrade guard
  + atomic write + shared `_norm_cert`.
- Tests: `test/*.bats` + `test/genperms_test.py` (reworked + new ExtractPerms and
  UnknownPermissionGuard tests). RUN THEM to get current counts (Session 6 did not).

### Hard constraints (from the user -- non-negotiable)
- DO NOT build for / flash / run on / SSH to any device. The user deploys and
  verifies on real phones. Write code/docs + host checks only.
- Public repo: never commit home paths, private dir names, the user's work email,
  or device codenames. Generic placeholders only.
- ASCII-only output (a Stop hook enforces it; even accented words like a backend
  name will block the turn).
- Autocommit in logically-grouped commits; squash your own noise before it gets
  messy. NOTE: the commit hook blocks any shell command containing the literal
  token for the project tracking dir -- stage those files via a glob
  (e.g. `git add cla*/*.md`) and keep that token out of the commit message. The
  destructive_guard hook also blocks commands whose TEXT contains patterns like a
  forced recursive delete or `reset --hard` -- including inside a commit message;
  reword to avoid the literal pattern. File deletions need explicit user
  confirmation and you cannot mint the confirm token yourself -- have the user run
  the deletion. Do not push or tag unless asked.
- On-device scripts only SELECT + PLACE pre-generated XML and only write under
  `$MODPATH/system`. Build-time XML generation + the CI permission invariant
  (now including the fail-closed unknown-perm guard) is the bootloop cure -- do not
  weaken it.
- Signature spoofing is OUT of the installer by design (`docs/signature-spoofing.md`
  documents that the user must supply it via a microG-aware ROM or FakeGApps). The
  apksigcopier/no-sigspoof route was researched and explicitly DEFERRED.

### Open work -- pick with the user (after Step 0 is green)
**Option A -- Component comparison matrix doc.** `docs/temp.md` exists (committed
in 458eb10) and holds the RAW material for a matrix comparing this installer's
components against micro5k, MinMicroG, NanoDroid, nift4-revived, and
Lineage4microG -- but it is a raw chat dump with NON-ASCII box-drawing and must be
rewritten as a clean ASCII markdown doc (e.g. `docs/comparison.md`) and linked from
the README, then `docs/temp.md` removed (deletion needs user confirmation). The
factual content to preserve: our 5-component core == canonical Lineage4microG core
minus F-Droid; the differences are optional add-ons + the spoofing story.

**Option B -- `place.sh` system/app placement path.** Add a placement-location
field to the components.conf schema (priv-app vs app) and a `system/app` write path
in `common/place.sh`, honoring the contract. This is the PREREQUISITE before the
sync adapters can be un-deferred (they install to `system/app`, not priv-app, and
need no privapp-permissions entry). Add BATS coverage.

**Option C -- Bump the sync adapters (network step, needs the user).** Pin real
sources for the two Google-signed sync adapters. Research from Session 6: the Google
"Android" platform signer-cert SHA-256 is
`f0fd6c5b410f25cb25c3b53346c8972fae30f8ee7411df910480ad6b2d60db83` (distinct from
the microG cert `9bd0...14165`); candidate sources are APKMirror (Google-verified),
MindTheGapps, or MinMicroG. They are API-level-specific, so a real pin records
version_code + per-API APK sha256. Do Option B first (placement) or the placed
adapters land in the wrong dir. Pinning downloads APKs -- surface the plan; let the
user drive.

**Option D -- Phase 3: System-mode / direct-partition placement.** Implement
`DirectPartitionPlacer` behind the `_place_overlay_root` seam (mount rw, 0644,
SELinux contexts), free-space / dynamic-partition / A-B handling, addon.d OTA
survival. Module mode stays default. KNOWN FOLLOW-UP to fix here: `place_remove`
clears a framework jar named `<Name>.jar` but `place_framework` writes
`<basename of asset>` (e.g. `maps.jar`) -- reconcile.

**Option E -- Cut / re-cut the release (decision + network step).** The `release`
job runs only on a `v*` tag AND when the manifest is bumped (real APK hashes, not
PENDING-BUMP). v0.1.0 was published once then its tag removed during a history
squash. Re-tag from current history to re-publish, OR cut a new version that
includes the Session 6 hardening. Pinning + tagging are outward-facing on a public
repo -- surface the plan, let the user drive; do not bump or tag unilaterally. Note
Phase 1/2 are host-tested but NOT yet device-verified.

### Update protocol
After each task: mark it `[x]` in `claude/progress.md`, recount the Status Summary,
update the date/session. Follow the global CLAUDE.md discipline for diary +
project-memory writes UNLESS the user opts out for the session. Pull current docs
via context7 for Magisk module / SELinux / addon.d / AOSP perms APIs rather than
relying on memory.
