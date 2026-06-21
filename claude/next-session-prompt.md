# Handoff prompt -- microG Universal Installer (start of implementation)

Copy the prompt below into a fresh session to continue this project with clean
context. Everything it needs is on disk; it does not need this conversation.

---

## Prompt for the next agent

You are picking up a long-running project in this repository (work from the repo
root): build a single flashable ZIP that installs microG as privileged system apps on
stock Android, working across Magisk / KernelSU / APatch as a systemless module
overlay. The design is DONE and approved; your job is to plan and implement it.

### First: read these, in order (do not skip)
1. `docs/superpowers/specs/2026-06-20-microg-zygisk-installer-design.md` -- the
   full, authoritative design spec. This is the source of truth.
2. `claude/progress.md` -- the 6-phase task tracker. Update it after every task.
3. `CLAUDE.md` (this repo) and your global Claude instructions, if any.
4. Your project-memory store for this repo, if you maintain one.

### Hard constraints (from the user -- non-negotiable)
- DO NOT build, test, flash, or SSH to any device. The user deploys and verifies
  on real phones. You write code/docs and a CI that builds the artifact; rely on
  host-side checks only (shellcheck, BATS, the CI permission invariant).
- Autocommit: commit logically-grouped changes as you go (do not set git
  user.name/email; use the repo defaults). Do not push unless asked.
- Use parallel subagents for independent multi-file work.
- ASCII-only output (a hook enforces this).
- This is a fresh, clean module -- NOT a fork. The user has old MinMicroG forks;
  ignore them. Vendor only assets (permission XMLs, MapsV1 jar), never an engine.
- Signature spoofing is OUT of the installer. It is a separate guide (Phase 5).

### The five design pillars you must preserve (see spec for detail)
1. Permission XMLs are generated at BUILD time; a CI invariant asserts
   requested-privileged-perms subset-of allowlist AND default-permissions
   subset-of declared. This makes a bootlooping microG bump unbuildable. No
   on-device aapt.
2. Module mode OVERLAYS under `$MODPATH/system`; it never writes real partitions
   in Phase 1. Free-space / read-only / A-B / dynamic-partition logic is Phase 3
   (DirectPartitionPlacer), not now.
3. Detect the MOUNT ENGINE (magic-mount vs OverlayFS), not the root manager.
   Prefer the declarative REPLACE sentinel over imperative mknod for stock-GMS
   removal.
4. Data-driven `components.conf`; `customize.sh` is a generic interpreter. A
   `type` discriminator separates priv-app from framework JAR (MapsV1).
5. Components: GmsCore + GsfProxy + MapsV1 + (FakeStore XOR real Phonesky). APKs
   are CI-downloaded + SHA-pinned, never committed.

### What to do first
Start with Phase 0 (Foundations + CI invariant). Before writing code, invoke the
`writing-plans` skill (superpowers) to turn Phase 0 of the spec into a detailed,
checkpointed implementation plan, then execute it. Phase 0 tasks (from
`claude/progress.md`):
- Repo scaffold (module.prop, META-INF/update-binary + updater-script, dir layout,
  .gitignore for apks/ and build output).
- `components.conf` schema + a parser.
- `common/detect.sh` (api, arch, root manager, mount engine, partition) with a
  host-side BATS harness using mocked getprop/manifest fixtures.
- `common/log.sh` structured logging.
- `build.sh`: pinned-version + SHA-256 manifest, APK download + verify,
  build-time permission-XML generation via aapt2.
- CI permission-invariant gate.
- GitHub Actions workflow: build.sh + invariant + artifact upload.

Pull current docs via context7 when touching aapt2/Magisk module APIs rather than
relying on memory. Confirm pinned microG version against
https://github.com/microg/GmsCore/releases (latest at design time: v0.3.15.x,
GmsCore versionCode 250932030).

### Update protocol
After each task: mark it `[x]` in `claude/progress.md`, recount the Status
Summary, update the date. Commit at phase boundaries with a message like
`progress: complete Phase 0 - Foundations`. Append diary + project-memory writes
per the global CLAUDE.md discipline.

### Reference repos (for assets/patterns only, already researched -- do not re-survey)
- micro5k/microg-unofficial-installer -- `tools/generate-perm-xml.sh` pattern,
  permission XML structure, SHA-pinned download manifest. Actively maintained.
- FriendlyNeighborhoodShane/MinMicroG (+ HPsaucii/MinMicroG NikFixes) -- defconf
  data-driven variant pattern, module+recovery unification. Upstream dead.
- nift4/microg_installer_revived -- the overlay-branch RRO that redirects
  network-location/geocoder to microG (optional later add).
- SelfRef/noogle-magisk -- mknod whiteout removal, priv-app/perms quartet layout.
- microg/GmsCore -- official releases + signature-spoofing wiki.
---
