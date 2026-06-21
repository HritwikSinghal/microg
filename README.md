# microG Universal Installer

[![build](https://github.com/HritwikSinghal/microg/actions/workflows/build.yml/badge.svg)](https://github.com/HritwikSinghal/microg/actions/workflows/build.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

A single flashable ZIP that installs [microG](https://microg.org/) as privileged
system apps on stock Android, working across **Magisk**, **KernelSU**, and
**APatch** as a systemless module overlay.

The installer deliberately ships **no signature spoofing**. Spoofing is the
genuinely ROM-specific part; it is provided by your ROM (e.g. LineageOS for
microG, CalyxOS, /e/OS) or by a separate add-on, and is covered by a standalone
guide (see [Roadmap](#roadmap), Phase 5). The ZIP runs correctly in a
Zygisk-enabled environment but bundles no spoofing engine of its own.

> **Status: pre-alpha.** Phases 0-2 are code-complete and host-tested: the build
> system + CI invariant (Phase 0), the on-device installer -- `customize.sh`
> interpreter, overlay placer, API-matched permission selection, declarative
> stock-GMS removal, boot-gated self-check (Phase 1) -- and the framework
> (MapsV1) path + FakeStore/Phonesky mutual exclusion (Phase 2). 96 BATS tests
> and 31 Python tests pass; shellcheck is clean. Real APK hashes are now pinned
> (the `bump` has run), so the build is green and produces a publishable ZIP.
> **Not yet verified on a real device, and no release is currently published.**
> Track progress in [`claude/progress.md`](claude/progress.md). The authoritative
> design is
> [`docs/superpowers/specs/2026-06-20-microg-zygisk-installer-design.md`](docs/superpowers/specs/2026-06-20-microg-zygisk-installer-design.md).

## Why another installer

This is a fresh, focused, fully understood module rather than a fork. It adopts
the good ideas from the reference installers (MinMicroG, micro5k, noogle-magisk)
while fixing the failure modes that bite them -- above all, **bootloops from
mismatched privileged-app permission XMLs**.

### Design pillars

1. **Permission XMLs are generated at build time, and a CI invariant makes a
   bootlooping release unbuildable.** A `/system/priv-app` on stock Android
   (API >= 26, `enforce` mode) is only granted the privileged permissions an
   allowlist XML explicitly lists. The allowlist is computed as an
   *intersection* -- `requested(APK) INTERSECT privileged_perms(API)` plus the
   microG-custom `FAKE_PACKAGE_SIGNATURE` -- and a CI gate asserts the APK's
   requested-privileged perms are a subset of it. No on-device `aapt`.
2. **Module mode overlays under `$MODPATH/system`; it never writes real
   partitions.** Free-space / read-only / A-B / dynamic-partition concerns are
   deferred to a later direct-partition placer.
3. **The mount engine is detected (magic-mount vs OverlayFS), not the root
   manager.** Stock-GMS removal prefers the declarative Magisk `REPLACE`
   sentinel over imperative `mknod` whiteouts.
4. **Data-driven `components.conf`; `customize.sh` is a generic interpreter.** A
   `type` discriminator separates a normal priv-app from a framework JAR.
5. **APKs are CI-downloaded and triple-pinned, never committed.** Each component
   is verified by three anchors before use: APK `sha256` (integrity),
   `apksigner verify` (valid signature), and the signer **certificate** SHA-256
   (publisher authenticity). A signer-cert change is a hard CI failure, never an
   auto-bump. The one exception is the MapsV1 framework JAR -- it has no signed
   APK and no stable URL, so it is vendored at `vendor/com.google.android.maps.jar`
   and pinned by `sha256` alone.

## Components installed

| Component | Package | Placement | Notes |
|-----------|---------|-----------|-------|
| microG Services (GmsCore) | `com.google.android.gms` | priv-app | Mandatory core |
| GsfProxy | `com.google.android.gsf` | priv-app | Legacy GSF shim |
| microG Companion (FakeStore) | `com.android.vending` | priv-app | Default store stub; conflicts with Phonesky |
| Google Play Store (Phonesky) | `com.android.vending` | priv-app | Optional real store (Phase 2); conflicts with FakeStore |
| MapsV1 | `com.google.android.maps` | framework | Vendored shared-lib JAR + permissions XML |

## Repository layout

```
module.prop                 # Magisk/KSU/APatch module metadata
META-INF/.../update-binary  # vendored topjohnwu module installer + #MAGISK
customize.sh                # install-time interpreter over components.conf
post-fs-data.sh service.sh  # early-boot stock-GMS removal; boot-gated self-check
common/                     # detect.sh, log.sh, place.sh, perms.sh, cleanup.sh
manifest.toml               # build-time source of truth (urls, hashes, signer certs)
components.conf             # slim install-time table, GENERATED from manifest.toml
lib/                        # build tooling: manifest.py, fetch.sh, genperms.py, invariant.py
tools/bump                  # network RESOLVE step: rewrites manifest.toml
data/                       # privileged-perms-<api>.txt allowlist data
vendor/                     # MapsV1 framework JAR (vendored, sha256-pinned)
test/                       # host BATS + unittest suites (no device, no network)
build.sh                    # hermetic build orchestrator
.github/workflows/          # build (+ publish) and bump CI
apks/  perms/               # populated at build time (git-ignored)
```

Two manifests, two audiences, intentionally not merged: `manifest.toml` holds the
build-time secrets (urls/hashes/signers); `components.conf` is the slim, generated
row table the on-device `customize.sh` interprets.

## Building

The build is split into a network-trusting **resolve** step and a hermetic
**build** step, so the same `manifest.toml` always produces the same ZIP.

```sh
# 1. Resolve: pin real versionCodes + APK hashes + signer certs (reaches the
#    network). Run via the bump CI workflow, or locally:
python3 tools/bump

# 2. Build: hermetic. Downloads each pinned APK, verifies the three anchors,
#    generates the permission XMLs, runs the permission invariant, and assembles
#    the ZIP into out/.
./build.sh
```

`build.sh` requires `python3` (3.11+), `apksigner` and `apkanalyzer`/`aapt2`
(Android build-tools), `zip`, and a sha256 tool; `xmllint` is optional. The
manifest is already pinned, so the build runs; if a non-deferred component were
left at the sentinel `sha256 = "PENDING-BUMP"`, the build would refuse to run --
by design. (The deferred Phonesky entry stays unpinned on purpose -- see
[`docs/phonesky-sourcing.md`](docs/phonesky-sourcing.md).)

## Installing

> The install logic is implemented (Phases 1-2) but not yet device-verified. The
> manifest is pinned, so `./build.sh` produces a flashable ZIP; no GitHub Release
> is currently published (tag a `v*` to publish one -- see [Building](#building)).

Build it (or download a published release), then flash
`out/microg-installer-*.zip` like any module: in
the Magisk / KernelSU / APatch app (Modules -> Install from storage), then reboot.
A boot-time self-check is written to `/data/adb/microg_installer/selfcheck.log`
(detected environment, what was placed, and a final OK/PROBLEM verdict) to turn
"it bootlooped" into an actionable diagnosis.

## Development and CI

- **`build` workflow** -- on every push/PR runs host checks (shellcheck,
  `unittest`, BATS, manifest validation) and the hermetic build; it
  neutral-skips (stays green) while the manifest is unpinned, and **publishes a
  GitHub Release** with the ZIP on a `v*` tag.
- **`bump` workflow** -- the only network-trusting step. On demand or weekly it
  runs `tools/bump`, enforces the signer-cert gate, and opens a PR with the
  updated `manifest.toml`, keeping the build workflow hermetic.

All scripts target POSIX `sh` where they run on-device; tests run purely on the
host (no device, no network).

## Roadmap

- **Phase 0** -- Foundations + CI invariant. *(complete)*
- **Phase 1** -- Module-only installer (Magisk + KSU + APatch): the
  `components.conf` interpreter, overlay placer, API-matched permission
  selection, declarative stock-GMS removal, boot-gated self-check.
  *(code-complete, host-tested; not yet device-verified)*
- **Phase 2** -- Phonesky variant + the MapsV1 framework path.
  *(code-complete, host-tested; Phonesky is user-supplied -- see
  [`docs/phonesky-sourcing.md`](docs/phonesky-sourcing.md))*
- **Phase 3** -- System-mode / direct-partition placement (free-space, A/B,
  dynamic partitions, addon.d OTA survival).
- **Phase 4** (stretch) -- Recovery flashing (ZIP signing, `/mnt/system`).
- **Phase 5** -- Signature-spoofing guide (standalone; can start anytime).

## License

[GPL-3.0-or-later](LICENSE). The module entry point (`update-binary`) is vendored
from [Magisk](https://github.com/topjohnwu/Magisk) (also GPLv3). microG and the
bundled APKs are the property of their respective authors and are downloaded at
build time under their own licenses, not redistributed in this repository.

## Credits

- [microG](https://github.com/microg) -- GmsCore and the microG project.
- [Magisk](https://github.com/topjohnwu/Magisk) -- the module framework and
  installer template.
- Reference installers studied for patterns: MinMicroG, micro5k
  microg-unofficial-installer, nift4 microg_installer_revived, noogle-magisk.
