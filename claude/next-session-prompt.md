# Handoff prompt -- microG Universal Installer (Phase 1 + 2 done; next: Phase 3 or release)

Copy the prompt below into a fresh session to continue this project with clean
context. Everything it needs is on disk; it does not need the prior conversation.

---

## Prompt for the next agent

You are picking up a long-running project in this repository (work from the repo
root): a single flashable ZIP that installs microG as privileged system apps on
stock Android, working across Magisk / KernelSU / APatch as a systemless module
overlay. The design is DONE and approved. Phases 0, 1, and 2 are CODE-COMPLETE,
host-tested, and pushed to `master`. Your job is to do ONE of the two next steps
(ask the user which) -- Phase 3, or cut the first real release -- not both.

### First: read these, in order (do not skip)
1. `claude/progress.md` -- the 6-phase tracker and the authoritative status. Phase
   0/1/2 are `[x]`; Status Summary shows them code-complete.
2. `docs/superpowers/specs/2026-06-20-microg-zygisk-installer-design.md` -- the
   full design spec (source of truth). Focus on sections 5-7 and 10-12.
3. `claude/phase1-2-contracts.md` -- the binding inter-module function contract
   the existing scripts implement. Any new on-device code must honor it.
4. `claude/phase1-handoff.md` -- the Phase 1 brief (still accurate background).
5. `CLAUDE.md` (this repo) + your global instructions + your project-memory store.

### Current repo state (verified, do not rebuild)
- `common/detect.sh`, `common/log.sh` -- env probes + logging (Phase 0).
- `common/place.sh` -- ModuleOverlayPlacer: `place_resolve_partition`, `place_app`,
  `place_framework`, `place_remove`. Single `_place_overlay_root` seam is where a
  Phase 3 DirectPartitionPlacer slots in.
- `common/perms.sh` -- `perms_select` (API-variant aware), `perms_validate`
  (xmllint-optional), `perms_place_app` / `perms_place_framework` /
  `perms_place_sysconfig`. Selects + places pre-generated XML; never generates.
- `common/cleanup.sh` -- `cleanup_stock_gms PART ENGINE` (declarative REPLACE
  sentinels over a stock-dir list).
- `customize.sh` -- the generic components.conf interpreter (conflict purge +
  per-row failure isolation + type dispatch). Thin: a component is data, not code.
- `post-fs-data.sh` -- early-boot REPLACE re-lay, FBE-safe. `service.sh` -- bounded
  boot-gate then a self-check verdict to `selfcheck.log`.
- Build/CI: `manifest.toml` (build-time source of truth), `lib/{manifest,genperms,
  invariant}.py`, `lib/fetch.sh`, `build.sh`, `tools/bump`,
  `.github/workflows/{build,bump}.yml`.
- Tests: `test/*.bats` (place 13, perms 20, cleanup 16, customize 20, detect 19,
  log 9) + `test/genperms_test.py` (31). 96 BATS + 31 pytest. shellcheck clean on
  all 10 scripts in the CI list.

### Hard constraints (from the user -- non-negotiable)
- DO NOT build, flash, run on, or SSH to any device. The user deploys and verifies
  on real phones. Write code/docs + host checks only (shellcheck, BATS, the CI
  invariant). `bats` is not on PATH here; use `npx --yes bats test/`.
- Public repo: never commit home paths, private dir names, the user's work email,
  or device codenames. Generic placeholders only.
- ASCII-only output (a hook enforces it).
- Autocommit in logically-grouped commits. NOTE: the commit hook blocks any shell
  command containing the literal token for the project tracking dir -- stage those
  files via a glob (e.g. `git add cla*/*.md`) and keep that token out of the commit
  message. Do not push or tag unless asked.
- On-device scripts only SELECT + PLACE pre-generated XML and only write under
  `$MODPATH/system`. The build-time XML generation + CI permission invariant is the
  bootloop cure -- do not weaken it.
- Signature spoofing is OUT of the installer (separate guide, Phase 5).

### Choose ONE next step (ask the user)

**Option A -- Phase 3: System-mode / direct-partition placement.**
Implement `DirectPartitionPlacer` behind the existing Placer seam in `place.sh`
(real-partition writes: mount rw, 0644 modes, SELinux contexts), plus free-space /
dynamic-partition / A-B slot handling and addon.d OTA survival. Keep module mode
the default; direct mode is opt-in. Honor the contract in
`claude/phase1-2-contracts.md`; add BATS coverage; run `shellcheck` +
`npx --yes bats test/`. Update `progress.md` per task. KNOWN FOLLOW-UP to fix here:
`place_remove` clears a framework jar named `<Name>.jar`, but `place_framework`
writes `<basename of asset>` (e.g. `maps.jar`) -- reconcile so a framework
component can be cleanly removed (harmless today: only app-type conflicts exist).

**Option B -- Cut the first real release (needs a decision + the network step).**
The release pipeline cannot publish an artifact until `manifest.toml` has real APK
hashes -- every hash is `PENDING-BUMP` by design. The `build` job neutral-skips
(stays green) while unpinned; the `release` job runs only on a `v*` tag AND when
the manifest is bumped. So a real release is: run the `bump` step (the only
network-trusting action -- `bump.yml` workflow dispatch opens a manifest-pin PR, or
`tools/bump` locally) -> merge the real pins -> THEN push a `v*` tag -> the Release
publishes. Pinning is outward-facing (downloads APKs) and tagging is a public
Release on a public repo -- surface the plan and let the user drive it; do not run
the bump or push a tag unilaterally. Whoever cuts the release should also note that
Phase 1/2 are host-tested but NOT yet device-verified (no on-device flash has run).

### Update protocol
After each task: mark it `[x]` in `claude/progress.md`, recount the Status Summary,
update the date/session. Append diary + project-memory writes per the global
CLAUDE.md discipline. Pull current docs via context7 for Magisk module / SELinux /
addon.d APIs rather than relying on memory.
