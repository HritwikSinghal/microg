# microG Universal Installer -- Progress

Last updated: 2026-06-21 | Session: 5

## Phase 1 Handoff

A fresh-context brief for the next agent (grounded in actual repo state, with the
exact contracts for components.conf, detect.sh, log.sh, and on-device placement)
lives at `claude/phase1-handoff.md`. Start there before Phase 1.

## Overview

A single flashable ZIP that installs microG as privileged system apps on stock
Android, working across Magisk / KernelSU / APatch as a systemless module overlay.
The installer ships NO signature spoofing (provided by the ROM or an add-on, and
covered by a separate guide). Full design: docs/superpowers/specs/2026-06-20-microg-zygisk-installer-design.md

Key principles:
- Permission XMLs generated at build time + a CI invariant make a bootlooping
  release unbuildable (the #1 failure mode in reference installers).
- Module mode overlays under $MODPATH/system; it never writes real partitions in
  Phase 1, so partition/free-space/A-B concerns are deferred to Phase 3.
- Data-driven components.conf; customize.sh is a generic interpreter.
- Detect the mount engine (magic-mount vs OverlayFS), not the root manager.

## Plan

### Phase 0 -- Foundations + CI invariant
- [x] Repo scaffold (module.prop, META-INF, dir layout, .gitignore for apks/)
      -- module.prop + vendored topjohnwu update-binary + #MAGISK updater-script;
         placeholder customize.sh; .gitignore for apks/perms/components.conf/zip/pycache
- [x] manifest.toml schema + 5 component entries (build-time pins: versionCode, url, apk sha256, signer-cert sha256)
      -- GmsCore/GsfProxy/FakeStore (microG-signed) + MapsV1 (framework jar) + Phonesky
         (deferred, empty-url marker); all sha256 = "PENDING-BUMP" until first bump
- [x] lib/fetch.sh: download + 3-anchor verify (sha256 + apksigner verify + cert match)
      -- type=app: 3 anchors; type=framework (jar): sha256-only; PENDING-BUMP = loud fail
- [x] lib/genperms.py: requested(APK) INTERSECT privileged_perms(API) + FAKE_PACKAGE_SIGNATURE; separate sysconfig XML
      -- Python; data-driven privileged-perms via data/privileged-perms-<api>.txt, unions API
         levels; injectable requested-list for host tests; xmllint validation; XXE-hardened parser;
         dump-requested subcommand (single requested-perms source for genperms + invariant)
- [x] common/detect.sh (api, arch, root manager, mount engine, partition) + host BATS harness
      -- pure read-only probes; GETPROP/DETECT_ROOT/DETECT_MOUNTS indirection for mocking; 19 BATS tests
         (+ 9 BATS tests for log.sh = 28 shell tests total)
- [x] common/log.sh structured logging
      -- selfcheck.log (MICROG_LOG_DIR overridable); mirrors ui_print/stderr; degrades quietly
- [x] build.sh (hermetic): orchestrate fetch+genperms, assemble ZIP, emit slim components.conf from manifest
      -- joins manifest.py list (fetch) + components.conf (place) by name; sidecars kept out of the zip
- [x] bump tool (separate, network-trusting): rewrite manifest.toml from F-Droid/GitHub (tools/bump)
      -- GitHub releases / F-Droid index-v2; hard-fails on signer-cert change; skips deferred + framework
- [x] CI permission-invariant gate (requested_privileged subset-of allowlist; default-permissions subset-of declared; xmllint)
      -- lib/invariant.py check-perms; host tests in test/genperms_test.py (31 tests, all pass)
- [x] CI signer-cert gate (refuse bump where signer_cert_sha256 changed)
      -- lib/invariant.py check-signer (operates on manifest.toml; reusable signer_cert_gate())
- [x] GitHub Actions: build.sh + invariants + artifact upload + publish Release on tag; separate bump-PR workflow
      -- .github/workflows/build.yml (checks -> build -> release-on-v*) + bump.yml (dispatch/weekly -> PR)

### Phase 1 -- Module-only installer (Magisk + KSU + APatch)
- [x] customize.sh manifest interpreter
      -- thin data-driven interpreter over components.conf; per-row failure isolation
         (one bad component does not abort install); fatal only on missing
         MODPATH/components.conf/library. 20 BATS tests against stub modules.
- [x] common/place.sh ModuleOverlayPlacer
      -- place_resolve_partition / place_app / place_framework / place_remove;
         whole-word partition match + warn-fallback; rm-then-copy idempotence
         (replace never merge); single _place_overlay_root seam for Phase 3
         DirectPartitionPlacer. 13 BATS tests.
- [x] common/perms.sh XML selection by API level + placement in matching partition
      -- perms_select (prefers perms/<base>-<API>.xml, falls back to base);
         perms_validate (xmllint when present, warn-once+accept when absent);
         perms_place_app/framework -> etc/permissions, perms_place_sysconfig ->
         etc/sysconfig. Never generates XML on device. 20 BATS tests.
- [x] common/cleanup.sh StockGmsRemover via declarative REPLACE sentinel
      -- cleanup_stock_gms PART ENGINE drops .replace sentinels over a declarative
         stock-dir list under priv-app + app; portable across magic-mount/overlayfs;
         idempotent. 16 BATS tests (shared with boot scripts).
- [x] post-fs-data.sh (engine-aware removal) + service.sh (boot-gated self-check log)
      -- post-fs-data: early-boot REPLACE re-lay, FBE-safe (no /data/data);
         service.sh: bounded boot-gate loop ($GETPROP seam + SVC_BOOT_* knobs),
         self-check summary to selfcheck.log only.
- [x] selfcheck.log diagnostics
      -- service.sh writes detected env + overlay package presence + OK/PROBLEM verdict.
- [x] shellcheck clean across all scripts
      -- all 10 scripts in the CI list pass; new scripts added to build.yml shellcheck step.

### Phase 2 -- Phonesky variant + MapsV1 framework path
- [x] Phonesky vs FakeStore mutual-exclusion (atomic across place+perms+cleanup)
      -- customize.sh _purge_conflicts splits the conflicts column and calls
         place_remove + deletes the conflicting perms XML before placing; clean
         variant switch on re-flash.
- [x] type=framework handling (JAR -> framework dir + permissions XML)
      -- place_framework -> system/<part>/framework/<basename>; perms_place_framework
         -> etc/permissions; customize dispatches on the type column.
- [x] Resolve Phonesky sourcing/mirror question
      -- decision: user-supplied APK (no Google binary shipped); doc at
         docs/phonesky-sourcing.md. manifest.toml Phonesky stays deferred.

### Phase 3 -- System-mode / direct-partition placement
- [ ] DirectPartitionPlacer (mount rw, 0644, SELinux contexts)
- [ ] Free-space, dynamic-partition, A/B slot handling
- [ ] addon.d OTA survival

### Phase 4 (stretch) -- Recovery flashing
- [ ] ZIP signing + key management
- [ ] /mnt/system mounting + Android-14 free-space workaround

### Phase 5 -- Signature-spoofing guide (parallel; can start anytime)
- [ ] Patched-ROM detection + which ROMs already spoof
- [ ] LSPosed + FakeGApps route (fork selection, Zygisk impl per root manager)
- [ ] Native Zygisk spoofing options survey
- [ ] Verification + pitfalls (no GMS coexistence, activation, DenyList/Shamiko)

## Release Milestones

- **v0.1.0** -- cut on 2026-06-21 (Phases 0-2, working flashable module), then the
  tag and GitHub Release were removed during a history cleanup (the whole commit
  history was squashed into logical commits, which invalidated the tag). The code is
  unchanged and release-ready; re-tag from the rewritten history when ready to
  publish. Release assets were: microg-installer-v0.1.0.zip (flashable module),
  update.json (in-app auto-update feed), changelog.md (generated from git log).

## Status Summary

| Phase | Status | Tasks done |
|-------|--------|------------|
| Phase 0 -- Foundations + CI invariant | Code-complete, build green | 11/11 |
| Phase 1 -- Module-only installer | Code-complete, build green | 7/7 |
| Phase 2 -- Phonesky + MapsV1 | Code-complete, build green | 3/3 |
| Phase 3 -- System-mode placement | Pending | 0/3 |
| Phase 4 -- Recovery flashing | Pending | 0/2 |
| Phase 5 -- Spoofing guide | Pending | 0/4 |

Phases 0-2 are code-complete and verified by a real (green) build: `tools/bump`
filled real F-Droid APK hashes (PR #1), so the `build` CI job passes and can
publish. The PENDING-BUMP era is over. Verification of on-device behaviour remains
the user's to run (per directive: agent does not build/test/flash).

## Decisions & Notes

- 2026-06-20: Design finalized via brainstorming + architecture review. Base =
  fresh clean module (not a fork); micro5k module path is a stub, MinMicroG upstream
  is dead. Spoofing excluded from the installer, shipped as a separate guide.
  APKs CI-downloaded + SHA-pinned (not committed). XML generation at build time
  with a CI invariant as the permanent bootloop fix. Mount-engine detection over
  root-manager inference. See the design spec for full rationale.
- 2026-06-20: Build-system arch review (adopting good MinMicroG ideas, dropping its
  traps). Decisions: (1) hermetic build -- split `bump` (network, rewrites manifest)
  from `build` (verifies static pins); same manifest in -> identical zip. (2) two
  manifests -- build-time manifest.toml (urls/hashes/signers, source of truth) vs
  install-time components.conf (slim, generated from it; never merge). (3) pin 3
  anchors: versionCode + APK sha256 + signer-cert sha256; signer-cert change = hard
  CI fail. (4) permission XML is an INTERSECTION: requested(APK) cap privileged
  platform perms + FAKE_PACKAGE_SIGNATURE (APK manifest does not carry protection
  levels). (5) drop MinMicroG's variant matrix, resdl DSL, shell-generates-shell.
  microG signer cert SHA-256: 9bd06727e62796c0130eb6dab39b73157451582cbd138e86c468acc395d14165.
- 2026-06-20 (Session 2): Phase 0 implemented via 4 parallel subagents (scaffold /
  manifest+fetch+bump / detect+log+tests / genperms+invariant) + orchestrator glue
  (build.sh, CI). Integration decisions: (a) perms XML filename is the on-device
  lowercased contract perms/<name>.xml (manifest.py is the source of truth; aligned
  invariant.py to it). (b) Added genperms `dump-requested` so a single requested-perms
  sidecar feeds BOTH genperms and the invariant -- no apkanalyzer/aapt2 output drift.
  (c) Sidecars staged under build/meta, kept OUT of the shipped ZIP. (d) CI is two
  workflows: build.yml (hermetic build + checks + publish Release on tag v*) and
  bump.yml (the only network step; opens a manifest-bump PR; weekly + on demand).
  Publish target = GitHub Releases. APKs never committed; build red until first bump.
- 2026-06-20 (Session 4): Phase 1 + Phase 2 implemented together via 5 parallel
  subagents, split by MODULE (disjoint files) not by phase -- the two phases edit
  the same files, so each phase-2 concern was folded into the module it belongs to
  (framework path into place.sh/perms.sh, FakeStore<->Phonesky mutual exclusion into
  customize.sh). Inter-module function contracts were fixed up front in
  claude/phase1-2-contracts.md so the interpreter could be written in parallel
  against stubs. Result: 96 BATS tests green (28 prior + 68 new: place 13, perms 20,
  cleanup 16, customize 20 -- minus 1 reconciliation), shellcheck clean on all 10
  scripts. Phonesky sourcing resolved as user-supplied (docs/phonesky-sourcing.md).
  KNOWN FOLLOW-UP (Phase 3): place_remove clears a framework jar named <Name>.jar but
  place_framework writes <basename of asset> (e.g. maps.jar) -- harmless now (only
  app-type conflicts are declared) but reconcile when a framework conflict exists.
  Note: the `build` CI job stays neutral-skip/red until tools/bump fills real APK
  hashes (PENDING-BUMP); a publishable Release tag requires a bump first.
- 2026-06-21 (Session 5): Cut v0.1.0. Squash-merged PR #1 (dc911f9) so the real
  F-Droid hashes landed as one clean commit; confirmed a real (non-PENDING) build on
  master, which surfaced + fixed a latent Phase 0 bug (build.sh passed --manifest
  AFTER the subcommand, but manifest.py defines it as a global option -- masked until
  now because the build had always neutral-skipped on PENDING-BUMP; fixed c06b547).
  Tagged v0.1.0 -> build + release jobs green -> Release published. Documented the
  whole flow in docs/RELEASING.md. THEN, same session, cleaned up git history: the
  whole 27-commit history was squashed (by contiguous range, content-preserving) into
  5 logical commits (scaffold/design -> Phase 0 build system -> Phase 1/2 installer ->
  auto-update feed -> release pins/MapsV1/runbook) and force-pushed to master; the
  v0.1.0 tag and GitHub Release were deleted (squash invalidated the tag). Re-tag from
  the new history to re-publish. Loose ends: marketplace actions warn "Node.js 20
  deprecated" (cosmetic; future @v4 bump); FakeStore-vs-Play-Store hybrid store
  selector (auto-detect + MICROG_STORE flag) still deferred.
- 2026-06-20 (Session 3): Mapped actual repo state via 3 parallel explorers and
  wrote a fresh-context Phase 1 handoff (`claude/phase1-handoff.md`) with the exact
  contracts (components.conf 7-column format, detect.sh/log.sh APIs, Magisk env,
  on-device placement layout). Corrected the test count in this log: shell suite is
  19 (detect.bats) + 9 (log.bats) = 28 BATS, plus 31 pytest (genperms_test.py) = 59
  host tests total. Confirmed common/place.sh|perms.sh|cleanup.sh and root
  post-fs-data.sh|service.sh do NOT exist yet -- they are Phase 1 deliverables.
