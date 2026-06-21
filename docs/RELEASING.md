# Releasing

How to cut a release of the microG Universal Installer. The pipeline is split so
the build stays hermetic: the network-trusting step (`bump`) is separate from the
build, and a release is just a `v*` tag once the manifest is pinned.

## Pipeline at a glance

```
tools/bump (network) --> PR with real APK pins --> squash-merge --> tag v* --> Release
   (bump.yml)              (review the diff)        (master green)   (build.yml -> release)
```

- `bump.yml` -- the ONLY network step. Resolves each component's latest
  versionCode + APK sha256 + signer cert from the microG F-Droid repo / GitHub,
  rewrites `manifest.toml`, runs the signer-cert gate, and opens a PR.
- `build.yml` -- `checks` (lint/tests, always) -> `build` (hermetic ZIP; **neutral-skips
  while any non-deferred component is `PENDING-BUMP`**) -> `release` (on `v*` tags only).

## Prerequisites (one-time)

- `gh` CLI authenticated (`gh auth status`).
- Repo setting **Settings -> Actions -> General -> "Allow GitHub Actions to create
  and approve pull requests"** must be ON (so `bump.yml` can open its PR). Check / set:
  ```bash
  gh api repos/OWNER/REPO/actions/permissions/workflow            # check
  gh api -X PUT repos/OWNER/REPO/actions/permissions/workflow \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true
  ```

## Steps

### 1. Bump the pinned component versions

```bash
gh workflow run bump.yml
gh run watch "$(gh run list --workflow=bump.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

This opens (or refreshes) the `automated/manifest-bump` PR. If the **signer-cert
gate** fails, a component's signing key changed -- treat it as a security event,
verify the new key out-of-band, and only then update `signer_cert_sha256` by hand.
Re-run `bump` after any manual `manifest.toml` change so the PR rebases onto it.

### 2. Review and squash-merge the bump PR

```bash
gh pr diff <N>                       # eyeball the versionCode / sha256 diff
gh pr merge <N> --squash --delete-branch
git checkout master && git pull --ff-only
```

Always **squash-merge** (one clean commit, no merge noise).

### 3. Confirm the real build is green on master

Merging flips the build gate to `bumped=true`, so the push runs the full hermetic
build. Confirm it before tagging:

```bash
# local gate sanity-check (no Android SDK needed):
python3 lib/manifest.py list | awk -F'\t' 'NR>1 && $3=="PENDING-BUMP"{f=1} END{exit f?1:0}' \
  && echo "fully pinned" || echo "still has PENDING-BUMP"

gh run watch "$(gh run list --workflow=build.yml --branch master --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

### 4. Set the release version

The version + versionCode come from `module.prop` (the source of truth):

```
version=v0.1.0
versionCode=1
```

For a new release, bump both (versionCode must be a strictly increasing integer --
it is what the module managers compare for auto-update). Commit the change:

```bash
git commit -am "release: bump module.prop to vX.Y.Z (versionCode N)"
git push origin master
```

### 5. Tag and publish

The tag must match `module.prop`'s `version` (the `v` prefix is required):

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

The `v*` tag triggers `build.yml` -> `build` -> `release`, which builds the ZIP and
publishes a GitHub Release with three assets:

- `microg-installer-vX.Y.Z.zip` -- the flashable module
- `update.json` -- the in-app auto-update feed (`module.prop`'s `updateJson` points
  at the fixed `latest` URL; its body references this versioned zip)
- `changelog.md` -- generated from the git log since the previous tag

Watch it:

```bash
gh run watch "$(gh run list --workflow=build.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
gh release view vX.Y.Z
```

## Notes

- **MapsV1** is `source = "vendored"` -- the jar is committed at
  `vendor/com.google.android.maps.jar` and `bump` skips it (it is a framework JAR
  with no signed APK and no stable bare-jar URL). To update it, replace the file
  and pin the new `sha256` in `manifest.toml` by hand.
- **Phonesky** is deferred (`url = ""`): no redistributable Play Store binary ships
  (see `docs/phonesky-sourcing.md`). It is skipped by both `bump` and the build.
- A tag pushed while the manifest still has `PENDING-BUMP` is a no-op: `build`
  neutral-skips and `release` never runs. Always bump first.
