# microG Universal Installer -- Progress

Last updated: 2026-06-20 | Session: 1

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
- [ ] Repo scaffold (module.prop, META-INF, dir layout, .gitignore for apks/)
- [ ] components.conf schema + parser
- [ ] common/detect.sh (api, arch, root manager, mount engine, partition) + host BATS harness
- [ ] common/log.sh structured logging
- [ ] build.sh: pinned-version manifest, SHA-verified APK download, build-time XML generation (aapt2)
- [ ] CI permission-invariant gate (requested_privileged subset-of allowlist; default-permissions subset-of declared)
- [ ] GitHub Actions workflow running build.sh + invariant + artifact upload

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
| Phase 0 -- Foundations + CI invariant | Pending | 0/7 |
| Phase 1 -- Module-only installer | Pending | 0/7 |
| Phase 2 -- Phonesky + MapsV1 | Pending | 0/3 |
| Phase 3 -- System-mode placement | Pending | 0/3 |
| Phase 4 -- Recovery flashing | Pending | 0/2 |
| Phase 5 -- Spoofing guide | Pending | 0/4 |

## Decisions & Notes

- 2026-06-20: Design finalized via brainstorming + architecture review. Base =
  fresh clean module (not a fork); micro5k module path is a stub, MinMicroG upstream
  is dead. Spoofing excluded from the installer, shipped as a separate guide.
  APKs CI-downloaded + SHA-pinned (not committed). XML generation at build time
  with a CI invariant as the permanent bootloop fix. Mount-engine detection over
  root-manager inference. See the design spec for full rationale.
