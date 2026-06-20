# microG Universal Installer -- Design Spec

- Status: Draft for review
- Date: 2026-06-20
- Repo: this repository (run all scripts from the repo root)

## 1. Overview

A single flashable ZIP that installs microG as privileged system apps on stock
Android, working universally across the three major root managers (Magisk,
KernelSU, APatch) by shipping as a systemless module overlay. The installer
deliberately does NOT bundle signature spoofing; spoofing is provided by the
user's ROM or an add-on, and is covered by a separate, comprehensive guide
(see Section 9). The ZIP runs correctly in a Zygisk-enabled environment but
ships no spoofing engine of its own.

This mirrors what every mature reference installer actually does (MinMicroG,
micro5k, nift4/revived, noogle-magisk all ship the app-install layer and
delegate spoofing), while fixing the failure modes those projects hit.

## 2. Goals and non-goals

Goals:
- Install microG components as privileged apps with version-matched permission
  XMLs, so the install never boot-loops.
- One ZIP, three root managers (Magisk + KernelSU + APatch), module mode.
- Self-contained, reproducible build: CI downloads pinned, SHA-verified APKs
  and assembles the ZIP; no dependency on an external builder repo.
- A surface small enough to fully understand and maintain across microG bumps.

Non-goals (Phase 1):
- No signature spoofing engine bundled (no LSPosed, no Zygisk spoof native code).
- No recovery/system-partition install in Phase 1 (designed for, deferred).
- No ZIP signing in Phase 1 (root managers do not verify it).
- No Play Integrity / SafetyNet passing logic (out of scope; documented only).

## 3. Decisions log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Target environment | Maximally universal (stock + microG ROMs; Magisk/KSU/APatch) | Broadest usefulness; spoofing auto-skipped where the ROM already provides it. |
| Signature spoofing | Out of installer; separate guide | The genuinely ROM-specific, hard part; all references delegate it. Keeps the installer shippable and low-maintenance. |
| Base | Fresh, clean module; vendor only assets | micro5k's module path is a stub + 4000-line monolith; MinMicroG upstream is dead. A focused module is less work and fully understood. |
| Components | GmsCore + Companion/FakeStore OR Phonesky + GsfProxy + MapsV1 | Standard functional set plus optional real Play Store. |
| Repo setup | Start fresh in this dir | User directive; no inheritance from the old MinMicroG fork. |
| XML generation | Build-time, with CI invariant | On-device aapt is fat/fragile; CI is where bootloop prevention is strongest. |
| Spoofing guide timing | Parallel / anytime | Pure research+writing, no code dependency. |
| APK sourcing | CI downloads, SHA-pinned | Small repo, matches micro5k; no committed binaries. |

## 4. Components installed

| Component | Package | Placement | Notes |
|-----------|---------|-----------|-------|
| microG Services (GmsCore) | com.google.android.gms | priv-app | Mandatory core. Current: v0.3.15.x, versionCode 250932030. Use standard build (not -hw/-user). |
| microG Companion (FakeStore) | com.android.vending | priv-app | Default store stub. Mutually exclusive with Phonesky. |
| Google Play Store (Phonesky) | com.android.vending | priv-app | Optional real store; conflicts with FakeStore; needs Device Registration to be useful. |
| GsfProxy | com.google.android.gsf | priv-app | Legacy GSF shim. |
| MapsV1 | com.google.android.maps | framework | Shared-lib JAR + permissions XML; not a normal app (type=framework). |

Google signing cert SHA-1 that spoofing must report (documented in the guide,
not used by the installer): 38918a453d07199354f8b19af05ec6562ced5788.

## 5. Architecture

### 5.1 ZIP layout

```
microg-installer.zip
  META-INF/com/google/android/
    update-binary        # topjohnwu module_installer.sh (module + recovery entry)
    updater-script       # "#MAGISK"
  module.prop            # id, name, version, versionCode, author, description
  customize.sh           # install-time orchestrator (sourced by module_installer)
  post-fs-data.sh        # early boot: declarative stock-GMS removal if present
  service.sh             # late boot (boot-gated): self-check log only
  common/
    detect.sh            # pure readers: api, arch, root mgr, mount engine, partition
    place.sh             # Placer strategies (module overlay; direct-partition later)
    perms.sh             # select + validate pre-generated permission XMLs
    cleanup.sh           # StockGmsRemover strategies (REPLACE sentinel preferred)
    log.sh               # structured logging to a fixed path
  components.conf        # data-driven component manifest (see 5.4)
  apks/                  # populated at build time: SHA-pinned APKs + maps JAR
  perms/                 # build-time-generated version-matched XML variants
```

(addon.d/ and ZIP signing are intentionally absent in Phase 1; see phases.)

### 5.2 Logical units (single-responsibility)

1. Detection -- read-only environment probes (API level, CPU arch/IS64BIT, root
   manager, mount engine, partition layout). No side effects; host-testable with
   a mocked getprop source.
2. Placement -- a `Placer` interface with two implementations:
   - `ModuleOverlayPlacer` (Phase 1): writes under `$MODPATH/system/<part>/priv-app/...`.
     The "partition" is only a path prefix inside the module; the target is always
     on writable /data, so free-space / read-only / dynamic-partition / A-B
     concerns DO NOT apply here.
   - `DirectPartitionPlacer` (Phase 3): real partition writes, mount rw, free-space
     checks, 0644 modes, addon.d. Deferred.
3. Permissions -- selects the correct pre-generated XML variant (by API level) and
   places it in the matching partition's etc/permissions, etc/sysconfig,
   etc/default-permissions. Never generates on-device.
4. Cleanup -- `StockGmsRemover`: prefer the declarative Magisk `REPLACE` sentinel
   over imperative `mknod` whiteouts (which can silently no-op under OverlayFS).

### 5.3 Mount-engine-aware behavior

Detect the mount engine explicitly (Magisk magic-mount vs KSU/APatch OverlayFS) --
NOT inferred from the root manager, since KSU can be configured either way.
Whiteout/removal semantics differ between engines; the `REPLACE` sentinel is the
portable path.

### 5.4 Data-driven component manifest

`components.conf` declares each component as a row; `customize.sh` is a generic
interpreter over it (iterate -> place -> collect XML -> resolve conflicts). Adding
or swapping a component is a data change, not shell logic. Sketch:

```
# name        pkg                          asset              partition  type       perms            conflicts
GmsCore        com.google.android.gms       apks/GmsCore.apk   product    app        perms/gms.xml     -
GsfProxy       com.google.android.gsf       apks/GsfProxy.apk  product    app        perms/gsf.xml     -
FakeStore      com.android.vending          apks/FakeStore.apk product    app        perms/vending.xml Phonesky
Phonesky       com.android.vending          apks/Phonesky.apk  product    app        perms/phonesky.xml FakeStore
MapsV1         com.google.android.maps      apks/maps.jar      product    framework  perms/maps.xml    -
```

A `type` discriminator distinguishes a normal priv-app from a framework JAR
(which goes to `<part>/framework` plus an XML in `<part>/etc/permissions`).

## 6. Build and CI

- `build.sh`: reads pinned versions+SHA-256 from a manifest, downloads microG
  (GitHub releases) and Phonesky (mirror), verifies SHA, generates permission XMLs
  from the actual APK manifests (build-time, using aapt2 on the CI host),
  assembles the ZIP. No committed binaries.
- GitHub Actions: runs `build.sh`, uploads the ZIP artifact / release.
- CI permission-invariant gate (the permanent bootloop cure): for each bundled
  APK, extract the set of requested permissions whose protectionLevel includes
  `privileged`, and assert:
  - requested_privileged is a subset of the generated privapp-permissions allowlist, AND
  - every entry in default-permissions is actually declared by the APK.
  A mismatched microG bump becomes literally unbuildable.

## 7. Error handling and edge cases (must-handle checklist)

- [ ] Real GMS present and active -> refuse or fully remove; coexistence breaks auth.
- [ ] Encrypted /data (FBE) -> post-fs-data runs pre-decryption; never touch /data/data there.
- [ ] KSU/APatch on OverlayFS vs magic-mount -> detect engine; use declarative removal.
- [ ] API < 26 (no privapp enforcement) -> XMLs harmless; behavior still correct.
- [ ] arch mismatch -> ensure bundled APK/native libs match ARCH/IS64BIT.
- [ ] service.sh before PMS ready -> gate on sys.boot_completed.
- [ ] Re-flash / upgrade -> idempotent placement; replace stale XML, do not merge.
- [ ] Uninstall -> remove placed files; restore stock expectations cleanly.
- [ ] User already runs LSPosed/Zygisk spoofing -> must not conflict; document boundary.
- [ ] FakeStore vs Phonesky -> mutually exclusive; conflict resolved atomically across place+perms+cleanup.

## 8. Testing strategy

- Host-side: shellcheck on all scripts; BATS unit tests for `common/detect.sh`
  and `perms.sh` selection logic with fixture getprop / manifest inputs.
- CI: the permission-invariant assertion (Section 6) on every build.
- Device (user-deployed; agent does not flash): flash the same ZIP on Magisk,
  KernelSU, APatch across two API levels (e.g. 13 and 14); confirm microG
  self-check shows components present with correct versionCode, no bootloop.
- A boot-time self-check log at /data/adb/microg_installer/selfcheck.log turns
  "it bootlooped" into an actionable diagnosis.

## 9. Signature-spoofing guide (separate deliverable, parallel)

A standalone document, independent of the installer code, covering every way to
get signature spoofing working on any ROM, with verification via the microG
self-check ("System grants signature spoofing"):
- Patched-framework ROMs that already spoof (LineageOS-for-microG, CalyxOS,
  /e/OS, iodeOS) -- detect and do nothing.
- LSPosed + FakeGApps (whew-inc) -- the Xposed route; LSPosed fork selection per
  Android version; required Zygisk implementation per root manager
  (Magisk built-in vs ReZygisk / Zygisk Next on KSU/APatch).
- Native Zygisk signature-spoofing modules (survey of current options + maturity).
- Verification steps and common pitfalls (must not coexist with real GMS; module
  activation toggles; DenyList/Shamiko interactions).

## 10. Phase breakdown

- Phase 0 -- Foundations + CI invariant. Scaffold, components.conf schema,
  common/detect.sh + host test harness, build-time XML generation, CI
  permission-invariant gate first.
- Phase 1 -- Module-only installer (Magisk + KSU + APatch). Manifest interpreter,
  ModuleOverlayPlacer, declarative REPLACE stock-GMS removal, boot-gated self-check.
- Phase 2 -- Phonesky variant + MapsV1 framework path (conflict resolution, type=framework).
- Phase 3 -- System-mode / direct-partition placement (DirectPartitionPlacer,
  free-space, dynamic/A-B, addon.d OTA survival).
- Phase 4 (stretch) -- Recovery flashing (ZIP signing, /mnt/system, Android-14
  free-space workaround).
- Phase 5 -- Signature-spoofing guide (parallel; can start anytime).

## 11. YAGNI / cut from Phase 1

- addon.d (Phase 3), ZIP signing (Phase 4), on-device aapt XML generation
  (replaced by build-time + install-time selection), recovery support
  (interface designed now, implemented in Phase 4).

## 12. Open questions / risks

- Phonesky has no stable redistributable URL and licensing is gray; CI sourcing
  may need a maintained mirror. Revisit in Phase 2.
- OverlayFS priv-app visibility at PMS scan time must be verified on real KSU/APatch
  devices (cannot be unit-tested on host).
