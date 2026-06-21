# microG Universal Installer -- Progress

Last updated: 2026-06-20 | Session: 2

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
      -- pure read-only probes; GETPROP/DETECT_ROOT/DETECT_MOUNTS indirection for mocking; 28 BATS tests
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
- [ ] customize.sh manifest interpreter
- [ ] common/place.sh ModuleOverlayPlacer
- [ ] common/perms.sh XML selection by API level + placement in matching partition
- [ ] common/cleanup.sh StockGmsRemover via declarative REPLACE sentinel
- [ ] post-fs-data.sh (engine-aware removal) + service.sh (boot-gated self-check log)
- [ ] selfcheck.log diagnostics
- [ ] shellcheck clean across all scripts

### Phase 2 -- Phonesky variant + MapsV1 framework path
- [ ] Phonesky vs FakeStore mutual-exclusion (atomic across place+perms+cleanup)
- [ ] type=framework handling (JAR -> framework dir + permissions XML)
- [ ] Resolve Phonesky sourcing/mirror question

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

## Status Summary

| Phase | Status | Tasks done |
|-------|--------|------------|
| Phase 0 -- Foundations + CI invariant | Code-complete* | 11/11 |
| Phase 1 -- Module-only installer | Pending | 0/7 |
| Phase 2 -- Phonesky + MapsV1 | Pending | 0/3 |
| Phase 3 -- System-mode placement | Pending | 0/3 |
| Phase 4 -- Recovery flashing | Pending | 0/2 |
| Phase 5 -- Spoofing guide | Pending | 0/4 |

\* Code-complete = all files written; host/CI verification is the user's to run
(per directive: agent does not build/test/flash). The `build` CI job is RED until
the first `tools/bump` fills real APK hashes (sha256 is "PENDING-BUMP" by design);
the `checks` job (shellcheck/pytest/BATS) should be green. Run the `bump` workflow
(or `tools/bump` locally) to produce real pins, then the build can publish.

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
